import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/gcm.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/stream/sic.dart';

/// Giải mã file audio Suno ("Mango" scheme — đúng cách trình phát web
/// của Suno làm cho người nghe ẩn danh, không cần đăng nhập).
///
/// NGUYÊN NHÂN GỐC của lỗi "Không chuyển đổi được" (bug 15/10):
/// file audio trong `media_urls` của Suno KHÔNG phải file media thường —
/// toàn bộ file được mã hoá AES (kiểm chứng thật: file tải về không có
/// cấu trúc MP4 nào, ffmpeg báo "moov atom not found"). Vì vậy ffmpeg
/// không bao giờ convert được file này, dù đổi tham số thế nào.
/// Phải giải mã trước rồi mới convert.
///
/// Quy trình (đã kiểm chứng end-to-end với bài thật "Tình khúc ngày cũ"):
/// 1. POST https://studio-api.prod.suno.com/api/mango/rights
///    body {"content_params": {"content_id": clipId, "content_type": "clip"}}
///    -> {"key", "iv", "glt"} (ẩn danh, theo từng clip).
/// 2. user key = SHA-256(glt).
/// 3. key/iv được gói bằng AES-256-GCM: nonce = bytes[0:12],
///    ciphertext = bytes[12:-16], tag = bytes[-16:], AAD = clip id.
/// 4. File audio được mã hoá AES-128-CTR bằng key/counter đã gỡ gói.
///
/// Lưu ý: chỉ dùng cho nhạc công khai / nhạc của chính người dùng.
/// Không chạm vào tài khoản, cookie hay mật khẩu Suno.
class SunoCryptoException implements Exception {
  final String message;
  const SunoCryptoException(this.message);
}

/// Quyền giải mã của 1 clip: key/iv đã gói (base64) + token glt.
class SunoRights {
  final String key;
  final String iv;
  final String glt;

  const SunoRights({required this.key, required this.iv, required this.glt});
}

/// Xin quyền giải mã cho 1 clip từ rights server của Suno (ẩn danh).
Future<SunoRights> fetchRights(String clipId, {http.Client? client}) async {
  final httpClient = client ?? http.Client();
  late final http.Response response;
  try {
    response = await httpClient
        .post(
          Uri.parse('https://studio-api.prod.suno.com/api/mango/rights'),
          headers: {
            'Content-Type': 'application/json',
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                'AppleWebKit/537.36 (KHTML, like Gecko) '
                'Chrome/126.0.0.0 Safari/537.36',
            'Accept': 'application/json, text/plain, */*',
            'Origin': 'https://suno.com',
            'Referer': 'https://suno.com/song/$clipId',
          },
          body: jsonEncode({
            'content_params': {'content_id': clipId, 'content_type': 'clip'},
          }),
        )
        .timeout(const Duration(seconds: 30));
  } catch (e) {
    throw SunoCryptoException('Không lấy được quyền giải mã: $e');
  }
  if (response.statusCode != 200) {
    throw SunoCryptoException(
      'Máy chủ Suno từ chối quyền giải mã (mã ${response.statusCode}).',
    );
  }
  try {
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final key = data['key'] as String?;
    final iv = data['iv'] as String?;
    final glt = data['glt'] as String?;
    if (key == null || iv == null || glt == null) {
      throw const SunoCryptoException(
        'Phản hồi quyền giải mã thiếu dữ liệu.',
      );
    }
    return SunoRights(key: key, iv: iv, glt: glt);
  } catch (e) {
    if (e is SunoCryptoException) rethrow;
    throw SunoCryptoException('Không đọc được quyền giải mã: $e');
  }
}

/// Gỡ gói key/iv bằng AES-256-GCM. [wrappedB64] = nonce(12) + ct + tag(16).
Uint8List unwrapKey(String wrappedB64, String clipId, Uint8List userKey) {
  final wrapped = base64Decode(wrappedB64);
  if (wrapped.length < 12 + 16 + 1) {
    throw const SunoCryptoException('Gói key giải mã không hợp lệ.');
  }
  final nonce = wrapped.sublist(0, 12);
  final cipherTextWithTag = wrapped.sublist(12);
  final cipher = GCMBlockCipher(AESEngine());
  cipher.init(
    false,
    AEADParameters(
      KeyParameter(userKey),
      128,
      nonce,
      Uint8List.fromList(utf8.encode(clipId)),
    ),
  );
  try {
    // process() nhận ciphertext KÈM tag ở cuối, trả về plaintext.
    return cipher.process(cipherTextWithTag);
  } catch (e) {
    throw SunoCryptoException('Không gỡ được key giải mã: $e');
  }
}

