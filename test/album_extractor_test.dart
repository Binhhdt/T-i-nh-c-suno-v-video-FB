import 'package:fb_video_downloader/album_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

String img(String fbid, {String stp = '', String type = 't39.30808-6'}) {
  final q = stp.isEmpty ? 'oh=1' : 'stp=$stp&oh=1';
  return 'https:\\/\\/scontent.fsgn5-1.fna.fbcdn.net\\/v\\/$type\\/'
      '111_${fbid}_222_n.jpg?$q';
}

void main() {
  final ex = FacebookAlbumExtractor();

  group('URL', () {
    test('link share được nhận ra', () {
      expect(
        FacebookAlbumExtractor.isShareLink(
          'https://www.facebook.com/share/p/19tnz1odEn/',
        ),
        isTrue,
      );
      expect(
        FacebookAlbumExtractor.isShareLink(
          'https://www.facebook.com/abc/posts/pfbid0xyz',
        ),
        isFalse,
      );
    });

    test('Bảng tin / trang chủ bị chặn', () {
      for (final u in [
        'https://www.facebook.com/',
        'https://m.facebook.com/',
        'https://www.facebook.com/home.php',
        'https://www.facebook.com/?sk=h_chr',
      ]) {
        expect(FacebookAlbumExtractor.isHomeOrFeedUrl(u), isTrue, reason: u);
      }
      expect(
        FacebookAlbumExtractor.isHomeOrFeedUrl(
          'https://www.facebook.com/media/set/?set=a.123',
        ),
        isFalse,
      );
    });

    test('parseAlbumHtml trên Bảng tin ném lỗi, không trả ảnh', () {
      expect(
        () => ex.parseAlbumHtml('<html></html>',
            pageUrl: 'https://www.facebook.com/'),
        throwsA(isA<AlbumFeedRedirectException>()),
      );
    });

    test('normalizeUrl: m. -> www., lấy link trong đoạn chữ', () {
      expect(
        ex.normalizeUrl('xem nè https://m.facebook.com/share/p/abc/ hay lắm'),
        'https://www.facebook.com/share/p/abc/',
      );
    });

    test('set + fbid từ link ảnh', () {
      const u =
          'https://www.facebook.com/photo/?fbid=555&set=pcb.999&__cft__=x';
      expect(FacebookAlbumExtractor.setFromUrl(u), 'pcb.999');
      expect(FacebookAlbumExtractor.photoIdFromUrl(u), '555');
      expect(
        FacebookAlbumExtractor.photoIdFromUrl(
          'https://www.facebook.com/someone/photos/a.12345/6789012/',
        ),
        '6789012',
      );
    });

    test('fbid lấy từ tên file ảnh', () {
      expect(
        FacebookAlbumExtractor.fbidFromImageUrl(
          'https://scontent.xx.fbcdn.net/v/t39.30808-6/447_1029837_576_n.jpg?x=1',
        ),
        '1029837',
      );
    });
  });

  group('all_subattachments', () {
    test('chỉ lấy ảnh của bài chính, bỏ bài khác, chọn bản to nhất', () {
      final html = '''
<script type="application/json">{"x":{"all_subattachments":{"count":3,"nodes":[
 {"media":{"__typename":"Photo","id":"101",
   "image":{"uri":"${img('101', stp: 'dst-jpg_s206x206')}","width":206,"height":206},
   "viewer_image":{"height":1536,"width":2048,"uri":"${img('101')}"}}},
 {"media":{"__typename":"Photo","id":"102",
   "viewer_image":{"height":1536,"width":2048,"uri":"${img('102')}"}}},
 {"media":{"__typename":"Video","id":"103",
   "image":{"uri":"${img('103', type: 't15.5256-10')}","width":800,"height":450}}}
]}}}</script>
<script type="application/json">{"y":{"all_subattachments":{"count":2,"nodes":[
 {"media":{"__typename":"Photo","id":"900",
   "viewer_image":{"height":10,"width":10,"uri":"${img('900')}"}}}
]}}}</script>
''';
      final info = ex.parseAlbumHtml(
        html,
        pageUrl: 'https://www.facebook.com/abc/posts/pfbid0x',
      );
      expect(info.photos.map((p) => p.id).toList(), ['101', '102']);
      expect(info.declaredCount, 3);
      expect(info.photos.first.width, 2048);
      expect(info.photos.first.url.contains('stp='), isFalse);
      expect(info.photos.first.thumbUrl.contains('s206x206'), isTrue);
      expect(info.photos.first.isLikelyFullSize, isTrue);
    });
  });

  group('trang album (generic)', () {
    test('gộp các cỡ của cùng 1 ảnh, loại ảnh đại diện và icon', () {
      final html = '''
"image":{"uri":"${img('1', stp: 'dst-jpg_s960x960')}","width":960,"height":720}
"image":{"uri":"${img('1', stp: 'dst-jpg_p180x540')}","width":180,"height":135}
"image":{"uri":"${img('2', stp: 'dst-jpg_s960x960')}","width":960,"height":720}
"image":{"uri":"${img('3', type: 't39.30808-1')}","width":960,"height":960}
"image":{"uri":"${img('4', stp: 'cp0_dst-jpg_s40x40')}","width":40,"height":40}
''';
      final info = ex.parseAlbumHtml(
        html,
        pageUrl: 'https://www.facebook.com/media/set/?set=a.777',
      );
      expect(info.photos.map((p) => p.id).toList(), ['1', '2']);
      expect(info.photos.first.width, 960);
      expect(info.photos.first.isLikelyFullSize, isFalse);
    });
  });

  group('WebView DOM links', () {
    test('chỉ lấy link đúng bộ ảnh pcb của bài', () {
      final links = <Map<String, dynamic>>[
        {
          'href': 'https://www.facebook.com/photo/?fbid=11&set=pcb.500',
          'src': 'https://scontent.x.fbcdn.net/v/t39.30808-6/1_11_2_n.jpg',
          'w': 500,
          'h': 400,
        },
        {
          'href': 'https://www.facebook.com/photo/?fbid=12&set=pcb.500',
          'src': 'https://scontent.x.fbcdn.net/v/t39.30808-6/1_12_2_n.jpg',
          'w': 500,
          'h': 400,
        },
        {
          // ảnh của bài khác (gợi ý / quảng cáo) -> bỏ
          'href': 'https://www.facebook.com/photo/?fbid=99&set=pcb.777',
          'src': 'https://scontent.x.fbcdn.net/v/t39.30808-6/1_99_2_n.jpg',
          'w': 500,
          'h': 400,
        },
        {
          // ảnh chưa tải (lazy) -> bỏ, lượt sau lấy
          'href': 'https://www.facebook.com/photo/?fbid=13&set=pcb.500',
          'src': '',
          'w': 0,
          'h': 0,
        },
      ];
      final photos = ex.photosFromDomLinks(
        links,
        pageUrl: 'https://www.facebook.com/abc/posts/pfbid0x',
      );
      expect(photos.map((p) => p.id).toList(), ['11', '12']);
      expect(
        FacebookAlbumExtractor.targetSetFor(
          links,
          'https://www.facebook.com/abc/posts/pfbid0x',
        ),
        'pcb.500',
      );
    });
  });

  test('bestImageForPhotoId chỉ nhận ảnh đúng fbid', () {
    final html = '''
"image":{"uri":"${img('42')}","width":2048,"height":1365}
"image":{"uri":"${img('43')}","width":4096,"height":4096}
''';
    final p = ex.bestImageForPhotoId(html, '42');
    expect(p, isNotNull);
    expect(p!.width, 2048);
  });

  test('matchingBracket bỏ qua ngoặc trong chuỗi', () {
    const s = '{"a":"}{[","b":[1,{"c":"\\"}"}]}tail';
    expect(matchingBracket(s, 0), s.indexOf('tail') - 1);
  });

  test('canonicalUrlFromHtml lấy og:url, bỏ qua link share', () {
    const html =
        '<meta property="og:url" content="https://www.facebook.com/a/posts/pfbid1?x=1&amp;y=2" />';
    expect(
      FacebookAlbumExtractor.canonicalUrlFromHtml(html),
      'https://www.facebook.com/a/posts/pfbid1?x=1&y=2',
    );
  });
}
