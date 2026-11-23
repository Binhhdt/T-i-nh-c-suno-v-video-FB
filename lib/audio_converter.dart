import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';

/// Chuyển đổi audio NGAY TRÊN MÁY bằng ffmpeg (không cần server).
///
/// Vì sao cần: Suno KHÔNG công khai link MP3/WAV gốc khi chưa đăng nhập
/// (chỉ chủ bài nhạc mới tải WAV trong menu của Suno). File gốc tải
/// được từ trang công khai thường là .m4a (opus). Các trang tải Suno
/// (vd sunodownload.io) cũng làm y hệt: lấy file gốc rồi convert ra
/// MP3/WAV trên server của họ. App làm tương tự nhưng convert trên máy.
///
/// Lưu ý trung thực: file MP3/WAV sau chuyển đổi có chất lượng BẰNG
/// file gốc (nguồn lossy), không tăng thêm chất lượng — UI phải ghi rõ.
///
/// QUAN TRỌNG (bug 15/10): file Suno tải về từ `media_urls` ĐƯỢC MÃ HOÁ
/// AES (toàn bộ file là ciphertext, không có cấu trúc MP4). Phải giải mã
/// bằng [suno_crypto] TRƯỚC khi đưa vào đây — ffmpeg không bao giờ
/// convert được file chưa giải mã ("moov atom not found").
class ConvertResult {
  const ConvertResult({
    required this.ok,
    this.returnCode,
    this.errorOutput = '',
  });

  /// true khi ffmpeg chạy thành công VÀ file đích tồn tại.
  final bool ok;

  /// Mã trả về của ffmpeg (0 = thành công), null nếu không chạy được.
  final int? returnCode;

  /// Vài dòng cuối của log ffmpeg khi lỗi — để UI hiển thị LỖI THẬT
  /// thay vì thông báo chung chung "Không chuyển đổi được".
  final String errorOutput;
}

class AudioConverter {
  /// Chuyển đổi [inputPath] -> [outputPath] theo [format] ('mp3' | 'wav').
  /// Không throw — lỗi nào cũng trả về [ConvertResult.ok] = false kèm
  /// mã lỗi + log ffmpeg để phía gọi hiển thị và giữ file gốc.
  Future<ConvertResult> convert({
    required String inputPath,
    required String outputPath,
    required String format,
  }) async {
    final args = format == 'wav'
        // WAV: PCM 16-bit 44.1kHz, bỏ video stream nếu có.
        ? ['-y', '-i', inputPath, '-vn', '-codec:a', 'pcm_s16le', '-ar',
            '44100', outputPath]
        // MP3: libmp3lame VBR chất lượng cao (~190kbps, q:a 2).
        : ['-y', '-i', inputPath, '-vn', '-codec:a', 'libmp3lame', '-q:a',
            '2', outputPath];
    try {
      // ffmpeg KHÔNG tự tạo thư mục cha — file đích nằm trong thư mục
      // chưa tồn tại sẽ lỗi "No such file or directory". Tạo trước.
      await Directory(outputPath).parent.create(recursive: true);
      final session = await FFmpegKit.executeWithArguments(args);
      final returnCode = await session.getReturnCode();
      final codeValue = returnCode?.getValue();
      if (ReturnCode.isSuccess(returnCode) &&
          File(outputPath).existsSync()) {
        return ConvertResult(ok: true, returnCode: codeValue);
      }
      final output = await session.getOutput() ?? '';
      return ConvertResult(
        ok: false,
        returnCode: codeValue,
        errorOutput: _lastLines(output, 8),
      );
    } catch (e) {
      return ConvertResult(ok: false, errorOutput: e.toString());
    }
  }

  /// Lấy vài dòng cuối (không rỗng) của log, giới hạn độ dài để UI
  /// hiển thị gọn. Bỏ dòng "frame=..." tiến độ của ffmpeg.
  static String _lastLines(String output, int count) {
    final lines = output
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('frame='))
        .toList();
    if (lines.isEmpty) return '';
    final tail = lines.sublist(
      lines.length > count ? lines.length - count : 0,
    );
    const maxChars = 400;
    var joined = tail.join(' | ');
    if (joined.length > maxChars) {
      joined = '...${joined.substring(joined.length - maxChars)}';
    }
    return joined;
  }
}

/// Tên file đích sau chuyển đổi: giữ phần tên gốc, đổi đuôi theo format.
/// 'suno_123_source.m4a' + 'mp3' -> 'suno_123.mp3'
/// 'suno_123_source.mp3' + 'wav' -> 'suno_123.wav'
/// 'suno_123.m4a' + 'mp3' -> 'suno_123.mp3'
String convertedFileName(String sourceFileName, String targetFormat) {
  var name = sourceFileName;
  final dot = name.lastIndexOf('.');
  if (dot > 0) name = name.substring(0, dot);
  if (name.endsWith('_source')) {
    name = name.substring(0, name.length - '_source'.length);
  }
  return '$name.$targetFormat';
}

/// Có cần chuyển đổi không: chỉ khi đuôi gốc khác định dạng đích.
/// 'm4a' -> 'mp3': true. 'mp3' -> 'mp3': false. 'wav' -> 'wav': false.
bool needsConversion(String sourceExtension, String targetFormat) =>
    sourceExtension.toLowerCase() != targetFormat.toLowerCase();
