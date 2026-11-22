import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'facebook_video_http.dart';
import 'video_source.dart';

part 'video_transfer.dart';

/// Kết quả tải: file đã lưu + có phải fallback sang thư mục khác
/// (thư mục ưu tiên ghi không được) hay không.
class DownloadResult {
  const DownloadResult({required this.file, required this.usedFallback});

  final File file;
  final bool usedFallback;
}

/// Tải file video về máy, báo tiến độ 0.0 -> 1.0.
/// Thử lần lượt: thư mục ưu tiên (do người dùng chọn) -> thư mục
/// Downloads công khai -> thư mục riêng của app (Android 10+ scoped
/// storage có thể chặn ghi trực tiếp vào Downloads).
class VideoDownloader {
  final http.Client _client;

  /// Timeout KHÔNG CÓ DỮ LIỆU: chỉ timeout khi quá [idleTimeout] mà
  /// không nhận được byte nào (mạng chậm / file lớn không bị cắt
  /// giữa chừng như timeout tổng). Test truyền giá trị nhỏ.
  final Duration idleTimeout;

  VideoDownloader({
    http.Client? client,
    this.idleTimeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client();

  /// Số lần thử tải lại tối đa khi file bị cụt / lỗi mạng.
  static const maxAttempts = 3;

  Future<List<Directory>> _candidateDirs() async {
    final dirs = <Directory>[];
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) dirs.add(downloads);
    } catch (_) {}
    try {
      final external = await getExternalStorageDirectory();
      if (external != null) dirs.add(external);
    } catch (_) {}
    try {
      dirs.add(await getApplicationDocumentsDirectory());
    } catch (_) {}
    return dirs;
  }

  /// Tải [url] về file.
  /// [onProgress] nhận giá trị 0.0 - 1.0 (hoặc -1 nếu không biết tổng dung lượng).
  /// [preferredDir] là thư mục ưu tiên (do người dùng chọn); nếu ghi
  /// không được sẽ thử các thư mục còn lại và báo usedFallback = true.
  /// [fileName]: tên file đích. Mặc định `fb_video_<timestamp>.mp4`
  /// (tab Video FB). Tab Nhạc Suno truyền tên bài + `.mp3/.m4a/.wav`.
  ///
  /// Sau mỗi lần tải, file được KIỂM TRA ĐẦY ĐỦ: số byte so với
  /// Content-Length (nếu server gửi) + marker kết thúc file theo
  /// ĐỊNH DẠNG THẬT phát hiện từ magic bytes (KHÔNG tin đuôi file
  /// trong URL/tên file — CDN của Facebook có thể trả WebP/AVIF cho
  /// URL ".jpg" tùy header Accept; bản v12 kiểm tra JPEG cứng nên
  /// đã loại nhầm file WebP hợp lệ thành "file cụt"). File cụt sẽ bị
  /// XOÁ và tải lại tối đa [maxAttempts] lần. Hết lượt vẫn cụt ->
  /// ném lỗi kèm lý do thật, KHÔNG để file cụt lại trong thư mục
  /// (người gọi đếm vào "ảnh lỗi" và hiện lý do).
  /// Nếu định dạng thật khác đuôi tên file (vd WebP cho tên .jpg),
  /// file được ĐỔI ĐUÔI theo định dạng thật (vd .webp) để mở đúng.
  Future<DownloadResult> download(
    String url, {
    required void Function(double progress) onProgress,
    Directory? preferredDir,
    String? fileName,
  }) async {
    final resolvedFileName =
        fileName ?? 'fb_video_${DateTime.now().millisecondsSinceEpoch}.mp4';
    final dirs = <Directory>[];
    final seen = <String>{};
    void addDir(Directory dir) {
      if (seen.add(dir.path)) dirs.add(dir);
    }

    if (preferredDir != null) addDir(preferredDir);
    for (final dir in await _candidateDirs()) {
      addDir(dir);
    }
    if (dirs.isEmpty) {
      throw Exception('Không tìm được thư mục lưu file.');
    }

    Exception? lastError;
    for (final dir in dirs) {
      for (var attempt = 0; attempt < maxAttempts; attempt++) {
        final file = File('${dir.path}/$resolvedFileName');
        try {
          final expectedLength = await _downloadOnce(url, file, onProgress);
          final verification = await _verifyComplete(
            file,
            resolvedFileName,
            expectedLength,
          );
          if (!verification.ok) {
            throw Exception(
              'File tải về không đầy đủ (${verification.reason ?? 'không rõ lý do'})',
            );
          }
          // Định dạng thật khác đuôi tên file (vd WebP cho tên .jpg)
          // -> đổi đuôi file theo định dạng thật để mở đúng.
          final origExt = resolvedFileName.split('.').last.toLowerCase();
          final detectedExt = verification.detectedExt;
          if (detectedExt != null && detectedExt != origExt) {
            final renamed = await _renameWithExtension(file, detectedExt);
            onProgress(1.0);
            return DownloadResult(
              file: renamed,
              usedFallback:
                  preferredDir != null && dir.path != preferredDir.path,
            );
          }
          onProgress(1.0);
          return DownloadResult(
            file: file,
            usedFallback:
                preferredDir != null && dir.path != preferredDir.path,
          );
        } catch (e) {
          lastError = e is Exception ? e : Exception(e.toString());
          // Xoá file dở dang / file cụt, không để lại trong thư mục.
          try {
            if (await file.exists()) await file.delete();
          } catch (_) {}
          // Lỗi ghi file (thư mục không ghi được) -> sang thư mục khác
          // ngay, không tốn lượt tải lại. Lỗi mạng / file cụt -> tải
          // lại cùng thư mục.
          if (e is FileSystemException) break;
        }
      }
    }
    throw lastError ?? Exception('Không lưu được file.');
  }

