import 'dart:async';
import 'dart:io';

import 'package:fb_video_downloader/comic/cbz_writer.dart';
import 'package:fb_video_downloader/comic/comic_downloader.dart';
import 'package:fb_video_downloader/comic/comic_log.dart';
import 'package:fb_video_downloader/comic/comic_models.dart';
import 'package:fb_video_downloader/comic/comic_scanner.dart';
import 'package:fb_video_downloader/comic/image_validator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// JPEG hợp lệ tối giản (đủ dài, có FFD8 ... FFD9).
List<int> jpeg([int fill = 2000]) =>
    [0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(fill, 0x11), 0xFF, 0xD9];

/// Máy chủ giả: trả theo danh sách kịch bản cho từng URL.
class FakeClient extends http.BaseClient {
  FakeClient(this.routes);
  final Map<String, List<(int, String, List<int>)>> routes;
  final calls = <String, int>{};
  final seenHeaders = <String, Map<String, String>>{};

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final url = request.url.toString();
    final n = calls[url] = (calls[url] ?? 0) + 1;
    seenHeaders[url] = Map.of(request.headers);
    final script = routes[url] ?? [(404, 'text/plain', <int>[])];
    final k = n - 1 < script.length ? n - 1 : script.length - 1;
    final (code, ct, body) = script[k];
    return http.StreamedResponse(
      Stream.value(body),
      code,
      contentLength: body.length,
      headers: {'content-type': ct},
    );
  }
}