/// User key = SHA-256(glt).
Uint8List userKeyFromGlt(String glt) {
  final digest = SHA256Digest();
  return digest.process(Uint8List.fromList(utf8.encode(glt)));
}

/// Giải mã file audio đã mã hoá (AES-CTR) thành file media thường.
/// Đọc/ghi theo khối 64KB nên file dài cũng không tốn RAM.
/// [onProgress] nhận 0.0 -> 1.0 (hoặc -1 nếu không biết dung lượng).
Future<void> decryptAudioFile({
  required String inputPath,
  required String outputPath,
  required String clipId,
  required SunoRights rights,
  void Function(double progress)? onProgress,
}) async {
  final userKey = userKeyFromGlt(rights.glt);
  final key = unwrapKey(rights.key, clipId, userKey);
  final counter = unwrapKey(rights.iv, clipId, userKey);
  if (key.length != 16 || counter.length != 16) {
    throw const SunoCryptoException(
      'Key giải mã không đúng định dạng (cần AES-128).',
    );
  }
  // SIC = CTR mode (stream cipher): processBytes xử lý đúng từng byte,
  // an toàn khi đưa vào theo khối 64KB (keystream được giữ liên tục).
  final cipher = SICStreamCipher(AESEngine());
  cipher.init(false, ParametersWithIV(KeyParameter(key), counter));

  final input = File(inputPath);
  final total = await input.length();
  final output = File(outputPath);
  final sink = output.openWrite();
  var processed = 0;
  final raf = await input.open();
  try {
    while (true) {
      final chunk = await raf.read(64 * 1024);
      if (chunk.isEmpty) break;
      final out = Uint8List(chunk.length);
      cipher.processBytes(chunk, 0, chunk.length, out, 0);
      sink.add(out);
      processed += chunk.length;
      onProgress?.call(total > 0 ? processed / total : -1);
    }
  } finally {
    await raf.close();
    await sink.close();
  }
  onProgress?.call(1.0);
}

/// File đã là media thường (không mã hoá) chưa? Kiểm tra magic bytes:
/// MP4/M4A ("ftyp" ở offset 4), MP3 (ID3 / frame sync), WAV (RIFF),
/// Ogg (OggS), WebM (EBML). File Suno đã mã hoá không khớp cái nào.
bool isPlayableMediaHeader(List<int> head) {
  if (head.length >= 8 && String.fromCharCodes(head.sublist(4, 8)) == 'ftyp') {
    return true;
  }
  if (head.length >= 3 &&
      head[0] == 0x49 && // I
      head[1] == 0x44 && // D
      head[2] == 0x33) {
    return true; // ID3 (mp3)
  }
  if (head.length >= 2 && head[0] == 0xFF && (head[1] & 0xE0) == 0xE0) {
    return true; // MP3 frame sync
  }
  if (head.length >= 4 &&
      head[0] == 0x52 && // R
      head[1] == 0x49 && // I
      head[2] == 0x46 && // F
      head[3] == 0x46) {
    return true; // RIFF (wav)
  }
  if (head.length >= 4 &&
      head[0] == 0x4F && // O
      head[1] == 0x67 && // g
      head[2] == 0x67 && // g
      head[3] == 0x53) {
    return true; // OggS
  }
  if (head.length >= 4 &&
      head[0] == 0x1A &&
      head[1] == 0x45 &&
      head[2] == 0xDF &&
      head[3] == 0xA3) {
    return true; // EBML (webm)
  }
  return false;
}

/// Đọc 12 byte đầu file để kiểm tra có phải media thường không.
Future<bool> isPlayableMediaFile(String path) async {
  try {
    final file = File(path);
    final bytes = await file.openRead(0, 12).first;
    return isPlayableMediaHeader(bytes);
  } catch (_) {
    return false;
  }
}
