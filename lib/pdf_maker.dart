import 'dart:convert' show latin1;
import 'dart:io';
import 'dart:typed_data';

/// Ghép ảnh thành 1 file PDF — thuần Dart, KHÔNG cần thư viện ngoài.
///
/// - Ảnh JPEG được nhét NGUYÊN VẸN vào PDF (DCTDecode): không nén lại,
///   không giảm chất lượng, file PDF nhẹ ≈ tổng dung lượng ảnh.
/// - Ảnh khác (WebP, PNG, ...) do app giải mã ra điểm ảnh RGB rồi nén
///   không mất dữ liệu (FlateDecode).
/// - Mỗi ảnh = 1 trang, trang có đúng tỉ lệ của ảnh (rộng 595pt = A4),
///   không viền, không cắt ảnh.

/// Dữ liệu 1 ảnh đã sẵn sàng để nhét vào PDF.
class PdfImageData {
  const PdfImageData({
    required this.width,
    required this.height,
    required this.bytes,
    required this.filter,
    required this.colorSpace,
    this.decode,
  });

  final int width;
  final int height;
  final List<int> bytes;

  /// 'DCTDecode' (JPEG) hoặc 'FlateDecode' (RGB đã nén zlib).
  final String filter;

  /// 'DeviceRGB' / 'DeviceGray' / 'DeviceCMYK'.
  final String colorSpace;

  /// Mảng /Decode (JPEG CMYK của Adobe bị đảo màu).
  final String? decode;
}

/// Kích thước + số kênh màu đọc từ marker SOF của JPEG.
class JpegInfo {
  const JpegInfo(this.width, this.height, this.components);
  final int width;
  final int height;
  final int components;
}

/// Đọc kích thước JPEG (marker SOF0..SOF15, trừ DHT/JPG/DAC).
/// null nếu không phải JPEG hợp lệ.
JpegInfo? readJpegInfo(List<int> b) {
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;
  var i = 2;
  while (i + 9 < b.length) {
    if (b[i] != 0xFF) {
      i++;
      continue;
    }
    final m = b[i + 1];
    if (m == 0xFF) {
      i++;
      continue;
    }
    if (m == 0xD8 || m == 0x01 || (m >= 0xD0 && m <= 0xD7)) {
      i += 2;
      continue;
    }
    if (m == 0xD9 || m == 0xDA) break;
    final len = (b[i + 2] << 8) | b[i + 3];
    final isSof = m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC;
    if (isSof) {
      final h = (b[i + 5] << 8) | b[i + 6];
      final w = (b[i + 7] << 8) | b[i + 8];
      final c = b[i + 9];
      if (w <= 0 || h <= 0) return null;
      return JpegInfo(w, h, c);
    }
    i += 2 + len;
  }
  return null;
}

/// JPEG -> dữ liệu PDF (giữ nguyên byte). null nếu không phải JPEG.
PdfImageData? jpegToPdfImage(List<int> bytes) {
  final info = readJpegInfo(bytes);
  if (info == null) return null;
  final String cs;
  String? decode;
  switch (info.components) {
    case 1:
      cs = 'DeviceGray';
    case 4:
      cs = 'DeviceCMYK';
      decode = '[1 0 1 0 1 0 1 0]';
    default:
      cs = 'DeviceRGB';
  }
  return PdfImageData(
    width: info.width,
    height: info.height,
    bytes: bytes,
    filter: 'DCTDecode',
    colorSpace: cs,
    decode: decode,
  );
}

/// Điểm ảnh RGBA (từ bộ giải mã ảnh) -> dữ liệu PDF RGB nén zlib.
PdfImageData rgbaToPdfImage(Uint8List rgba, int width, int height) {
  final rgb = Uint8List(width * height * 3);
  for (var p = 0, q = 0; p + 3 < rgba.length && q + 2 < rgb.length; p += 4) {
    // Nền trắng cho điểm ảnh trong suốt (PNG có alpha).
    final a = rgba[p + 3];
    if (a == 255) {
      rgb[q++] = rgba[p];
      rgb[q++] = rgba[p + 1];
      rgb[q++] = rgba[p + 2];
    } else {
      rgb[q++] = (rgba[p] * a + 255 * (255 - a)) ~/ 255;
      rgb[q++] = (rgba[p + 1] * a + 255 * (255 - a)) ~/ 255;
      rgb[q++] = (rgba[p + 2] * a + 255 * (255 - a)) ~/ 255;
    }
  }
  return PdfImageData(
    width: width,
    height: height,
    bytes: zlib.encode(rgb),
    filter: 'FlateDecode',
    colorSpace: 'DeviceRGB',
  );
}

