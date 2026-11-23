import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Ghi file CBZ (= file ZIP chứa ảnh theo thứ tự 001, 002, ...).
/// Thuần Dart, không cần thư viện: ảnh đã nén sẵn nên lưu kiểu STORE
/// (không nén lại) — nhanh, không giảm chất lượng, mọi app đọc truyện
/// (CDisplayEx, Perfect Viewer, Tachiyomi/Mihon...) đều mở được.
class CbzWriter {
  /// Ghi [files] (đúng thứ tự) vào [outPath]. Tên trong CBZ giữ tên file
  /// (001.jpg ...). Có thể kèm ComicInfo.xml (tiêu đề, số trang).
  static Future<void> write(
    String outPath,
    List<File> files, {
    String? title,
    String? sourceUrl,
    void Function(int done, int total)? onProgress,
  }) async {
    final out = File(outPath);
    final sink = out.openWrite();
    var offset = 0;
    final central = BytesBuilder();
    var count = 0;
    final now = DateTime.now();
    final dosTime = (now.hour << 11) | (now.minute << 5) | (now.second ~/ 2);
    final yearOff = now.year < 1980 ? 0 : (now.year > 2107 ? 127 : now.year - 1980);
    final dosDate = (yearOff << 9) | (now.month << 5) | now.day;

    void addEntry(String name, List<int> data) {
      final nameBytes = utf8.encode(name);
      final crc = crc32(data);
      final local = BytesBuilder()
        ..add(_u32(0x04034b50))
        ..add(_u16(20)) // version needed
        ..add(_u16(0x0800)) // cờ: tên file UTF-8
        ..add(_u16(0)) // method: STORE
        ..add(_u16(dosTime))
        ..add(_u16(dosDate))
        ..add(_u32(crc))
        ..add(_u32(data.length))
        ..add(_u32(data.length))
        ..add(_u16(nameBytes.length))
        ..add(_u16(0))
        ..add(nameBytes);
      final localBytes = local.takeBytes();
      central
        ..add(_u32(0x02014b50))
        ..add(_u16(20)) // version made by
        ..add(_u16(20)) // version needed
        ..add(_u16(0x0800))
        ..add(_u16(0))
        ..add(_u16(dosTime))
        ..add(_u16(dosDate))
        ..add(_u32(crc))
        ..add(_u32(data.length))
        ..add(_u32(data.length))
        ..add(_u16(nameBytes.length))
        ..add(_u16(0)) // extra
        ..add(_u16(0)) // comment
        ..add(_u16(0)) // disk
        ..add(_u16(0)) // internal attrs
        ..add(_u32(0)) // external attrs
        ..add(_u32(offset))
        ..add(nameBytes);
      sink.add(localBytes);
      sink.add(data);
      offset += localBytes.length + data.length;
      count++;
    }

    try {
      for (var i = 0; i < files.length; i++) {
        final f = files[i];
        final name = f.uri.pathSegments.isNotEmpty
            ? f.uri.pathSegments.last
            : '${(i + 1).toString().padLeft(3, '0')}.jpg';
        addEntry(name, await f.readAsBytes());
        onProgress?.call(i + 1, files.length);
      }
      addEntry(
        'ComicInfo.xml',
        utf8.encode(comicInfoXml(
          title: title,
          pageCount: files.length,
          web: sourceUrl,
        )),
      );
      final cd = central.takeBytes();
      sink.add(cd);
      // End of central directory.
      for (final part in [
        _u32(0x06054b50),
        _u16(0),
        _u16(0),
        _u16(count),
        _u16(count),
        _u32(cd.length),
        _u32(offset),
        _u16(0),
      ]) {
        sink.add(part);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
  }

  /// ComicInfo.xml tối giản (chuẩn ComicRack) để app đọc truyện hiện tên.
  static String comicInfoXml({String? title, int? pageCount, String? web}) {
    String esc(String s) => s
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;');
    final b = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="utf-8"?>')
      ..writeln('<ComicInfo xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
          'xmlns:xsd="http://www.w3.org/2001/XMLSchema">');
    if (title != null && title.isNotEmpty) {
      b.writeln('  <Title>${esc(title)}</Title>');
    }
    if (pageCount != null) b.writeln('  <PageCount>$pageCount</PageCount>');
    if (web != null && web.isNotEmpty) b.writeln('  <Web>${esc(web)}</Web>');
    b.writeln('</ComicInfo>');
    return b.toString();
  }

  static final List<int> _crcTable = List<int>.generate(256, (n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    return c;
  });

  /// CRC-32 (chuẩn ZIP).
  static int crc32(List<int> data) {
    var c = 0xFFFFFFFF;
    for (final b in data) {
      c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
    }
    return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  static Uint8List _u16(int v) =>
      Uint8List(2)..buffer.asByteData().setUint16(0, v & 0xFFFF, Endian.little);
  static Uint8List _u32(int v) => Uint8List(4)
    ..buffer.asByteData().setUint32(0, v & 0xFFFFFFFF, Endian.little);
}
