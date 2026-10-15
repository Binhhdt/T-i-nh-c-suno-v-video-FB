import 'dart:convert';

import 'package:http/http.dart' as http;

/// Một ảnh trong album / bài viết nhiều ảnh.
class AlbumPhoto {
  const AlbumPhoto({
    required this.id,
    required this.url,
    required this.thumbUrl,
    this.width = 0,
    this.height = 0,
  });

  /// fbid của ảnh (nếu biết) — hoặc tên file ảnh trên CDN.
  final String id;

  /// Link ảnh lớn nhất tìm được.
  final String url;

  /// Link ảnh nhỏ để hiện trong lưới chọn ảnh.
  final String thumbUrl;
  final int width;
  final int height;

  /// Ảnh đã đủ lớn chưa (không cần mở trang ảnh để lấy bản to hơn).
  bool get isLikelyFullSize {
    final side = width > height ? width : height;
    if (side >= 1500) return true;
    if (side == 0) return FacebookAlbumExtractor._sizeFromStp(url) == null;
    return false;
  }

  AlbumPhoto copyWith({String? url, int? width, int? height}) => AlbumPhoto(
        id: id,
        url: url ?? this.url,
        thumbUrl: thumbUrl,
        width: width ?? this.width,
        height: height ?? this.height,
      );
}

/// Kết quả lấy album.
class AlbumInfo {
  const AlbumInfo({
    required this.photos,
    required this.pageUrl,
    this.title,
    this.declaredCount,
  });

  final List<AlbumPhoto> photos;

  /// Trang bài viết/album thật (sau khi đã giải link share).
  final String pageUrl;
  final String? title;

  /// Số ảnh Facebook ghi trong dữ liệu bài viết (nếu có) — để báo khi
  /// lấy được ít hơn.
  final int? declaredCount;
}

class AlbumNotFoundException implements Exception {
  const AlbumNotFoundException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Lỗi riêng: link mở ra BẢNG TIN (News Feed) chứ không phải bài viết.
/// Đây chính là lỗi bản cũ gặp: link /share/p/... bị Facebook chuyển về
/// trang chủ, app quét cả bảng tin nên lấy ra hàng trăm ảnh lung tung.
/// Bản này DỪNG LẠI và báo lỗi thay vì quét bảng tin.
class AlbumFeedRedirectException extends AlbumNotFoundException {
  const AlbumFeedRedirectException()
      : super(
          'Facebook chuyển link này về Bảng tin chứ không mở bài viết, nên '
          'app dừng lại (không quét Bảng tin). Hãy mở bài viết trong app '
          'Facebook → bấm vào 1 ảnh → "..." → Sao chép liên kết, rồi dán '
          'link đó vào đây. Hoặc đăng nhập Facebook rồi thử lại.',
        );
}

/// Trích xuất ảnh từ bài viết nhiều ảnh / album Facebook.
///
/// Nguyên tắc chống lấy nhầm ảnh:
/// 1. Link share (/share/p/..., /share/...) được GIẢI ra link bài viết
///    thật trước khi mở.
/// 2. Trang đích là Bảng tin / trang chủ / đăng nhập -> DỪNG, báo lỗi.
/// 3. Chỉ lấy ảnh thuộc ĐÚNG bài viết: ưu tiên khối dữ liệu
///    `all_subattachments` của bài; nếu không có thì chỉ lấy ảnh có link
///    trỏ về đúng bộ ảnh (set=pcb.<id bài> / set=a.<id album>).
class FacebookAlbumExtractor {
  FacebookAlbumExtractor({http.Client? client})
      : _client = client ?? http.Client();

  final http.Client _client;

  static const desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/126.0.0.0 Safari/537.36';

  static const _headers = {
    'User-Agent': desktopUserAgent,
    'Accept':
        'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'vi-VN,vi;q=0.9,en-US;q=0.8,en;q=0.7',
    'Upgrade-Insecure-Requests': '1',
    'Sec-Fetch-Dest': 'document',
    'Sec-Fetch-Mode': 'navigate',
    'Sec-Fetch-Site': 'none',
  };