  /// Đổi đuôi file sang [newExt], tránh ghi đè (thêm " (1)", " (2)"...).
  Future<File> _renameWithExtension(File file, String newExt) async {
    final path = file.path;
    final dot = path.lastIndexOf('.');
    final base = dot >= 0 ? path.substring(0, dot) : path;
    var target = '$base.$newExt';
    var n = 1;
    while (await File(target).exists()) {
      target = '$base ($n).$newExt';
      n++;
    }
    return file.rename(target);
  }

  /// Tải 1 lượt (request mới mỗi lượt — stream chỉ dùng được 1 lần).
  /// Trả về Content-Length server gửi (null nếu server không gửi).
  /// Timeout áp cho headers (30s) + timeout không-có-dữ-liệu cho body.
  Future<int?> _downloadOnce(
    String url,
    File file,
    void Function(double) onProgress,
  ) async {
    final request = http.Request('GET', Uri.parse(url));
    request.headers['User-Agent'] =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/126.0.0.0 Safari/537.36';
    final streamed = await _client.send(request).timeout(
          const Duration(seconds: 30),
        );
    if (streamed.statusCode != 200) {
      throw Exception('Tải thất bại (mã ${streamed.statusCode}).');
    }
    final total = streamed.contentLength ?? -1;
    var received = 0;
    final sink = file.openWrite();
    try {
      // timeout() trên stream = timeout KHÔNG CÓ DỮ LIỆU: chỉ ném
      // TimeoutException khi quá idleTimeout không có chunk nào.
      await for (final chunk in streamed.stream.timeout(idleTimeout)) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          onProgress(received / total);
        } else {
          onProgress(-1);
        }
      }
    } finally {
      await sink.close();
    }
    return total > 0 ? total : null;
  }

  /// Kết quả kiểm tra file: đầy đủ không + định dạng thật phát hiện
  /// từ magic bytes (để sửa đuôi file khi CDN trả định dạng khác
  /// đuôi URL) + lý do nếu không đầy đủ.
  Future<_Verification> _verifyComplete(
    File file,
    String fileName,
    int? expectedLength,
  ) async {
    final ext = fileName.split('.').last.toLowerCase();
    final raf = await file.open();
    try {
      final len = await raf.length();
      if (len == 0) {
        return const _Verification(ok: false, reason: 'file rỗng (0 byte)');
      }
      if (expectedLength != null && len != expectedLength) {
        return _Verification(
          ok: false,
          reason: 'thiếu byte ($len/$expectedLength)',
        );
      }
      const imageExts = {'jpg', 'jpeg', 'png', 'webp', 'gif', 'avif'};
      if (imageExts.contains(ext)) {
        // Phải await: finally đóng file ngay sau return, nếu trả
        // Future chưa await thì _verifyImage đọc file đã đóng.
        return await _verifyImage(raf, len);
      }
      if (ext == 'mp4') {
        if (len < 8) {
          return const _Verification(
            ok: false,
            reason: 'file MP4 quá ngắn',
          );
        }
        await raf.setPosition(4);
        final box = await raf.read(4);
        if (String.fromCharCodes(box) != 'ftyp') {
          return const _Verification(
            ok: false,
            reason: 'thiếu hộp ftyp của MP4',
          );
        }
        return const _Verification(ok: true);
      }
      // Các định dạng khác (mp3, m4a, wav, ...): chỉ kiểm tra
      // Content-Length (đã kiểm ở trên).
      return const _Verification(ok: true);
    } finally {
      await raf.close();
    }
  }

  /// Kiểm tra file ảnh bằng ĐỊNH DẠNG THẬT từ magic bytes — không tin
  /// đuôi file trong URL/tên file (CDN Facebook có thể trả WebP/AVIF
  /// cho URL ".jpg"). Trả về detectedExt để đổi đuôi file cho đúng.
  Future<_Verification> _verifyImage(RandomAccessFile raf, int len) async {
    final headLen = len < 16 ? len : 16;
    await raf.setPosition(0);
    final head = await raf.read(headLen);

    bool startsWith(List<int> bytes) {
      if (head.length < bytes.length) return false;
      for (var i = 0; i < bytes.length; i++) {
        if (head[i] != bytes[i]) return false;
      }
      return true;
    }

    String ascii(int offset, int count) {
      if (head.length < offset + count) return '';
      return String.fromCharCodes(head.sublist(offset, offset + count));
    }

    // JPEG: FF D8 ... FF D9 (EOI).
    if (startsWith([0xFF, 0xD8])) {
      if (len < 2) {
        return const _Verification(ok: false, reason: 'file JPEG quá ngắn');
      }
      await raf.setPosition(len - 2);
      final tail = await raf.read(2);
      if (tail.length < 2 || tail[0] != 0xFF || tail[1] != 0xD9) {
        return const _Verification(
          ok: false,
          reason: 'thiếu dấu kết thúc JPEG (FFD9)',
        );
      }
      return const _Verification(ok: true, detectedExt: 'jpg');
    }
    // PNG: signature 8 byte ... chunk IEND 12 byte cuối.
    if (startsWith([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
      if (len < 12) {
        return const _Verification(ok: false, reason: 'file PNG quá ngắn');
      }
      await raf.setPosition(len - 12);
      final tail = await raf.read(12);
      const iend = [
        0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, //
        0xAE, 0x42, 0x60, 0x82,
      ];
      for (var i = 0; i < 12; i++) {
        if (tail[i] != iend[i]) {
          return const _Verification(
            ok: false,
            reason: 'thiếu chunk IEND của PNG',
          );
        }
      }
      return const _Verification(ok: true, detectedExt: 'png');
    }
    // WebP: "RIFF" + kích thước (LE32 ở offset 4) + "WEBP".
    // File đầy đủ <=> độ dài file == 8 + kích thước RIFF.
    if (ascii(0, 4) == 'RIFF' && ascii(8, 4) == 'WEBP') {
      if (head.length < 12) {
        return const _Verification(ok: false, reason: 'file WebP quá ngắn');
      }
      final riffSize =
          head[4] |
          (head[5] << 8) |
          (head[6] << 16) |
          (head[7] << 24);
      if (len != 8 + riffSize) {
        return _Verification(
          ok: false,
          reason: 'WebP thiếu byte ($len/${8 + riffSize})',
        );
      }
      return const _Verification(ok: true, detectedExt: 'webp');
    }
    // GIF: "GIF87a"/"GIF89a" ... kết thúc byte 0x3B.
    if (ascii(0, 6) == 'GIF87a' || ascii(0, 6) == 'GIF89a') {
      await raf.setPosition(len - 1);
      final last = await raf.read(1);
      if (last.isEmpty || last[0] != 0x3B) {
        return const _Verification(
          ok: false,
          reason: 'thiếu byte kết thúc GIF (0x3B)',
        );
      }
      return const _Verification(ok: true, detectedExt: 'gif');
    }
    // AVIF: ...."ftyp" + brand "avif"/"avis" ở offset 8. Không có
    // marker kết thúc -> dựa vào Content-Length (đã kiểm ở trên).
    if (ascii(4, 4) == 'ftyp' &&
        (ascii(8, 4) == 'avif' || ascii(8, 4) == 'avis')) {
      return const _Verification(ok: true, detectedExt: 'avif');
    }
    return const _Verification(
      ok: false,
      reason: 'không nhận dạng được định dạng ảnh',
    );
  }
}

/// Kết quả kiểm tra file tải về: đầy đủ không + định dạng thật
/// phát hiện từ magic bytes + lý do nếu không đầy đủ.
class _Verification {
  const _Verification({required this.ok, this.detectedExt, this.reason});

  final bool ok;

  /// Định dạng thật của file (jpg/png/webp/gif/avif) — null khi
  /// không cần đổi đuôi (mp4, mp3, m4a, wav, ...).
  final String? detectedExt;

  /// Lý do không đầy đủ (hiện trong UI khi tải lỗi).
  final String? reason;
}