/// Ghi file PDF gồm [pageCount] trang, mỗi trang 1 ảnh lấy từ
/// [loadPage] (null = ảnh lỗi -> bỏ qua trang đó). Đọc từng ảnh một nên
/// không tốn bộ nhớ dù nhiều ảnh. Trả về số trang thực sự ghi được.
Future<int> writeImagesPdf({
  required String outPath,
  required int pageCount,
  required Future<PdfImageData?> Function(int index) loadPage,
  void Function(int done)? onProgress,
}) async {
  final file = File(outPath);
  final sink = file.openWrite();
  var offset = 0;
  final offsets = <int, int>{}; // id object -> vị trí byte

  void writeBytes(List<int> bytes) {
    sink.add(bytes);
    offset += bytes.length;
  }

  void writeText(String s) => writeBytes(latin1.encode(s));

  var nextId = 3; // 1 = Catalog, 2 = Pages (ghi cuối cùng)
  final pageIds = <int>[];

  try {
    writeText('%PDF-1.4\n');
    writeBytes(const [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]);

    offsets[1] = offset;
    writeText('1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n');

    for (var i = 0; i < pageCount; i++) {
      PdfImageData? img;
      try {
        img = await loadPage(i);
      } catch (_) {
        img = null;
      }
      if (img != null && img.width > 0 && img.height > 0) {
        final imageId = nextId++;
        final contentId = nextId++;
        final pageId = nextId++;
        const pageW = 595.0;
        final pageH = pageW * img.height / img.width;
        final w = pageW.toStringAsFixed(2);
        final h = pageH.toStringAsFixed(2);

        offsets[imageId] = offset;
        final decode = img.decode != null ? ' /Decode ${img.decode}' : '';
        writeText('$imageId 0 obj\n<< /Type /XObject /Subtype /Image '
            '/Width ${img.width} /Height ${img.height} '
            '/ColorSpace /${img.colorSpace} /BitsPerComponent 8 '
            '/Filter /${img.filter}$decode /Length ${img.bytes.length} >>\n'
            'stream\n');
        writeBytes(img.bytes);
        writeText('\nendstream\nendobj\n');

        final content = 'q $w 0 0 $h 0 0 cm /Im0 Do Q';
        offsets[contentId] = offset;
        writeText('$contentId 0 obj\n<< /Length ${content.length} >>\n'
            'stream\n$content\nendstream\nendobj\n');

        offsets[pageId] = offset;
        writeText('$pageId 0 obj\n<< /Type /Page /Parent 2 0 R '
            '/MediaBox [0 0 $w $h] '
            '/Resources << /XObject << /Im0 $imageId 0 R >> >> '
            '/Contents $contentId 0 R >>\nendobj\n');
        pageIds.add(pageId);
      }
      onProgress?.call(i + 1);
    }

    offsets[2] = offset;
    writeText('2 0 obj\n<< /Type /Pages /Kids '
        '[${pageIds.map((id) => '$id 0 R').join(' ')}] '
        '/Count ${pageIds.length} >>\nendobj\n');

    final xrefPos = offset;
    final size = nextId;
    final xref = StringBuffer('xref\n0 $size\n0000000000 65535 f \n');
    for (var id = 1; id < size; id++) {
      final off = offsets[id] ?? 0;
      xref.write('${off.toString().padLeft(10, '0')} 00000 n \n');
    }
    writeText(xref.toString());
    writeText('trailer\n<< /Size $size /Root 1 0 R >>\n'
        'startxref\n$xrefPos\n%%EOF\n');
  } finally {
    await sink.flush();
    await sink.close();
  }

  if (pageIds.isEmpty) {
    try {
      await file.delete();
    } catch (_) {}
  }
  return pageIds.length;
}

/// So tên file "tự nhiên": anh_2 đứng trước anh_10.
int naturalCompare(String a, String b) {
  String key(String s) => s
      .toLowerCase()
      .replaceAllMapped(RegExp(r'\d+'), (m) => m.group(0)!.padLeft(12, '0'));
  return key(a).compareTo(key(b));
}