  // ---------------------------------------------------------------------
  // URL
  // ---------------------------------------------------------------------

  /// Chuẩn hoá link: thêm https://, đổi m./mbasic./web./touch. -> www.
  String normalizeUrl(String raw) {
    var url = raw.trim();
    if (url.isEmpty) {
      throw const AlbumNotFoundException('Bạn chưa nhập link album.');
    }
    // Người dùng hay dán cả đoạn chữ có link ở giữa -> lấy link đầu tiên.
    final found = RegExp(r'https?://\S+').firstMatch(url);
    if (found != null) url = found.group(0)!;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      throw const AlbumNotFoundException('Link không hợp lệ.');
    }
    if (!isFacebookHost(uri.host)) {
      throw const AlbumNotFoundException(
        'Đây không phải link Facebook.',
      );
    }
    return toWww(uri).toString();
  }

  static bool isFacebookHost(String host) {
    final h = host.toLowerCase();
    return h == 'facebook.com' ||
        h.endsWith('.facebook.com') ||
        h == 'fb.com' ||
        h == 'fb.me' ||
        h == 'fb.watch';
  }

  /// m.facebook.com / mbasic / web / touch -> www.facebook.com
  static Uri toWww(Uri uri) {
    final h = uri.host.toLowerCase();
    if (h == 'facebook.com' ||
        h == 'm.facebook.com' ||
        h == 'mbasic.facebook.com' ||
        h == 'web.facebook.com' ||
        h == 'touch.facebook.com' ||
        h == 'mobile.facebook.com') {
      return uri.replace(scheme: 'https', host: 'www.facebook.com');
    }
    return uri.replace(scheme: 'https');
  }

  /// Link rút gọn / link chia sẻ cần giải ra link thật.
  static bool isShareLink(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final h = uri.host.toLowerCase();
    if (h == 'fb.me' || h == 'fb.watch') return true;
    return uri.path.startsWith('/share/') || uri.path == '/share';
  }

