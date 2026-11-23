import 'package:fb_video_downloader/video_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final extractor = FacebookVideoExtractor();

  test('og:video được ưu tiên và lấy đúng thumbnail', () {
    const html = '''
<html><head>
<meta property="og:video" content="https://scontent.fbcdn.net/v/video.mp4?x=1" />
<meta property="og:image" content="https://scontent.fbcdn.net/thumb.jpg" />
</head><body></body></html>
''';
    final info = extractor.parseHtml(html);
    expect(info.candidates.length, 1);
    expect(info.best.url, 'https://scontent.fbcdn.net/v/video.mp4?x=1');
    expect(info.thumbnailUrl, 'https://scontent.fbcdn.net/thumb.jpg');
  });

  test('URL fbcdn bị escape \\/ được giải mã và dedupe', () {
    const html = r'''
<html><body>
"playable_url":"https:\/\/scontent.fsgn5-1.fna.fbcdn.net\/v\/t42.1790-2\/12345\/video_sd.mp4?efg=1"
"playable_url":"https:\/\/scontent.fsgn5-1.fna.fbcdn.net\/v\/t42.1790-2\/12345\/video_sd.mp4?efg=1"
"playable_url":"https:\/\/scontent.fsgn5-1.fna.fbcdn.net\/v\/t42.1790-2\/12345\/video_hd_720.mp4?efg=2"
</body></html>
''';
    final info = extractor.parseHtml(html);
    // Trùng nhau bị loại; tên URL không xác định chất lượng.
    expect(info.candidates.length, 2);
    expect(info.candidates.every((c) => c.qualityScore == 0), isTrue);
  });

  test('Không có mp4 -> báo lỗi tiếng Việt rõ ràng', () {
    const html = '<html><body>Không có video ở đây</body></html>';
    expect(
      () => extractor.parseHtml(html),
      throwsA(
        isA<VideoNotFoundException>().having(
          (e) => e.message,
          'message',
          contains('Không tìm thấy video'),
        ),
      ),
    );
  });

  test('parseRenderedPage dùng src thẻ <video> dù HTML thô không có mp4', () {
    const html = '<html><head></head><body>Trang render bằng JS</body></html>';
    final info = extractor.parseRenderedPage(html, [
      'https://scontent.fbcdn.net/v/video_720.mp4?x=1',
      'https://scontent.fbcdn.net/v/video_360.mp4?x=2',
    ]);
    expect(info.candidates.length, 2);
    expect(info.best.qualityLabel, 'Chưa rõ độ phân giải');
  });

  test('parseRenderedPage dedupe src DOM trùng link trong HTML', () {
    const html = r'''
<html><body>
"playable_url":"https:\/\/scontent.fbcdn.net\/v\/video_720.mp4?x=1"
</body></html>
''';
    final info = extractor.parseRenderedPage(html, [
      'https://scontent.fbcdn.net/v/video_720.mp4?x=1',
    ]);
    expect(info.candidates.length, 1);
  });

  test('parseRenderedPage không có video nào -> báo lỗi tiếng Việt', () {
    const html = '<html><body>Không có video</body></html>';
    expect(
      () => extractor.parseRenderedPage(html, []),
      throwsA(isA<VideoNotFoundException>()),
    );
    expect(
      () => extractor.parseRenderedPage(html, ['blob:https://x/abc']),
      throwsA(isA<VideoNotFoundException>()),
    );
  });

  test('normalizeUrl thêm https:// khi thiếu scheme', () {
    expect(
      extractor.normalizeUrl('facebook.com/watch/?v=123'),
      'https://facebook.com/watch/?v=123',
    );
  });

  test('lấy tiêu đề từ og:title để đặt tên file', () {
    const html = '''
<html><head>
<meta property="og:video" content="https://scontent.fbcdn.net/v/video.mp4" />
<meta property="og:title" content="Mưa trên phố - Ca sĩ A" />
</head><body></body></html>
''';
    final info = extractor.parseHtml(html);
    expect(info.title, 'Mưa trên phố - Ca sĩ A');
  });

  test('bỏ hậu tố " | Facebook" và tiêu đề chung chung', () {
    const html = '''
<html><head>
<meta property="og:video" content="https://scontent.fbcdn.net/v/video.mp4" />
<title>Clip vui | Facebook</title>
</head><body></body></html>
''';
    expect(extractor.parseHtml(html).title, 'Clip vui');

    const generic = '''
<html><head>
<meta property="og:video" content="https://scontent.fbcdn.net/v/video.mp4" />
<title>Facebook</title>
</head><body></body></html>
''';
    expect(extractor.parseHtml(generic).title, isNull);
  });

  test('không có tiêu đề -> null (caller fallback fb_video_<ts>)', () {
    const html = '''
<html><head>
<meta property="og:video" content="https://scontent.fbcdn.net/v/video.mp4" />
</head><body></body></html>
''';
    expect(extractor.parseHtml(html).title, isNull);
  });
}
