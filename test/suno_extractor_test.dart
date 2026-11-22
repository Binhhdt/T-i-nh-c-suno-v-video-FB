import 'package:fb_video_downloader/suno_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final extractor = SunoExtractor();

  test('media_urls .m4a + og:title/og:image -> audioUrl .m4a, wav null', () {
    const html = r'''
<html><head>
<meta property="og:title" content="Bai Hat Test" />
<meta property="og:image" content="https://cdn2.suno.ai/image_test.jpeg" />
</head><body>
<script>"media_urls":[{"url":"https:\/\/d2lwuy8qc234o3.cloudfront.net\/1\/clip\/abc.m4a","content_type":"m4a-opus"}]</script>
</body></html>
''';
    final info = extractor.parseHtml(html);
    expect(info.title, 'Bai Hat Test');
    expect(info.coverUrl, 'https://cdn2.suno.ai/image_test.jpeg');
    expect(
      info.audioUrl,
      'https://d2lwuy8qc234o3.cloudfront.net/1/clip/abc.m4a',
    );
    expect(info.audioExtension, 'm4a');
    expect(info.audioIsNotMp3, isTrue);
    expect(info.wavUrl, isNull);
  });

  test('media_urls có .mp3 thì ưu tiên .mp3 hơn .m4a', () {
    const html = r'''
<html><body>
<script>"media_urls":[
{"url":"https:\/\/d2lwuy8qc234o3.cloudfront.net\/1\/clip\/abc.m4a","content_type":"m4a-opus"},
{"url":"https:\/\/cdn1.suno.ai\/abc.mp3","content_type":"mp3"}
]</script>
</body></html>
''';
    final info = extractor.parseHtml(html);
    expect(info.audioUrl, 'https://cdn1.suno.ai/abc.mp3');
    expect(info.audioExtension, 'mp3');
    expect(info.audioIsNotMp3, isFalse);
  });

  test('audio_url "forbidden" bị bỏ qua, fallback sang media_urls', () {
    const html = r'''
<html><body>
<script>"audio_url":"https:\/\/studio-api.prod.suno.com\/api\/forbidden"</script>
<script>"media_urls":[{"url":"https:\/\/d2lwuy8qc234o3.cloudfront.net\/1\/clip\/abc.m4a","content_type":"m4a-opus"}]</script>
</body></html>
''';
    final info = extractor.parseHtml(html);
    expect(info.audioUrl.contains('forbidden'), isFalse);
    expect(info.audioUrl.endsWith('.m4a'), isTrue);
  });

  test('wav_url có trong JSON thì lấy được wavUrl', () {
    const html = r'''
<html><body>
<script>"media_urls":[{"url":"https:\/\/d2lwuy8qc234o3.cloudfront.net\/1\/clip\/abc.m4a","content_type":"m4a-opus"}]</script>
<script>"wav_url":"https:\/\/cdn1.suno.ai\/abc.wav"</script>
</body></html>
''';
    final info = extractor.parseHtml(html);
    expect(info.wavUrl, 'https://cdn1.suno.ai/abc.wav');
  });

  test('fallback quét link mp3 CDN Suno khi không có media_urls', () {
    const html = '''
<html><body>
Nghe thử: https://cdn1.suno.ai/abc123.mp3?x=1
File im lặng: https://cdn-o.suno.com/sil-100.mp3
</body></html>
''';
    final info = extractor.parseHtml(html);
    expect(info.audioUrl, 'https://cdn1.suno.ai/abc123.mp3?x=1');
  });

  test('không có audio nào -> báo lỗi tiếng Việt', () {
    const html = '<html><body>Trang trống, không có nhạc</body></html>';
    expect(
      () => extractor.parseHtml(html),
      throwsA(isA<SunoNotFoundException>().having(
        (e) => e.message,
        'message',
        contains('Không tìm thấy nhạc'),
      )),
    );
  });

  test('normalizeUrl: link không phải Suno -> lỗi', () {
    expect(
      () => extractor.normalizeUrl('https://www.facebook.com/watch?v=1'),
      throwsA(isA<SunoNotFoundException>()),
    );
    expect(
      () => extractor.normalizeUrl('https://suno.com/playlist/abc'),
      throwsA(isA<SunoNotFoundException>()),
    );
  });

  test('normalizeUrl: chấp nhận /song/, /s/, /embed/ và thêm https://', () {
    expect(
      extractor.normalizeUrl('suno.com/song/abc-123'),
      'https://suno.com/song/abc-123',
    );
    expect(
      extractor.normalizeUrl('https://suno.com/s/xyz'),
      'https://suno.com/s/xyz',
    );
    expect(
      extractor.normalizeUrl('https://www.suno.com/embed/abc'),
      'https://www.suno.com/embed/abc',
    );
  });

  test(
    'REGRESSION 15/10: link /s/ thật "Tình khúc ngày cũ" — trang Suno thật '
    'nhúng dữ liệu clip trong payload RSC với quote đã escape (\\"media_urls\\")',
    () {
      // Mô phỏng đúng hình thức trang thật (đã kiểm chứng bằng curl
      // https://suno.com/s/cz4CXGsdkW0KKCzz -> 302 -> /song/bc95fcc5-...):
      // mọi dấu " trong JSON đều là \" vì nằm trong self.__next_f.push(...).
      // Trước fix, extractor KHÔNG thấy media_urls vì _unescape không gỡ \".
      const html = r'''
<html><head>
<meta property="og:title" content="Tình khúc ngày cũ" />
<meta property="og:image" content="https://cdn2.suno.ai/image_large_bc95fcc5-36c6-427e-9edd-af038aeb8fd4.jpeg" />
</head><body>
<script>self.__next_f.push([1,"...\"audio_url\":\"https://studio-api.prod.suno.com/api/forbidden\",\"media_urls\":[{\"url\":\"https://d2lwuy8qc234o3.cloudfront.net/1/clip/bc95fcc5-36c6-427e-9edd-af038aeb8fd4.m4a\",\"content_type\":\"m4a-opus\",\"delivery\":\"progressive\",\"encoding\":\"1.0.0\"}],\"image_url\":\"https://cdn2.suno.ai/image_bc95fcc5-36c6-427e-9edd-af038aeb8fd4.jpeg\"..."])</script>
</body></html>
''';
      final info = extractor.parseHtml(html);
      expect(info.title, 'Tình khúc ngày cũ');
      expect(
        info.coverUrl,
        'https://cdn2.suno.ai/image_large_bc95fcc5-36c6-427e-9edd-af038aeb8fd4.jpeg',
      );
      expect(
        info.audioUrl,
        'https://d2lwuy8qc234o3.cloudfront.net/1/clip/bc95fcc5-36c6-427e-9edd-af038aeb8fd4.m4a',
      );
      expect(info.audioExtension, 'm4a');
    },
  );

  test('clipId lấy từ URL audio /clip/<uuid> (để xin quyền giải mã)', () {
    const html = r'''
<html><head>
<meta property="og:title" content="Tình khúc ngày cũ" />
</head><body>
<script>"media_urls":[{"url":"https:\/\/d2lwuy8qc234o3.cloudfront.net\/1\/clip\/bc95fcc5-36c6-427e-9edd-af038aeb8fd4.m4a","content_type":"m4a-opus"}]</script>
</body></html>
''';
    final info = extractor.parseHtml(html);
    expect(info.clipId, 'bc95fcc5-36c6-427e-9edd-af038aeb8fd4');
  });

  test('clipId null khi URL audio không chứa UUID', () {
    const html = r'''
<html><body>
<script>"media_urls":[{"url":"https:\/\/cdn1.suno.ai\/abc.mp3","content_type":"mp3"}]</script>
</body></html>
''';
    final info = extractor.parseHtml(html);
    expect(info.clipId, isNull);
  });
}