void main() {
  const base = 'https://site.test/truyen/chap-12';

  group('ComicScanner', () {
    test('srcset chọn ảnh lớn nhất', () {
      expect(
        ComicScanner.bestFromSrcset('/p4.jpg?w=300 300w, /p4.jpg 1080w'),
        '/p4.jpg',
      );
      expect(ComicScanner.bestFromSrcset('a.jpg 1x, b.jpg 2x'), 'b.jpg');
    });

    test('ưu tiên data-src / data-original hơn ảnh giữ chỗ', () {
      expect(
        ComicScanner.pickImgUrl(
          {'src': 'data:image/gif;base64,R0l', 'data-src': '/img/p2.jpg'},
          '',
          base,
        ),
        'https://site.test/img/p2.jpg',
      );
      expect(
        ComicScanner.pickImgUrl(
          {'src': '/static/loading.gif', 'data-original': 'img/p3.jpg'},
          '',
          base,
        ),
        'https://site.test/truyen/img/p3.jpg',
      );
    });

    test('DOM: chọn khung đọc truyện, giữ thứ tự, bỏ logo, giữ ảnh lazy', () {
      const reader = 'DIV.page<DIV#reader.reading-content<BODY';
      final imgs = <Map<String, dynamic>>[
        {'i': 0, 'sig': 'HEADER<BODY<HTML', 'nw': 40, 'nh': 40, 'w': 40, 'h': 40,
          'cur': 'https://site.test/logo.png', 'attrs': {'src': '/logo.png'}},
        {'i': 1, 'sig': reader, 'nw': 600, 'nh': 900, 'w': 400, 'h': 600,
          'cur': 'https://site.test/img/p1.jpg', 'attrs': {'src': '/img/p1.jpg'}},
        // lazy: đang hiện ảnh 1px -> không được loại nhầm
        {'i': 2, 'sig': reader, 'nw': 1, 'nh': 1, 'w': 16, 'h': 16,
          'cur': 'data:image/gif;base64,R0l',
          'attrs': {'src': 'data:image/gif;base64,R0l', 'data-src': '/img/p2.jpg'}},
        {'i': 3, 'sig': reader, 'nw': 0, 'nh': 0, 'w': 0, 'h': 0, 'cur': '',
          'attrs': {'data-src': '/img/p3.jpg'}},
      ];
      final r = ComicScanner.fromDom(imgs, base);
      expect(r.images.map((e) => e.url.split('/').last).toList(),
          ['p1.jpg', 'p2.jpg', 'p3.jpg']);
      expect(r.images.map((e) => e.baseName).toList(), ['001', '002', '003']);
    });

    test('DOM: xếp theo data-index khi mọi ảnh đều có', () {
      const g = 'DIV<DIV#r<BODY';
      final imgs = [
        for (final (i, idx) in [(0, 3), (1, 1), (2, 2)])
          <String, dynamic>{'i': i, 'sig': g, 'nw': 0, 'nh': 0, 'w': 0, 'h': 0,
            'cur': '', 'attrs': {'data-src': '/p$idx.jpg', 'data-index': '$idx'}},
      ];
      final r = ComicScanner.fromDom(imgs, base);
      expect(r.images.map((e) => e.url.split('/').last).toList(),
          ['p1.jpg', 'p2.jpg', 'p3.jpg']);
    });

    test('JSON: lấy mảng ảnh theo thứ tự, bỏ mảng 1 phần tử', () {
      const text = '{"chapter":{"pages":[{"url":"/img/p1.jpg"},'
          '{"url":"/img/p2.jpg"},{"url":"/img/p3.jpg"}]},'
          '"related":[{"thumb":"/img/x.png"}]}';
      final lists = ComicScanner.listsFromText(text, base);
      expect(lists.length, 1);
      expect(lists.first.map((u) => u.split('/').last).toList(),
          ['p1.jpg', 'p2.jpg', 'p3.jpg']);
    });

    test('script JS thường: gom link ảnh trong ngoặc kép', () {
      const text = r'var pages = ["https:\/\/cdn.test\/a\/1.webp",'
          r' "https:\/\/cdn.test\/a\/2.webp"];';
      final lists = ComicScanner.listsFromText(text, base);
      expect(lists.single, [
        'https://cdn.test/a/1.webp',
        'https://cdn.test/a/2.webp',
      ]);
    });

    test('analyze: JSON đầy đủ hơn DOM (trang chưa render hết) -> dùng JSON', () {
      const g = 'DIV<DIV#r<BODY';
      final raw = <String, dynamic>{
        'url': base,
        'title': 'Chap 12',
        'ua': 'UA',
        'imgs': [
          for (var i = 1; i <= 3; i++)
            {'i': i, 'sig': g, 'nw': 600, 'nh': 900, 'w': 400, 'h': 600,
              'cur': 'https://site.test/img/p$i.jpg', 'attrs': {'src': '/img/p$i.jpg'}},
        ],
        'scripts': [],
        'apis': [
          {
            'url': 'https://site.test/api',
            'body': '{"images":["/img/p1.jpg","/img/p2.jpg","/img/p3.jpg",'
                '"/img/p4.jpg","/img/p5.jpg"]}',
          },
        ],
        'errors': [],
      };
      final r = ComicScanner.analyze(raw);
      expect(r.images.length, 5);
      expect(r.images.first.source, 'json');
      expect(r.chosenSource, contains('JSON'));
    });
  });

  group('Nhận diện trang không phải chapter', () {
    Map<String, dynamic> img(int i, String sig, String src, {String link = ''}) => {
          'i': i, 'sig': sig, 'nw': 600, 'nh': 900, 'w': 300, 'h': 450,
          'cur': 'https://site.test$src', 'attrs': {'src': src}, 'link': link,
        };

    test('trang giới thiệu: lưới ảnh bìa có link -> cảnh báo', () {
      const g = 'DIV.image-box<DIV.product-item<DIV.product-grid';
      final r = ComicScanner.analyze({
        'url': base, 'title': 'Truyện [Tới Chap 35]', 'ua': '',
        'imgs': [
          img(0, g, '/c1.jpg', link: 'https://site.test/truyen-x'),
          img(1, g, '/c2.jpg', link: 'https://site.test/truyen-y'),
          img(2, g, '/c3.jpg', link: 'https://site.test/truyen-z'),
        ],
        'scripts': [], 'apis': [], 'errors': [],
      });
      expect(r.warning, isNotNull);
      expect(r.warning, contains('GIỚI THIỆU'));
    });

    test('trang chapter có thanh bên ảnh bìa: chọn khung chapter, không cảnh báo', () {
      const side = 'DIV.item<ASIDE.side<BODY';
      const reader = 'DIV.pc<DIV#chapter<BODY';
      final r = ComicScanner.analyze({
        'url': base, 'title': 'Chap 1', 'ua': '',
        'imgs': [
          for (var i = 0; i < 4; i++)
            img(i, side, '/t$i.jpg', link: 'https://site.test/truyen-$i'),
          for (var i = 1; i <= 3; i++) img(10 + i, reader, '/p$i.jpg'),
        ],
        'scripts': [], 'apis': [], 'errors': [],
      });
      expect(r.images.map((e) => e.url.split('/').last).toList(),
          ['p1.jpg', 'p2.jpg', 'p3.jpg']);
      expect(r.warning, isNull);
    });
  });

  group('Danh sách chapter', () {
    test('đọc số chapter', () {
      expect(ComicScanner.chapterNumber('Chương 12'), 12);
      expect(ComicScanner.chapterNumber('Chapter 3.5'), 3.5);
      expect(ComicScanner.chapterNumber('abc-chap-12-5'), 12.5);
      expect(ComicScanner.chapterNumber('Đọc từ đầu'), isNull);
    });

    test('lọc đúng bộ truyện, gộp trùng, xếp tăng dần', () {
      const page = 'https://site.test/truyen-tranh/abc-truyen-hay-123';
      final links = <Map<String, dynamic>>[
        {'href': '/truyen-tranh/abc-truyen-hay-123-chap-1', 'text': 'Đọc từ đầu'},
        {'href': '/truyen-tranh/abc-truyen-hay-123-chap-12-5', 'text': 'Chương 12.5'},
        {'href': '/truyen-tranh/abc-truyen-hay-123-chap-12', 'text': 'Chương 12'},
        {'href': '/truyen-tranh/abc-truyen-hay-123-chap-2', 'text': 'Chương 2'},
        {'href': '/truyen-tranh/abc-truyen-hay-123-chap-1', 'text': 'Chương 1'},
        // truyện khác (thẻ gợi ý)
        {'href': '/truyen-tranh/xyz-khac-9-chap-120', 'text': 'Chapter 120'},
        {'href': '/truyen-tranh/qwe-khac-7-chap-88', 'text': 'Chapter 88'},
        // trang web khác
        {'href': 'https://other.test/chap-5', 'text': 'Chap 5'},
      ];
      final chs = ComicScanner.chapterLinksFrom(links, page);
      expect(chs.map((c) => c.numberLabel).toList(), ['1', '2', '12', '12.5']);
      expect(chs.first.title, 'Chương 1');
    });

    test('analyze: trang giới thiệu trả về danh sách chapter', () {
      const page = 'https://site.test/truyen-tranh/abc-truyen-hay-123';
      final r = ComicScanner.analyze({
        'url': page, 'title': 'ABC', 'ua': '',
        'imgs': [], 'scripts': [], 'apis': [], 'errors': [],
        'links': [
          {'href': '$page-chap-1', 'text': 'Chương 1'},
          {'href': '$page-chap-2', 'text': 'Chương 2'},
        ],
      });
      expect(r.images, isEmpty);
      expect(r.chapters.length, 2);
    });
  });

  group('ImageValidator', () {
    test('nhận dạng định dạng thật', () {
      expect(ImageValidator.sniffExtension([0xFF, 0xD8, 0xFF, 0xE0]), 'jpg');
      expect(ImageValidator.sniffExtension('RIFF\x00\x00\x00\x00WEBP'.codeUnits), 'webp');
      expect(ImageValidator.sniffExtension('<html>'.codeUnits), isNull);
    });

    test('Content-Type: HTML bị từ chối, octet-stream + ảnh thật được', () {
      expect(ImageValidator.checkContentType('text/html; charset=utf-8', '<html'.codeUnits),
          isNotNull);
      expect(ImageValidator.checkContentType('application/octet-stream', [0xFF, 0xD8, 0xFF]),
          isNull);
      expect(ImageValidator.checkContentType('image/webp', const []), isNull);
    });
  });

  group('ComicDownloader', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('comic'));
    tearDown(() async => dir.delete(recursive: true));

    test('retry khi 503, chặn HTML, bỏ qua file đã có, đặt tên 001...', () async {
      final client = FakeClient({
        'https://cdn.test/1.jpg': [(503, 'text/plain', <int>[]), (200, 'image/jpeg', jpeg())],
        'https://cdn.test/2.jpg': [(200, 'text/html', '<html>blocked</html>'.codeUnits)],
        'https://cdn.test/3.jpg': [(200, 'image/jpeg', jpeg())],
      });
      // Trang 3 đã có sẵn & hợp lệ -> không tải lại.
      await File('${dir.path}/003.jpg').writeAsBytes(jpeg());
      final log = ComicLog();
      final dl = ComicDownloader(
        client: client,
        retryBaseDelay: const Duration(milliseconds: 1),
      );
      final images = [
        for (var i = 0; i < 3; i++)
          ChapterImage(index: i, url: 'https://cdn.test/${i + 1}.jpg', source: 'dom'),
      ];
      final report = await dl.downloadAll(
        images: images,
        dir: dir,
        referer: base,
        userAgent: 'TestUA',
        log: log,
      );
      expect(report.results[0].state, PageState.done);
      expect(report.results[0].attempts, 2);
      expect(File('${dir.path}/001.jpg').existsSync(), isTrue);
      expect(report.results[1].state, PageState.failed);
      expect(report.results[1].reason, contains('HTML'));
      expect(File('${dir.path}/002.part').existsSync(), isFalse);
      expect(report.results[2].state, PageState.skipped);
      expect(client.calls['https://cdn.test/3.jpg'], isNull);
      expect(client.seenHeaders['https://cdn.test/1.jpg']!['Referer'], base);
      expect(log.lines.any((l) => l.contains('cdn.test/2.jpg')), isTrue);
      expect(report.filesInOrder.length, 2);
    });
  });

  group('CbzWriter', () {
    test('CRC-32 chuẩn', () {
      expect(CbzWriter.crc32('123456789'.codeUnits), 0xCBF43926);
    });

    test('ghi CBZ có chữ ký ZIP + ComicInfo', () async {
      final dir = await Directory.systemTemp.createTemp('cbz');
      final f1 = File('${dir.path}/001.jpg')..writeAsBytesSync(jpeg());
      final f2 = File('${dir.path}/002.jpg')..writeAsBytesSync(jpeg(3000));
      final out = '${dir.path}/a.cbz';
      await CbzWriter.write(out, [f1, f2], title: 'Chap <1>');
      final bytes = await File(out).readAsBytes();
      expect(bytes.sublist(0, 4), [0x50, 0x4B, 0x03, 0x04]);
      final text = String.fromCharCodes(bytes);
      expect(text.contains('001.jpg'), isTrue);
      expect(text.contains('ComicInfo.xml'), isTrue);
      expect(text.contains('Chap &lt;1&gt;'), isTrue);
      await dir.delete(recursive: true);
    });
  });
}