  /// Trang chủ / Bảng tin / trang đăng nhập — KHÔNG BAO GIỜ quét ảnh ở đây.
  static bool isHomeOrFeedUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    if (!isFacebookHost(uri.host)) return false;
    final p = uri.path.replaceAll(RegExp(r'/+$'), '');
    return p.isEmpty ||
        p == '/home.php' ||
        p == '/index.php' ||
        p == '/home' ||
        p == '/feed';
  }

  static bool isLoginUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final p = uri.path;
    return p.startsWith('/login') ||
        p.startsWith('/checkpoint') ||
        p.startsWith('/recover');
  }

  /// Giá trị `set=` của link ảnh / album: "pcb.123", "a.456", ...
  static String? setFromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final s = uri.queryParameters['set'];
    if (s != null && s.isNotEmpty) return s;
    // /<user>/photos/a.123/456/  hoặc /media/set/?set=a.123
    final m = RegExp(r'/photos/((?:a|pcb|ms)\.\d+)/').firstMatch(uri.path);
    return m?.group(1);
  }

  /// fbid của ảnh từ link ảnh.
  static String? photoIdFromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final fbid = uri.queryParameters['fbid'];
    if (fbid != null && RegExp(r'^\d+$').hasMatch(fbid)) return fbid;
    final m = RegExp(r'/photos/(?:[a-z]+\.[\d.]+/)?(\d{6,})').firstMatch(
      uri.path,
    );
    return m?.group(1);
  }

  /// Link là album / bộ ảnh (không phải bài viết thường).
  static bool isAlbumUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    return uri.path.startsWith('/media/set') ||
        uri.path.contains('/photos/a.') ||
        uri.path.contains('/photos/pcb.') ||
        (uri.queryParameters['set']?.isNotEmpty ?? false);
  }

  // ---------------------------------------------------------------------
  // HTTP
  // ---------------------------------------------------------------------

  /// GET theo redirect thủ công (để biết link cuối cùng).
  Future<({int status, String body, String finalUrl})> _get(
    String url, {
    String? cookieHeader,
    int maxHops = 8,
  }) async {
    var current = Uri.parse(url);
    for (var hop = 0; hop <= maxHops; hop++) {
      final req = http.Request('GET', current)
        ..followRedirects = false
        ..headers.addAll(_headers);
      if (cookieHeader != null && cookieHeader.isNotEmpty) {
        req.headers['Cookie'] = cookieHeader;
      }
      final streamed =
          await _client.send(req).timeout(const Duration(seconds: 30));
      final res = await http.Response.fromStream(streamed)
          .timeout(const Duration(seconds: 60));
      final location = res.headers['location'];
      if (res.statusCode >= 300 && res.statusCode < 400 && location != null) {
        current = current.resolve(location);
        // Bị đẩy sang trang đăng nhập: nếu có ?next=<link thật> thì vẫn
        // biết link thật của bài viết.
        if (isLoginUrl(current.toString())) {
          final next = current.queryParameters['next'];
          if (next != null && next.startsWith('http')) {
            return (status: 401, body: '', finalUrl: next);
          }
          return (status: 401, body: '', finalUrl: current.toString());
        }
        continue;
      }
      return (
        status: res.statusCode,
        body: res.body,
        finalUrl: current.toString(),
      );
    }
    throw const AlbumNotFoundException('Link chuyển hướng quá nhiều lần.');
  }

  /// Giải link share (/share/p/xxx) ra link bài viết thật.
  /// Không giải được -> trả lại link gốc (WebView sẽ thử tiếp).
  Future<String> resolveShareUrl(String url, {String? cookieHeader}) async {
    if (!isShareLink(url)) return url;
    try {
      final r = await _get(url, cookieHeader: cookieHeader);
      var resolved = r.finalUrl;
      if (isShareLink(resolved) && r.body.isNotEmpty) {
        final fromHtml = canonicalUrlFromHtml(r.body);
        if (fromHtml != null) resolved = fromHtml;
      }
      return toWww(Uri.parse(resolved)).toString();
    } catch (_) {
      return url;
    }
  }

  /// og:url / canonical / meta refresh trong HTML.
  static String? canonicalUrlFromHtml(String html) {
    final patterns = [
      RegExp(
        r'''<meta[^>]+property=["']og:url["'][^>]+content=["']([^"']+)["']''',
        caseSensitive: false,
      ),
      RegExp(
        r'''<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:url["']''',
        caseSensitive: false,
      ),
      RegExp(
        r'''<link[^>]+rel=["']canonical["'][^>]+href=["']([^"']+)["']''',
        caseSensitive: false,
      ),
      RegExp(
        r'''<meta[^>]+http-equiv=["']refresh["'][^>]+content=["'][^"']*url=([^"']+)["']''',
        caseSensitive: false,
      ),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(html);
      if (m != null) {
        final u = _htmlUnescape(m.group(1)!.trim());
        if (u.startsWith('http') && !isShareLink(u)) return u;
      }
    }
    return null;
  }

  /// Lấy album qua HTTP (giả trình duyệt máy tính + cookie đăng nhập).
  /// Ném [AlbumFeedRedirectException] nếu link dẫn về Bảng tin.
  Future<AlbumInfo> extract(
    String rawUrl, {
    String? cookieHeader,
    void Function(String status)? onStatus,
  }) async {
    var url = normalizeUrl(rawUrl);
    if (isShareLink(url)) {
      onStatus?.call('Đang giải link chia sẻ...');
      url = await resolveShareUrl(url, cookieHeader: cookieHeader);
    }
    if (isHomeOrFeedUrl(url)) throw const AlbumFeedRedirectException();

    onStatus?.call('Đang đọc bài viết...');
    final page = await _get(url, cookieHeader: cookieHeader);
    if (page.status == 401 || isLoginUrl(page.finalUrl)) {
      throw const AlbumNotFoundException(
        'Facebook yêu cầu đăng nhập để xem bài này. Bấm "Đăng nhập '
        'Facebook" rồi thử lại.',
      );
    }
    if (isHomeOrFeedUrl(page.finalUrl)) {
      throw const AlbumFeedRedirectException();
    }
    if (page.status != 200) {
      throw AlbumNotFoundException(
        'Không mở được bài viết (mã ${page.status}).',
      );
    }
    var info = parseAlbumHtml(page.body, pageUrl: page.finalUrl);

    // Bài có nhiều ảnh hơn số lấy được ("+5" trên lưới ảnh) -> mở trang
    // bộ ảnh của bài (set=pcb.<id bài>) để lấy nốt.
    final declared = info.declaredCount ?? 0;
    final postId = postIdFromHtml(page.body);
    if (postId != null &&
        (declared > info.photos.length || info.photos.isEmpty)) {
      onStatus?.call('Đang lấy thêm ảnh của bài...');
      try {
        final setPage = await _get(
          'https://www.facebook.com/media/set/?set=pcb.$postId&type=3',
          cookieHeader: cookieHeader,
        );
        if (setPage.status == 200 && !isHomeOrFeedUrl(setPage.finalUrl)) {
          final more = parseAlbumHtml(
            setPage.body,
            pageUrl: setPage.finalUrl,
            allowGeneric: true,
          );
          info = AlbumInfo(
            photos: mergePhotos(info.photos, more.photos),
            pageUrl: info.pageUrl,
            title: info.title ?? more.title,
            declaredCount: info.declaredCount,
          );
        }
      } catch (_) {}
    }
    if (info.photos.isEmpty) {
      throw const AlbumNotFoundException(
        'Không tìm thấy ảnh trong bài viết này.',
      );
    }
    return info;
  }

  /// Mở trang ảnh lẻ để lấy bản lớn nhất của ảnh [photo].
  /// Chỉ nhận ảnh có tên file chứa đúng fbid của ảnh (không lấy nhầm).
  Future<AlbumPhoto> fetchFullSize(
    AlbumPhoto photo, {
    String? cookieHeader,
  }) async {
    if (!RegExp(r'^\d+$').hasMatch(photo.id)) return photo;
    try {
      final r = await _get(
        'https://www.facebook.com/photo/?fbid=${photo.id}',
        cookieHeader: cookieHeader,
      );
      if (r.status != 200) return photo;
      final best = bestImageForPhotoId(r.body, photo.id);
      if (best == null) return photo;
      if (_area(best.url, best.width, best.height) >
          _area(photo.url, photo.width, photo.height)) {
        return photo.copyWith(
          url: best.url,
          width: best.width,
          height: best.height,
        );
      }
    } catch (_) {}
    return photo;
  }

  // ---------------------------------------------------------------------
  // Phân tích HTML (thuần Dart, test được không cần mạng)
  // ---------------------------------------------------------------------

  /// Phân tích HTML trang bài viết / album.
  /// - Có khối `all_subattachments` -> chỉ lấy ảnh trong đó (đúng bài).
  /// - Không có: nếu là trang album/bộ ảnh hoặc [allowGeneric] -> lấy mọi
  ///   ảnh-nội-dung trong dữ liệu trang (đã loại ảnh đại diện, icon).
  ///   Bài 1 ảnh: lấy ảnh og:image.
  AlbumInfo parseAlbumHtml(
    String html, {
    required String pageUrl,
    bool allowGeneric = false,
  }) {
    if (isHomeOrFeedUrl(pageUrl)) throw const AlbumFeedRedirectException();
    final title = titleFromHtml(html);
    final sub = parseSubattachments(html);
    if (sub.photos.isNotEmpty) {
      return AlbumInfo(
        photos: sub.photos,
        pageUrl: pageUrl,
        title: title,
        declaredCount: sub.count,
      );
    }
    if (allowGeneric || isAlbumUrl(pageUrl)) {
      return AlbumInfo(
        photos: parseGenericPhotos(html),
        pageUrl: pageUrl,
        title: title,
      );
    }
    // Bài viết 1 ảnh: ảnh của bài là og:image (bản to nhất có tên file
    // trùng fbid nếu tìm được).
    final og = _metaProperty(html, 'og:image');
    if (og != null && isContentPhotoUrl(og)) {
      final key = photoKey(og);
      final fbid = fbidFromImageUrl(og);
      AlbumPhoto photo = AlbumPhoto(id: fbid ?? key, url: og, thumbUrl: og);
      if (fbid != null) {
        final best = bestImageForPhotoId(html, fbid);
        if (best != null) photo = best;
      }
      return AlbumInfo(photos: [photo], pageUrl: pageUrl, title: title);
    }
    return AlbumInfo(photos: const [], pageUrl: pageUrl, title: title);
  }

  /// Khối `"all_subattachments":{"count":N,"nodes":[...]}` của bài viết.
  /// Lấy khối ĐẦU TIÊN có ảnh (bài chính), gộp thêm các khối sau có
  /// trùng ảnh (cùng bài, dữ liệu đầy đủ hơn). Khối của bài khác bị bỏ.
  ({List<AlbumPhoto> photos, int? count}) parseSubattachments(String html) {
    final sources = [html];
    if (html.contains(r'\"all_subattachments\"')) {
      sources.add(html.replaceAll(r'\"', '"').replaceAll(r'\/', '/'));
    }
    List<AlbumPhoto>? main;
    int? count;
    for (final src in sources) {
      for (final m
          in RegExp(r'"all_subattachments"\s*:\s*\{').allMatches(src)) {
        final start = m.end - 1;
        final end = matchingBracket(src, start);
        if (end == null) continue;
        Map<String, dynamic> block;
        try {
          final decoded = jsonDecode(src.substring(start, end + 1));
          if (decoded is! Map<String, dynamic>) continue;
          block = decoded;
        } catch (_) {
          continue;
        }
        final nodes = block['nodes'];
        if (nodes is! List) continue;
        final photos = <AlbumPhoto>[];
        for (final node in nodes) {
          final p = _photoFromNode(node);
          if (p != null) photos.add(p);
        }
        if (photos.isEmpty) continue;
        final c = block['count'];
        if (main == null) {
          main = photos;
          if (c is int) count = c;
        } else {
          final ids = main.map((p) => p.id).toSet();
          if (photos.any((p) => ids.contains(p.id))) {
            main = mergePhotos(main, photos);
            if (c is int && (count == null || c > count)) count = c;
          }
        }
      }
      if (main != null) break;
    }
    return (photos: main ?? const [], count: count);
  }

  AlbumPhoto? _photoFromNode(dynamic node) {
    if (node is! Map) return null;
    final media = node['media'];
    final scope = media is Map ? media : node;
    final typename = scope['__typename'];
    if (typename is String && typename != 'Photo') return null; // video
    final images = parseImageObjects(jsonEncode(scope))
        .where((i) => isContentPhotoUrl(i.url))
        .toList();
    if (images.isEmpty) return null;
    images.sort(
      (a, b) =>
          _area(b.url, b.width, b.height).compareTo(_area(a.url, a.width, a.height)),
    );
    final best = images.first;
    final thumb = images.last;
    var id = scope['id']?.toString();
    if (id == null || id.isEmpty) {
      id = fbidFromImageUrl(best.url) ?? photoKey(best.url);
    }
    return AlbumPhoto(
      id: id,
      url: best.url,
      thumbUrl: thumb.url,
      width: best.width,
      height: best.height,
    );
  }

  /// Mọi ảnh-nội-dung trong dữ liệu trang (dùng cho trang album / bộ ảnh).
  /// Gộp các bản khác cỡ của cùng 1 ảnh, giữ bản lớn nhất.
  List<AlbumPhoto> parseGenericPhotos(String html) {
    final images = parseImageObjects(html);
    // Thêm ảnh từ thẻ <img> (HTML đã render trong WebView).
    images.addAll(imgTagImages(html));
    final byKey = <String, List<({String url, int width, int height})>>{};
    final order = <String>[];
    for (final img in images) {
      if (!isContentPhotoUrl(img.url)) continue;
      final key = fbidFromImageUrl(img.url) ?? photoKey(img.url);
      if (!byKey.containsKey(key)) order.add(key);
      byKey.putIfAbsent(key, () => []).add(img);
    }
    final out = <AlbumPhoto>[];
    for (final key in order) {
      final list = byKey[key]!
        ..sort(
          (a, b) => _area(b.url, b.width, b.height)
              .compareTo(_area(a.url, a.width, a.height)),
        );
      final best = list.first;
      // Bỏ ảnh quá nhỏ (icon, avatar, sticker) khi biết kích thước.
      final side = _side(best.url, best.width, best.height);
      if (side > 0 && side < 250) continue;
      out.add(AlbumPhoto(
        id: key,
        url: best.url,
        thumbUrl: list.last.url,
        width: best.width,
        height: best.height,
      ));
    }
    return out;
  }

  /// Bản lớn nhất của ảnh có fbid [id] trong HTML (trang ảnh lẻ).
  AlbumPhoto? bestImageForPhotoId(String html, String id) {
    final images = parseImageObjects(html)..addAll(imgTagImages(html));
    final mine = images
        .where((i) => isContentPhotoUrl(i.url) && fbidFromImageUrl(i.url) == id)
        .toList();
    if (mine.isEmpty) return null;
    mine.sort(
      (a, b) =>
          _area(b.url, b.width, b.height).compareTo(_area(a.url, a.width, a.height)),
    );
    return AlbumPhoto(
      id: id,
      url: mine.first.url,
      thumbUrl: mine.last.url,
      width: mine.first.width,
      height: mine.first.height,
    );
  }

  /// Các object ảnh dạng {"uri":"...","width":W,"height":H} đứng sau
  /// khoá viewer_image / image / photo_image / large_share_image / ...
  List<({String url, int width, int height})> parseImageObjects(String src) {
    final out = <({String url, int width, int height})>[];
    final re = RegExp(
      r'"(?:viewer_image|image|photo_image|large_share_image|full_image|'
      r'massive_image|imageHigh|image_high|imageLarge|preferred_image)"'
      r'\s*:\s*\{',
    );
    for (final m in re.allMatches(src)) {
      final start = m.end - 1;
      final end = matchingBracket(src, start);
      if (end == null) continue;
      try {
        final obj = jsonDecode(src.substring(start, end + 1));
        if (obj is! Map) continue;
        final uri = obj['uri'] ?? obj['url'];
        if (uri is! String || !uri.startsWith('http')) continue;
        out.add((
          url: uri,
          width: _toInt(obj['width']),
          height: _toInt(obj['height']),
        ));
      } catch (_) {}
    }
    return out;
  }

  /// Ảnh trong thẻ <img src="..."> (không biết kích thước thật).
  List<({String url, int width, int height})> imgTagImages(String html) {
    final out = <({String url, int width, int height})>[];
    for (final m in RegExp(
      r'''<img\b[^>]*?\ssrc=["'](https://[^"']+)["']''',
      caseSensitive: false,
    ).allMatches(html)) {
      out.add((url: _htmlUnescape(m.group(1)!), width: 0, height: 0));
    }
    return out;
  }

  /// id bài viết (số) — để mở trang bộ ảnh set=pcb.<id>.
  static String? postIdFromHtml(String html) {
    final patterns = [
      RegExp(r'set=pcb\.(\d+)'),
      RegExp(r'"post_id"\s*:\s*"(\d+)"'),
      RegExp(r'"top_level_post_id"\s*:\s*"(\d+)"'),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(html.replaceAll(r'%', '%'));
      if (m != null) return m.group(1);
    }
    return null;
  }

  /// Tiêu đề / dòng đầu caption để đặt tên thư mục.
  static String? titleFromHtml(String html) {
    String? clean(String? raw) {
      if (raw == null) return null;
      var t = _htmlUnescape(raw).replaceAll(RegExp(r'\s+'), ' ').trim();
      t = t.replaceAll(RegExp(r'\s*[|\-–—]\s*Facebook\s*$'), '').trim();
      if (t.isEmpty || t.toLowerCase() == 'facebook') return null;
      return t;
    }

    final og = clean(_metaProperty(html, 'og:title'));
    if (og != null) return og;
    final m = RegExp(r'<title>([^<]+)</title>', caseSensitive: false)
        .firstMatch(html);
    return clean(m?.group(1));
  }

  // ---------------------------------------------------------------------
  // Phân tích kết quả WebView (đường dự phòng)
  // ---------------------------------------------------------------------

  /// [links]: các thẻ <a> trỏ tới ảnh trên trang đã render
  /// ({href, src, w, h}). Chỉ giữ link thuộc ĐÚNG bộ ảnh của bài/album:
  /// bộ ảnh lấy từ link trang (set=...) hoặc là bộ `pcb.` xuất hiện
  /// nhiều nhất (trang bài viết chỉ có 1 bài).
  List<AlbumPhoto> photosFromDomLinks(
    List<Map<String, dynamic>> links, {
    required String pageUrl,
  }) {
    final target = targetSetFor(links, pageUrl);
    if (target == null) return const [];
    final out = <AlbumPhoto>[];
    final seen = <String>{};
    for (final l in links) {
      final href = l['href']?.toString() ?? '';
      if (setFromUrl(href) != target) continue;
      final id = photoIdFromUrl(href);
      final src = l['src']?.toString() ?? '';
      if (id == null || !seen.add(id)) continue;
      if (src.isEmpty || !src.startsWith('http')) {
        continue; // chưa có ảnh -> lượt cuộn sau sẽ có
      }
      out.add(AlbumPhoto(
        id: id,
        url: src,
        thumbUrl: src,
        width: _toInt(l['w']),
        height: _toInt(l['h']),
      ));
    }
    return out;
  }

  /// Bộ ảnh mục tiêu của trang (để WebView mở trang bộ ảnh nếu cần).
  static String? targetSetFor(
    List<Map<String, dynamic>> links,
    String pageUrl,
  ) {
    final fromUrl = setFromUrl(pageUrl);
    if (fromUrl != null) return fromUrl;
    final freq = <String, int>{};
    for (final l in links) {
      final s = setFromUrl(l['href']?.toString() ?? '');
      if (s != null && s.startsWith('pcb.')) freq[s] = (freq[s] ?? 0) + 1;
    }
    if (freq.isEmpty) return null;
    return (freq.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
        .first
        .key;
  }

  // ---------------------------------------------------------------------
  // Tiện ích
  // ---------------------------------------------------------------------

  /// Gộp 2 danh sách ảnh theo id, giữ bản lớn hơn, giữ thứ tự.
  static List<AlbumPhoto> mergePhotos(
    List<AlbumPhoto> a,
    List<AlbumPhoto> b,
  ) {
    final map = <String, AlbumPhoto>{};
    final order = <String>[];
    for (final p in [...a, ...b]) {
      final existing = map[p.id];
      if (existing == null) {
        map[p.id] = p;
        order.add(p.id);
      } else if (_area(p.url, p.width, p.height) >
          _area(existing.url, existing.width, existing.height)) {
        map[p.id] = AlbumPhoto(
          id: p.id,
          url: p.url,
          thumbUrl: existing.thumbUrl,
          width: p.width,
          height: p.height,
        );
      }
    }
    return [for (final id in order) map[id]!];
  }

  /// Ảnh nội dung (ảnh đăng lên) — loại ảnh đại diện, icon, emoji,
  /// ảnh tĩnh của giao diện.
  static bool isContentPhotoUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    if (!(host.contains('fbcdn.net') || host.startsWith('scontent'))) {
      return false;
    }
    if (host.startsWith('static.')) return false;
    final p = uri.path;
    if (p.contains('/rsrc.php') || p.contains('/emoji')) return false;
    // t39.30808-1 = ảnh đại diện; t1.30497-1 = ảnh đại diện kiểu cũ;
    // t39.1997-6 = sticker; t15.5256-10 = thumbnail video.
    const blocked = [
      't39.30808-1/',
      't1.30497-1/',
      't39.1997-6/',
      't15.5256-10/',
      't15.13418-10/',
      't51.36329-10/',
    ];
    for (final b in blocked) {
      if (p.contains(b)) return false;
    }
    return RegExp(r'\.(jpe?g|png|webp|gif)$', caseSensitive: false)
        .hasMatch(p);
  }

  /// Tên file ảnh trên CDN (khoá gộp các bản khác cỡ).
  static String photoKey(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.pathSegments.isEmpty) return url;
    return uri.pathSegments.last;
  }

  /// Tên file ảnh Facebook dạng `<a>_<fbid>_<b>_n.jpg` — số giữa là fbid.
  static String? fbidFromImageUrl(String url) {
    final m = RegExp(r'^\d+_(\d+)_\d+_[a-z]\.', caseSensitive: false)
        .firstMatch(photoKey(url));
    return m?.group(1);
  }

  /// Bội số ước lượng diện tích ảnh để so bản nào to hơn.
  static int _area(String url, int w, int h) {
    if (w > 0 && h > 0) return w * h;
    final s = _sizeFromStp(url);
    if (s != null) return s.$1 * s.$2;
    return 2048 * 2048; // không có tham số thu nhỏ -> coi là bản gốc
  }

  static int _side(String url, int w, int h) {
    if (w > 0 || h > 0) return w > h ? w : h;
    final s = _sizeFromStp(url);
    if (s != null) return s.$1 > s.$2 ? s.$1 : s.$2;
    return 0;
  }

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is double) return v.round();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  /// Kích thước thu nhỏ trong tham số stp (vd `dst-jpg_s960x960`, `p720x720`).
  static (int, int)? _sizeFromStp(String url) {
    final uri = Uri.tryParse(url);
    final stp = uri?.queryParameters['stp'];
    if (stp == null) return null;
    final m = RegExp(r'(?:^|_)[spc](\d{2,4})x(\d{2,4})').firstMatch(stp);
    if (m == null) return null;
    return (int.parse(m.group(1)!), int.parse(m.group(2)!));
  }

  static String? _metaProperty(String html, String property) {
    final patterns = [
      RegExp(
        '<meta[^>]+property=["\']$property["\'][^>]+content=["\']([^"\']+)["\']',
        caseSensitive: false,
      ),
      RegExp(
        '<meta[^>]+content=["\']([^"\']+)["\'][^>]+property=["\']$property["\']',
        caseSensitive: false,
      ),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(html);
      if (m != null) return _htmlUnescape(m.group(1)!);
    }
    return null;
  }

  static String _htmlUnescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#039;', "'")
      .replaceAll('&#x27;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');
}

/// Vị trí ngoặc đóng khớp với ngoặc mở `{`/`[` tại [start], bỏ qua ngoặc
/// nằm trong chuỗi JSON. Trả null nếu không khớp.
int? matchingBracket(String s, int start) {
  if (start < 0 || start >= s.length) return null;
  final open = s.codeUnitAt(start);
  if (open != 0x7B && open != 0x5B) return null; // { [
  var depth = 0;
  var inString = false;
  for (var i = start; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (inString) {
      if (c == 0x5C) {
        i++; // bỏ qua ký tự sau dấu \
      } else if (c == 0x22) {
        inString = false;
      }
      continue;
    }
    if (c == 0x22) {
      inString = true;
    } else if (c == 0x7B || c == 0x5B) {
      depth++;
    } else if (c == 0x7D || c == 0x5D) {
      depth--;
      if (depth == 0) return i;
    }
  }
  return null;
}
