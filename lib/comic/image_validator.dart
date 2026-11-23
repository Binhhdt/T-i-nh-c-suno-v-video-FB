import 'dart:io';

/// Kiểm tra file ảnh tải về: Content-Type, kích thước, định dạng thật
/// (magic bytes) và dấu kết thúc file (phát hiện file bị cụt).
class ImageValidator {
  /// Nhỏ hơn mức này coi như không phải trang truyện (ảnh lỗi, pixel).
  static const minBytes = 1024;

  /// Lớn hơn mức này coi như bất thường (không phải 1 trang ảnh).
  static const maxBytes = 60 * 1024 * 1024;

  /// Đuôi file đúng theo magic bytes; null nếu không nhận ra là ảnh.
  static String? sniffExtension(List<int> head) {
    bool starts(List<int> sig, [int offset = 0]) {
      if (head.length < offset + sig.length) return false;
      for (var i = 0; i < sig.length; i++) {
        if (head[offset + i] != sig[i]) return false;
      }
      return true;
    }

    String ascii(int offset, int count) {
      if (head.length < offset + count) return '';
      return String.fromCharCodes(head.sublist(offset, offset + count));
    }

    if (starts([0xFF, 0xD8, 0xFF])) return 'jpg';
    if (starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) return 'png';
    if (ascii(0, 4) == 'RIFF' && ascii(8, 4) == 'WEBP') return 'webp';
    if (ascii(0, 6) == 'GIF87a' || ascii(0, 6) == 'GIF89a') return 'gif';
    if (ascii(4, 4) == 'ftyp' &&
        (ascii(8, 4) == 'avif' || ascii(8, 4) == 'avis')) {
      return 'avif';
    }
    if (starts([0x42, 0x4D])) return 'bmp';
    return null;
  }

  /// Content-Type có chấp nhận được không. `image/*` luôn được; kiểu
  /// chung chung (octet-stream, binary, trống) được nếu magic bytes là
  /// ảnh. Trả về lý do lỗi, hoặc null nếu ổn.
  static String? checkContentType(String? contentType, List<int> head) {
    final ct = (contentType ?? '').toLowerCase().split(';').first.trim();
    if (ct.startsWith('image/')) return null;
    const generic = {
      '',
      'application/octet-stream',
      'binary/octet-stream',
      'application/binary',
      'application/x-binary',
    };
    if (generic.contains(ct) && sniffExtension(head) != null) return null;
    if (ct.contains('html')) {
      return 'máy chủ trả về trang HTML thay vì ảnh (Content-Type: $ct) — có '
          'thể link hết hạn, cần mở trang trước, hoặc trang chặn tải ngoài';
    }
    return 'Content-Type không phải ảnh: "${ct.isEmpty ? '(trống)' : ct}"';
  }

  /// Kiểm tra file trên đĩa: kích thước + định dạng + dấu kết thúc.
  /// Trả về (ext, null) nếu hợp lệ, (null, lý do) nếu không.
  static Future<({String? ext, String? error})> validateFile(
    File file, {
    int? expectedLength,
  }) async {
    if (!await file.exists()) return (ext: null, error: 'file không tồn tại');
    final raf = await file.open();
    try {
      final len = await raf.length();
      if (len < minBytes) {
        return (ext: null, error: 'file quá nhỏ ($len byte)');
      }
      if (len > maxBytes) {
        return (ext: null, error: 'file quá lớn ($len byte)');
      }
      if (expectedLength != null && expectedLength > 0 && len != expectedLength) {
        return (ext: null, error: 'thiếu byte ($len/$expectedLength)');
      }
      final head = await raf.read(32);
      final ext = sniffExtension(head);
      if (ext == null) {
        return (ext: null, error: 'không phải file ảnh (magic bytes lạ)');
      }
      final tailLen = len < 16 ? len : 16;
      await raf.setPosition(len - tailLen);
      final tail = await raf.read(tailLen);
      final cut = _truncationReason(ext, head, tail, len);
      if (cut != null) return (ext: null, error: cut);
      return (ext: ext, error: null);
    } finally {
      await raf.close();
    }
  }

  /// Phát hiện file cụt theo định dạng. null = đầy đủ.
  static String? _truncationReason(
    String ext,
    List<int> head,
    List<int> tail,
    int len,
  ) {
    switch (ext) {
      case 'jpg':
        // Cho phép vài byte rác sau FFD9 (một số máy chủ thêm \n).
        for (var i = tail.length - 2; i >= 0; i--) {
          if (tail[i] == 0xFF && tail[i + 1] == 0xD9) return null;
        }
        return 'JPEG bị cụt (thiếu dấu kết thúc FFD9)';
      case 'png':
        final s = String.fromCharCodes(tail);
        return s.contains('IEND') ? null : 'PNG bị cụt (thiếu IEND)';
      case 'webp':
        if (head.length < 8) return 'WebP quá ngắn';
        final riff = head[4] | (head[5] << 8) | (head[6] << 16) | (head[7] << 24);
        return len >= 8 + riff ? null : 'WebP bị cụt ($len/${8 + riff})';
      case 'gif':
        return tail.isNotEmpty && tail.last == 0x3B
            ? null
            : 'GIF bị cụt (thiếu byte 0x3B)';
      default:
        return null; // avif/bmp: dựa vào Content-Length
    }
  }
}
