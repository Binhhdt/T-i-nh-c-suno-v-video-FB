import 'dart:convert' show latin1;
import 'dart:io';
import 'dart:typed_data';

import 'package:fb_video_downloader/pdf_maker.dart';
import 'package:flutter_test/flutter_test.dart';

/// JPEG tối giản: SOI + APP0 + SOF0 (w x h, 3 kênh) + EOI.
List<int> fakeJpeg(int w, int h) => [
      0xFF, 0xD8, //
      0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, // APP0 độ dài 4
      0xFF, 0xC0, 0x00, 0x11, 0x08, //
      h >> 8, h & 0xFF, w >> 8, w & 0xFF, 0x03, //
      1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1, //
      0xFF, 0xD9,
    ];

void main() {
  test('đọc kích thước JPEG từ SOF', () {
    final info = readJpegInfo(fakeJpeg(800, 1200));
    expect(info, isNotNull);
    expect(info!.width, 800);
    expect(info.height, 1200);
    expect(info.components, 3);
    expect(readJpegInfo([0x89, 0x50, 0x4E, 0x47]), isNull);
  });

  test('sắp tên file tự nhiên: anh_2 trước anh_10', () {
    final names = ['anh_10.jpg', 'anh_2.jpg', 'anh_001.jpg'];
    names.sort(naturalCompare);
    expect(names, ['anh_001.jpg', 'anh_2.jpg', 'anh_10.jpg']);
  });

  test('ghi PDF: bỏ trang lỗi, đúng số trang, có xref', () async {
    final dir = await Directory.systemTemp.createTemp('pdf_test');
    final out = '${dir.path}/a.pdf';
    final pages = await writeImagesPdf(
      outPath: out,
      pageCount: 3,
      loadPage: (i) async {
        if (i == 1) return null; // ảnh lỗi
        if (i == 2) {
          return rgbaToPdfImage(Uint8List.fromList(List.filled(2 * 2 * 4, 200)), 2, 2);
        }
        return jpegToPdfImage(fakeJpeg(100, 150));
      },
    );
    expect(pages, 2);
    final text = latin1.decode(await File(out).readAsBytes());
    expect(text.startsWith('%PDF-1.4'), isTrue);
    expect(text.contains('/Count 2'), isTrue);
    expect(text.contains('/Filter /DCTDecode'), isTrue);
    expect(text.contains('/Filter /FlateDecode'), isTrue);
    expect(text.trimRight().endsWith('%%EOF'), isTrue);
    await dir.delete(recursive: true);
  });
}
