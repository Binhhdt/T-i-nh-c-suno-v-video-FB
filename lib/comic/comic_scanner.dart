import 'dart:convert';

import 'comic_models.dart';

/// Phân tích dữ liệu thô mà trình duyệt (WebView) thu được từ trang
/// chapter -> danh sách ảnh trang truyện theo đúng thứ tự.
///
/// Thuần Dart, không đụng mạng -> test được.
///
/// Dữ liệu thô (do [ComicScanScripts.scan] gửi về) gồm:
/// - `imgs`: mọi thẻ <img> với các thuộc tính src/srcset/data-*, kích
///   thước thật (naturalWidth/Height), kích thước hiển thị, "chữ ký"
///   khung chứa (3 cấp cha) và thứ tự trong DOM.
/// - `scripts`: nội dung các thẻ <script> JSON hoặc có chứa link ảnh.
/// - `apis`: phản hồi JSON của fetch/XHR mà trình duyệt đã nhận.
class ComicScanner {
  /// Thuộc tính lazy-load hay gặp, theo thứ tự ưu tiên (trước src).
  static const lazyAttrs = [
    'data-src',
    'data-original',
    'data-lazy-src',
    'data-lazy',
    'data-url',
    'data-echo',
    'data-cfsrc',
    'data-full',
    'data-large',
    'data-img',
    'data-image',
  ];

  static const _imageExt = r'\.(?:jpe?g|png|webp|gif|avif|bmp)';

  /// Link trông như link ảnh: http(s) và đường dẫn có đuôi ảnh.
  static bool looksLikeImageUrl(String url) {
    final u = url.trim();
    if (!u.startsWith('http://') && !u.startsWith('https://')) return false;
    final uri = Uri.tryParse(u);
    if (uri == null || uri.host.isEmpty) return false;
    return RegExp('$_imageExt(?:\$|[?#&/])', caseSensitive: false)
            .hasMatch(uri.path) ||
        RegExp('$_imageExt\$', caseSensitive: false).hasMatch(uri.path) ||
        // Một số CDN: ?format=jpg / ?fm=webp
        RegExp(r'[?&](?:format|fm|ext)=(?:jpe?g|png|webp|avif)',
                caseSensitive: false)
            .hasMatch(u);
  }

  /// Giá trị giữ chỗ của lazy-load (ảnh trong suốt 1px, ảnh "loading").
  static bool isPlaceholder(String v) {
    final s = v.trim().toLowerCase();
    if (s.isEmpty) return true;
    if (s.startsWith('data:')) return true;
    if (s == 'about:blank' || s == '#') return true;
    const words = [
      'placeholder',
      'loading',
      'blank.',
      'lazy.',
      'spinner',
      'transparent.',
      'pixel.',
      '1x1',
      'grey.gif',
      'gray.gif',
    ];
    return words.any(s.contains);
  }

  /// Đổi link tương đối thành tuyệt đối theo [base]. Chỉ nhận http(s).
  static String? resolve(String base, String raw) {
    var u = raw.trim().replaceAll('&amp;', '&');
    if (u.isEmpty) return null;
    if (u.startsWith('//')) u = 'https:$u';
    final b = Uri.tryParse(base);
    final r = Uri.tryParse(u);
    if (r == null) return null;
    final out = r.hasScheme ? r : (b?.resolveUri(r));
    if (out == null) return null;
    if (out.scheme != 'http' && out.scheme != 'https') return null;
    return out.toString();
  }

  /// Ứng viên lớn nhất trong srcset ("a.jpg 480w, b.jpg 1080w" -> b.jpg).
  static String? bestFromSrcset(String srcset) {
    String? best;
    var bestVal = -1.0;
    // Tách theo dấu phẩy nằm trước khoảng trắng + link mới (link có thể
    // chứa dấu phẩy trong query).
    for (final part in srcset.split(RegExp(r',\s+(?=\S)'))) {
      final tokens = part.trim().split(RegExp(r'\s+'));
      if (tokens.isEmpty || tokens.first.isEmpty) continue;
      var v = 1.0;
      if (tokens.length > 1) {
        final d = tokens[1].toLowerCase();
        final n = double.tryParse(d.replaceAll(RegExp(r'[wx]$'), ''));
        if (n != null) v = n;
      }
      if (v > bestVal) {
        bestVal = v;
        best = tokens.first.replaceAll(RegExp(r',$'), '');
      }
    }
    return best;
  }

  /// Chọn link ảnh tốt nhất cho 1 thẻ <img>:
  /// data-* lazy -> data-srcset -> data-* bất kỳ có link ảnh -> srcset ->
  /// <picture><source srcset> -> src -> currentSrc. Bỏ ảnh giữ chỗ.
  static String? pickImgUrl(
    Map<String, dynamic> attrs,
    String currentSrc,
    String base,
  ) {
    String? ok(String? raw) {
      if (raw == null || isPlaceholder(raw)) return null;
      return resolve(base, raw);
    }

    for (final a in lazyAttrs) {
      final v = ok(attrs[a]?.toString());
      if (v != null) return v;
    }
    final dss = attrs['data-srcset']?.toString();
    if (dss != null) {
      final v = ok(bestFromSrcset(dss));
      if (v != null) return v;
    }
    for (final e in attrs.entries) {
      if (!e.key.startsWith('data-')) continue;
      final s = e.value?.toString() ?? '';
      final v = ok(s);
      if (v != null && looksLikeImageUrl(v)) return v;
    }
    for (final k in ['srcset', 'picture-srcset']) {
      final ss = attrs[k]?.toString();
      if (ss != null) {
        final v = ok(bestFromSrcset(ss));
        if (v != null) return v;
      }
    }
    return ok(attrs['src']?.toString()) ?? ok(currentSrc);
  }

  // -------------------------------------------------------------------
  // DOM
  // -------------------------------------------------------------------

  /// Ảnh trang truyện từ DOM: nhóm theo khung chứa, chọn khung có nhiều
  /// ảnh lớn nhất (khung đọc truyện), giữ thứ tự DOM (hoặc data-index nếu
  /// mọi ảnh đều có).
  static ({List<ChapterImage> images, String note, double linkedRatio})
      fromDom(
    List<Map<String, dynamic>> imgs,
    String base,
  ) {
    final groups = <String, List<_DomImg>>{};
    var dropped = 0;
    for (final m in imgs) {
      final attrs = (m['attrs'] is Map)
          ? (m['attrs'] as Map).cast<String, dynamic>()
          : <String, dynamic>{};
      final cur = m['cur']?.toString() ?? '';
      final url = pickImgUrl(attrs, cur, base);
      if (url == null) continue;
      // Kích thước chỉ đáng tin khi ảnh đang hiện CHÍNH LÀ ảnh sẽ tải.
      // Ảnh lazy còn đang hiện ảnh giữ chỗ (1px, 16px...) -> coi như
      // chưa biết kích thước, KHÔNG được loại nhầm là icon.
      final shown = resolve(base, cur.isNotEmpty ? cur : (attrs['src']?.toString() ?? ''));
      final sizeKnown = shown != null && shown == url;
      final nw = sizeKnown ? _int(m['nw']) : 0;
      final nh = sizeKnown ? _int(m['nh']) : 0;
      final w = sizeKnown ? _int(m['w']) : 0;
      final h = sizeKnown ? _int(m['h']) : 0;
      // Icon / avatar / nút bấm: ảnh thật nhỏ.
      if (sizeKnown &&
          ((nw > 0 && nw < 150 && nh < 150) ||
              (nw == 0 && w > 0 && w < 100 && h < 100))) {
        dropped++;
        continue;
      }
      final sig = m['sig']?.toString() ?? '';
      final link = m['link']?.toString() ?? '';
      groups.putIfAbsent(sig, () => []).add(_DomImg(
            linked: _isNavLink(link, base, url),
            url: url,
            domIndex: _int(m['i']),
            nw: nw,
            nh: nh,
            w: w,
            orderAttr: _orderAttr(attrs),
            lazy: !sizeKnown || lazyAttrs.any((a) => attrs.containsKey(a)),
          ));
    }
    if (groups.isEmpty) {
      return (
        images: const <ChapterImage>[],
        note: 'DOM: không có ảnh',
        linkedRatio: 0.0,
      );
    }

    // Ảnh trang truyện thường KHÔNG nằm trong link; ảnh bìa/thumbnail của
    // truyện khác (lưới gợi ý, danh sách) thì có link -> ưu tiên khung
    // có nhiều ảnh lớn KHÔNG có link.
    int score(List<_DomImg> g) {
      var s = 0;
      for (final d in g) {
        final big = d.nw >= 300 || d.nh >= 300 || d.w >= 200 || d.lazy;
        if (big) s += d.linked ? 1 : 3;
      }
      return s;
    }
    final best = groups.entries.toList()
      ..sort((a, b) {
        final s = score(b.value).compareTo(score(a.value));
        return s != 0 ? s : b.value.length.compareTo(a.value.length);
      });
    final chosen = best.first.value;

    final allHaveOrder = chosen.every((d) => d.orderAttr != null);
    chosen.sort((a, b) => allHaveOrder
        ? a.orderAttr!.compareTo(b.orderAttr!)
        : a.domIndex.compareTo(b.domIndex));

    final seen = <String>{};
    final out = <ChapterImage>[];
    for (final d in chosen) {
      if (!seen.add(d.url)) continue;
      out.add(ChapterImage(
        index: out.length,
        url: d.url,
        source: 'dom',
        width: d.nw,
        height: d.nh,
      ));
    }
    final linkedCount = chosen.where((d) => d.linked).length;
    return (
      linkedRatio: chosen.isEmpty ? 0.0 : linkedCount / chosen.length,
      images: out,
      note: 'DOM: ${imgs.length} thẻ img, ${groups.length} khung, chọn khung '
          '"${best.first.key}" có ${out.length} ảnh'
          '${allHaveOrder ? ' (xếp theo data-index)' : ''}'
          '${linkedCount > 0 ? ', $linkedCount ảnh nằm trong link' : ''}'
          '${dropped > 0 ? ', bỏ $dropped ảnh nhỏ' : ''}',
    );
  }

  /// Ảnh nằm trong link dẫn sang TRANG KHÁC (không phải link tới chính
  /// ảnh đó, không phải "#") -> dấu hiệu ảnh bìa/thumbnail.
  static bool _isNavLink(String link, String base, String imageUrl) {
    if (link.isEmpty) return false;
    final l = resolve(base, link);
    if (l == null) return false;
    if (l == imageUrl || looksLikeImageUrl(l)) return false;
    final lu = Uri.parse(l), bu = Uri.tryParse(base);
    if (bu != null &&
        lu.host == bu.host &&
        lu.path == bu.path) {
      return false; // link về chính trang này (vd #trang-2)
    }
    return true;
  }

  static int? _orderAttr(Map<String, dynamic> attrs) {
    for (final k in ['data-index', 'data-page', 'data-number', 'data-p']) {
      final v = int.tryParse(attrs[k]?.toString().trim() ?? '');
      if (v != null) return v;
    }
    return null;
  }

  // -------------------------------------------------------------------
  // JSON / API
  // -------------------------------------------------------------------

  static const _urlKeys = [
    'url',
    'src',
    'image',
    'img',
    'imageUrl',
    'image_url',
    'imageURL',
    'path',
    'file',
    'link',
    'original',
    'large',
    'full',
  ];

  /// Mọi danh sách link ảnh (>= 2 ảnh) trong 1 đoạn văn bản JSON / script.
  /// Thứ tự trong mảng = thứ tự trang.
  static List<List<String>> listsFromText(String text, String base) {
    final out = <List<String>>[];
    final trimmed = text.trim();
    dynamic decoded;
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        decoded = jsonDecode(trimmed);
      } catch (_) {}
    }
    if (decoded != null) {
      _walk(decoded, base, out, 0);
      return out;
    }
    // Không phải JSON thuần (vd `var pages = ["a.jpg","b.jpg"]`): lấy các
    // link ảnh trong ngoặc kép theo thứ tự xuất hiện, gom thành 1 danh sách.
    final unescaped = text.replaceAll(r'\/', '/');
    final found = <String>[];
    final seen = <String>{};
    for (final m in RegExp(
      '["\'](https?://[^"\'\\s]+?$_imageExt(?:\\?[^"\'\\s]*)?)["\']',
      caseSensitive: false,
    ).allMatches(unescaped)) {
      final u = resolve(base, m.group(1)!);
      if (u != null && seen.add(u)) found.add(u);
    }
    if (found.length >= 2) out.add(found);
    return out;
  }

  static void _walk(
    dynamic node,
    String base,
    List<List<String>> out,
    int depth,
  ) {
    if (depth > 40) return;
    if (node is List) {
      final urls = <String>[];
      var hits = 0;
      for (final e in node) {
        final u = _urlOf(e, base);
        if (u != null) {
          hits++;
          urls.add(u);
        }
      }
      if (urls.length >= 2 && hits >= node.length * 0.6) {
        final seen = <String>{};
        out.add([for (final u in urls) if (seen.add(u)) u]);
      }
      for (final e in node) {
        if (e is List || e is Map) _walk(e, base, out, depth + 1);
      }
    } else if (node is Map) {
      for (final v in node.values) {
        if (v is List || v is Map) {
          _walk(v, base, out, depth + 1);
        } else if (v is String && v.length > 2 && v.length < 3000000) {
          // JSON lồng trong chuỗi (API hay trả {"data":"[...]"}).
          final t = v.trim();
          if ((t.startsWith('[') || t.startsWith('{')) && t.contains('http')) {
            try {
              _walk(jsonDecode(t), base, out, depth + 1);
            } catch (_) {}
          }
        }
      }
    }
  }

  static String? _urlOf(dynamic e, String base) {
    if (e is String) {
      final u = resolve(base, e);
      return (u != null && looksLikeImageUrl(u)) ? u : null;
    }
    if (e is Map) {
      for (final k in _urlKeys) {
        final v = e[k];
        if (v is String) {
          final u = resolve(base, v);
          if (u != null && looksLikeImageUrl(u)) return u;
        }
        if (v is Map) {
          final inner = _urlOf(v, base);
          if (inner != null) return inner;
        }
      }
    }
    return null;
  }

  // -------------------------------------------------------------------
  // Kết hợp
  // -------------------------------------------------------------------

  /// Phân tích dữ liệu thô từ WebView -> [ScanResult].
  ///
  /// Quy tắc chọn:
  /// 1. DOM có >= 3 ảnh: dùng DOM — TRỪ KHI có danh sách JSON dài hơn và
  ///    chứa >= 80% ảnh của DOM (trang chưa render hết ảnh lazy) -> JSON.
  /// 2. DOM < 3 ảnh: dùng danh sách JSON dài nhất (>= 3 ảnh).
  /// 3. Không có gì: dùng DOM (có thể rỗng).
  static ScanResult analyze(Map<String, dynamic> raw) {
    final log = <String>[];
    final pageUrl = raw['url']?.toString() ?? '';
    final title = raw['title']?.toString().trim() ?? '';
    final ua = raw['ua']?.toString() ?? '';
    log.add('Trang: $pageUrl');
    if (title.isNotEmpty) log.add('Tiêu đề: $title');

    final imgs = ((raw['imgs'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
    final dom = fromDom(imgs, pageUrl);
    log.add(dom.note);
    final expanded = raw['expanded'];
    if (expanded is num && expanded > 0) {
      log.add('Đã tự bấm $expanded nút "Xem thêm/Xem tất cả" để hiện đủ danh sách');
    }

    final jsonLists = <({List<String> urls, String from})>[];
    for (final s in ((raw['scripts'] as List?) ?? const []).whereType<Map>()) {
      final text = s['text']?.toString() ?? '';
      final id = s['id']?.toString() ?? '';
      for (final l in listsFromText(text, pageUrl)) {
        jsonLists.add((urls: l, from: 'script${id.isEmpty ? '' : '#$id'}'));
      }
    }
    for (final a in ((raw['apis'] as List?) ?? const []).whereType<Map>()) {
      final body = a['body']?.toString() ?? '';
      final url = a['url']?.toString() ?? '';
      for (final l in listsFromText(body, pageUrl)) {
        jsonLists.add((urls: l, from: 'API $url'));
      }
    }
    for (final e in ((raw['errors'] as List?) ?? const [])) {
      log.add('Cảnh báo khi quét: $e');
    }
    jsonLists.sort((a, b) => b.urls.length.compareTo(a.urls.length));
    if (jsonLists.isNotEmpty) {
      log.add('JSON/API: ${jsonLists.length} danh sách ảnh, dài nhất '
          '${jsonLists.first.urls.length} ảnh (${jsonLists.first.from})');
    } else {
      log.add('JSON/API: không có danh sách ảnh');
    }

    List<ChapterImage> fromJson(List<String> urls) => [
          for (var i = 0; i < urls.length; i++)
            ChapterImage(index: i, url: urls[i], source: 'json'),
        ];

    var chosen = dom.images;
    var why = 'DOM (thẻ <img>)';
    if (dom.images.length >= 3) {
      final domSet = dom.images.map((e) => e.url).toSet();
      for (final j in jsonLists) {
        if (j.urls.length <= dom.images.length) break;
        final overlap = j.urls.where(domSet.contains).length;
        if (overlap >= domSet.length * 0.8) {
          chosen = fromJson(j.urls);
          why = 'JSON (${j.from}) — đầy đủ hơn DOM';
          break;
        }
      }
    } else if (jsonLists.isNotEmpty && jsonLists.first.urls.length >= 3) {
      chosen = fromJson(jsonLists.first.urls);
      why = 'JSON (${jsonLists.first.from})';
    }
    log.add('Chọn nguồn: $why -> ${chosen.length} trang');

    // Nhận diện trang KHÔNG phải chapter (trang giới thiệu / danh sách):
    // ảnh được chọn phần lớn là ảnh có link sang trang khác (bìa truyện),
    // hoặc quá ít ảnh.
    String? warning;
    // (Cũng áp dụng khi JSON được chọn vì trùng với chính các ảnh bìa đó.)
    final basedOnDom = chosen.isNotEmpty &&
        (chosen.first.source == 'dom' || dom.images.length >= 3);
    if (basedOnDom && dom.linkedRatio >= 0.5) {
      warning = 'Trang này có vẻ là trang GIỚI THIỆU / DANH SÁCH truyện, '
          'không phải trang chapter: các ảnh tìm được là ảnh bìa có link '
          'sang trang khác. Hãy mở 1 chapter để đọc rồi dán link của trang '
          'chapter đó.';
    } else if (chosen.isNotEmpty && chosen.length < 3) {
      warning = 'Chỉ tìm thấy ${chosen.length} ảnh — có thể đây không phải '
          'trang chapter, hoặc trang chưa tải hết ảnh (thử bật "giao diện '
          'máy tính" rồi quét lại).';
    }
    final chapters = chapterLinksFrom(
      ((raw['links'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList(),
      pageUrl,
    );
    if (chapters.isNotEmpty) {
      log.add('Tìm thấy ${chapters.length} link chapter trên trang '
          '(chap ${chapters.first.numberLabel} → ${chapters.last.numberLabel})');
      if (warning != null && dom.linkedRatio >= 0.5) {
        warning = 'Đây là trang GIỚI THIỆU bộ truyện. Bên dưới có danh sách '
            '${chapters.length} chapter — tích chọn chapter muốn tải.';
      }
    }
    if (warning != null) log.add('CẢNH BÁO: $warning');

    return ScanResult(
      pageUrl: pageUrl,
      title: title,
      userAgent: ua,
      images: chosen,
      chosenSource: why,
      log: log,
      warning: warning,
      chapters: chapters,
    );
  }

  /// Số chapter trong chữ / link: "Chương 12", "chap-12-5", "Chapter 3.5".
  static double? chapterNumber(String text) {
    final m = RegExp(
      r'(?:chap(?:ter)?|chương|chuong|tập|tap|episode|ep|ch|第)'
      r'[\s\-_.:#]*(\d+(?:[.\-_]\d+)?)',
      caseSensitive: false,
    ).firstMatch(text);
    if (m == null) return null;
    final raw = m.group(1)!.replaceAll(RegExp(r'[\-_]'), '.');
    return double.tryParse(raw);
  }

  /// Lọc link chapter: cùng tên miền với trang, khác trang hiện tại,
  /// không phải link ảnh, có số chapter. Gộp link trùng (cùng URL hoặc
  /// cùng số chapter — vd nút "Đọc từ đầu" trỏ tới chap 1). Xếp tăng dần.
  static List<ChapterLink> chapterLinksFrom(
    List<Map<String, dynamic>> links,
    String pageUrl,
  ) {
    final page = Uri.tryParse(pageUrl);
    final out = <ChapterLink>[];
    final byUrl = <String, int>{};
    final byNum = <double, int>{};
    for (final l in links) {
      final url = resolve(pageUrl, l['href']?.toString() ?? '');
      if (url == null) continue;
      final u = Uri.parse(url);
      if (page != null) {
        if (u.host != page.host) continue;
        if (u.path == page.path && u.query == page.query) continue;
      }
      if (looksLikeImageUrl(url)) continue;
      final clean = u.removeFragment().toString();
      final text = l['text']?.toString().trim() ?? '';
      final textNum = chapterNumber(text);
      // Ưu tiên số trong chữ; không có thì lấy từ link (đã giải mã %xx).
      final n = textNum ??
          chapterNumber(Uri.decodeFull(u.path.split('/').last)) ??
          chapterNumber(Uri.decodeFull(u.path));
      if (n == null) continue;
      final cand = ChapterLink(
        url: clean,
        title: text.isEmpty ? 'Chapter ${_fmt(n)}' : text,
        number: n,
      );
      // Trùng link / trùng số chapter (vd nút "Đọc từ đầu" -> chap 1):
      // giữ 1 cái, ưu tiên cái có chữ ghi số chapter ("Chương 1").
      final dup = byUrl[clean] ?? byNum[n];
      if (dup != null) {
        if (chapterNumber(out[dup].title) == null && textNum != null) {
          out[dup] = ChapterLink(url: out[dup].url, title: cand.title, number: n);
        }
        continue;
      }
      out.add(cand);
      byUrl[clean] = out.length - 1;
      byNum[n] = out.length - 1;
    }
    final filtered = _sameSeries(out, page);
    filtered.sort((a, b) => a.number!.compareTo(b.number!));
    return filtered;
  }

  /// Bỏ link chapter của TRUYỆN KHÁC (thẻ gợi ý thường ghi "Chap 120").
  /// 1. Link có chứa "slug" của trang (phần cuối đường dẫn, vd
  ///    `ten-truyen-123`) -> chỉ giữ các link đó (cần >= 2 link).
  /// 2. Không thì giữ nhóm lớn nhất có cùng thư mục cha.
  static List<ChapterLink> _sameSeries(List<ChapterLink> all, Uri? page) {
    if (all.length < 2 || page == null) return List.of(all);
    final segs = page.pathSegments.where((e) => e.isNotEmpty).toList();
    if (segs.isNotEmpty) {
      var slug = Uri.decodeComponent(segs.last).toLowerCase();
      slug = slug.replaceAll(RegExp(r'\.(html?|php|aspx?)$'), '');
      final slugNoId = slug.replaceAll(RegExp(r'[-_]\d+$'), '');
      for (final key in {slug, slugNoId}) {
        if (key.length < 4) continue;
        final hit = all
            .where((c) =>
                Uri.decodeFull(Uri.parse(c.url).path).toLowerCase().contains(key))
            .toList();
        if (hit.length >= 2) return hit;
      }
    }
    final groups = <String, List<ChapterLink>>{};
    for (final c in all) {
      final ps = Uri.parse(c.url).pathSegments.where((e) => e.isNotEmpty).toList();
      final parent = ps.length > 1 ? ps.sublist(0, ps.length - 1).join('/') : '';
      groups.putIfAbsent(parent, () => []).add(c);
    }
    final best = groups.values.reduce((a, b) => a.length >= b.length ? a : b);
    return best.length >= 2 ? List.of(best) : List.of(all);
  }

  static String _fmt(double n) =>
      n == n.roundToDouble() ? n.toInt().toString() : n.toString();

  static int _int(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.round();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }
}

class _DomImg {
  _DomImg({
    required this.url,
    required this.linked,
    required this.domIndex,
    required this.nw,
    required this.nh,
    required this.w,
    required this.orderAttr,
    required this.lazy,
  });

  final String url;
  final bool linked;
  final int domIndex;
  final int nw;
  final int nh;
  final int w;
  final int? orderAttr;
  final bool lazy;
}

/// Các đoạn JavaScript chạy trong WebView.
class ComicScanScripts {
  /// Tên kênh JS -> Dart.
  static const channel = 'ComicScan';

  /// Gắn "tai nghe" vào fetch/XHR để giữ lại phản hồi JSON mà trình duyệt
  /// nhận được (chỉ đọc bản sao, không chặn/sửa request). Chạy được
  /// nhiều lần (tự bỏ qua nếu đã gắn).
  static const hook = r'''
(function(){
  if (window.__comicHooked) return;
  window.__comicHooked = true;
  window.__comicJson = window.__comicJson || [];
  function keep(url, text){
    try {
      if (!text || text.length > 2000000) return;
      var c = String(text).trim().charAt(0);
      if (c !== '{' && c !== '[') return;
      if (window.__comicJson.length >= 40) return;
      window.__comicJson.push({url: String(url || ''), body: String(text)});
    } catch (e) {}
  }
  var of = window.fetch;
  if (of) {
    window.fetch = function(){
      return of.apply(this, arguments).then(function(resp){
        try {
          var ct = (resp.headers && resp.headers.get('content-type')) || '';
          if (ct.indexOf('json') >= 0) {
            resp.clone().text().then(function(t){ keep(resp.url, t); });
          }
        } catch (e) {}
        return resp;
      });
    };
  }
  var oo = XMLHttpRequest.prototype.open, os = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(m, u){ this.__cu = u; return oo.apply(this, arguments); };
  XMLHttpRequest.prototype.send = function(){
    var x = this;
    x.addEventListener('load', function(){
      try {
        if (x.responseType === '' || x.responseType === 'text') keep(x.responseURL || x.__cu, x.responseText);
        else if (x.responseType === 'json' && x.response) keep(x.responseURL || x.__cu, JSON.stringify(x.response));
      } catch (e) {}
    });
    return os.apply(this, arguments);
  };
})();
''';

  /// Bấm các nút "Xem thêm / Xem tất cả / Show more / Load more" để hiện
  /// đủ danh sách chapter (nhiều trang ẩn bớt chương đầu). Chỉ bấm nút
  /// hoặc link KHÔNG dẫn sang trang khác (href "#", "javascript:", hoặc
  /// không có href). Mỗi nút bấm tối đa 1 lần / lượt. Trả về số nút đã bấm.
  static const expandMore = r'''
(function(){
  var re = /^\s*(\+\s*)?(xem thêm|xem tất cả|xem toàn bộ|hiện thêm|hiển thị thêm|hiển thị tất cả|tải thêm|mở rộng|show more|show all|load more|view more|view all|see more|see all|more chapters|all chapters|expand)\b/i;
  var clicked = 0;
  window.__comicClicked = window.__comicClicked || [];
  var els = document.querySelectorAll('button, a, span, div, li, p, [role=button]');
  for (var i = 0; i < els.length && clicked < 5; i++) {
    var el = els[i];
    var t = (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim();
    if (!t || t.length > 40 || !re.test(t)) continue;
    // chỉ phần tử "lá" (không chứa phần tử khác cũng khớp) để không bấm 2 lần
    if (el.querySelector && el.querySelector('button, a')) continue;
    var r = el.getBoundingClientRect();
    if (r.width === 0 && r.height === 0) continue; // đang ẩn
    var a = el.closest ? el.closest('a[href]') : null;
    if (a) {
      var h = a.getAttribute('href') || '';
      if (h && h !== '#' && h.indexOf('javascript:') !== 0) {
        try {
          var u = new URL(a.href);
          if (u.pathname !== location.pathname || u.search !== location.search) continue; // sang trang khác -> bỏ
        } catch (e) { continue; }
      }
    }
    var key = t + '|' + Math.round(r.top + window.scrollY);
    if (window.__comicClicked.indexOf(key) >= 0) continue;
    window.__comicClicked.push(key);
    try { el.click(); clicked++; } catch (e) {}
  }
  return String(clicked);
})()
''';

  /// Cuộn 1 đoạn xuống dưới. Trả về "cao|vị trí|cao màn hình".
  static const scrollStep = r'''
(function(){
  window.scrollBy(0, Math.round(window.innerHeight * 0.85));
  var h = Math.max(document.body ? document.body.scrollHeight : 0, document.documentElement.scrollHeight);
  return h + '|' + Math.round(window.scrollY + window.innerHeight) + '|' + window.innerHeight;
})()
''';

  /// Quét DOM + script + JSON/API, gửi kết quả về Dart qua kênh
  /// [channel]. Các API JSON trình duyệt đã gọi nhưng chưa bắt được thì
  /// đọc lại bằng fetch của chính trang (cùng cookie, cùng quyền).
  static const scan = r'''
(async function(){
  try {
    var out = {url: location.href, title: document.title || '', ua: navigator.userAgent,
               expanded: (window.__comicClicked || []).length,
               imgs: [], scripts: [], apis: [], errors: []};
    var idx = 0;
    document.querySelectorAll('img').forEach(function(el){
      var a = {};
      for (var k = 0; k < el.attributes.length; k++) {
        var at = el.attributes[k], n = at.name.toLowerCase();
        if (n === 'src' || n === 'srcset' || n.indexOf('data-') === 0) a[n] = String(at.value).slice(0, 4000);
      }
      if (el.parentElement && el.parentElement.tagName === 'PICTURE') {
        var srcs = el.parentElement.querySelectorAll('source[srcset]');
        if (srcs.length) a['picture-srcset'] = srcs[0].getAttribute('srcset');
      }
      var r = el.getBoundingClientRect();
      // "Chữ ký" khung chứa: 3 cấp cha, bỏ qua thẻ bọc nội dòng
      // (picture, a, span, figure, noscript) để ảnh cùng khung đọc truyện
      // luôn cùng nhóm dù có bọc thêm hay không.
      var p = el.parentElement, sig = [];
      while (p && sig.length < 3) {
        var tg = p.tagName;
        if (tg === 'PICTURE' || tg === 'A' || tg === 'SPAN' || tg === 'FIGURE' || tg === 'NOSCRIPT') {
          p = p.parentElement;
          continue;
        }
        var cls = (typeof p.className === 'string') ? p.className.trim().split(/\s+/).slice(0, 2).join('.') : '';
        sig.push(tg + (p.id ? '#' + p.id : '') + (cls ? '.' + cls : ''));
        p = p.parentElement;
      }
      var link = el.closest ? el.closest('a[href]') : null;
      out.imgs.push({i: idx++, attrs: a, cur: el.currentSrc || '',
        nw: el.naturalWidth || 0, nh: el.naturalHeight || 0,
        w: Math.round(r.width), h: Math.round(r.height), sig: sig.join('<'),
        link: link ? link.href : ''});
    });
    // Link chapter (trang giới thiệu bộ truyện): chữ hoặc link có
    // "chap/chương/chapter/tập/episode/ep/話/第".
    var chs = [], seenL = {};
    document.querySelectorAll('a[href]').forEach(function(a){
      var h = a.href;
      if (!h || seenL[h] || h.indexOf('javascript:') === 0) return;
      var t = (a.textContent || a.getAttribute('title') || '').replace(/\s+/g, ' ').trim().slice(0, 120);
      if (!/chap|chương|chuong|chapter|episode|tập|tap-\d|\bep\.?\s*\d|話|第/i.test(t + ' ' + h)) return;
      seenL[h] = 1;
      chs.push({href: h, text: t});
    });
    out.links = chs.slice(0, 5000);
    var total = 0;
    document.querySelectorAll('script').forEach(function(s){
      var t = s.textContent || '';
      if (t.length < 20) return;
      var typ = (s.type || '').toLowerCase();
      if (typ.indexOf('json') < 0 && !/\.(jpe?g|png|webp|gif|avif)/i.test(t)) return;
      if (total + t.length > 3000000) return;
      total += t.length;
      out.scripts.push({type: typ, id: s.id || '', text: t});
    });
    var seen = {};
    (window.__comicJson || []).forEach(function(x){ seen[x.url] = 1; out.apis.push(x); });
    var entries = [];
    try {
      // Chỉ đọc lại API cùng trang web (cùng tên miền gốc); bỏ qua link
      // thống kê/quảng cáo (analytics, collect, track, pixel, beacon...).
      var root = location.hostname.split('.').slice(-2).join('.');
      entries = performance.getEntriesByType('resource').filter(function(e){
        if (e.initiatorType !== 'fetch' && e.initiatorType !== 'xmlhttprequest') return false;
        if (seen[e.name]) return false;
        try {
          var u = new URL(e.name);
          var h = u.hostname;
          if (h !== root && h.slice(-(root.length + 1)) !== '.' + root) return false;
          if (/(^|\/)(collect|track|tracking|beacon|pixel|log|logs|analytics|metrics|telemetry|ads)(\/|$)/i.test(u.pathname)) return false;
        } catch (x) { return false; }
        return true;
      }).slice(-25);
    } catch (e) {}
    for (var j = 0; j < entries.length; j++) {
      try {
        var resp = await fetch(entries[j].name, {credentials: 'include'});
        var ct = resp.headers.get('content-type') || '';
        if (ct.indexOf('json') < 0) continue;
        var tx = await resp.text();
        if (tx.length > 2000000) continue;
        out.apis.push({url: entries[j].name, body: tx});
      } catch (e) { out.errors.push('Không đọc lại được API ' + entries[j].name + ': ' + e); }
    }
    ComicScan.postMessage(JSON.stringify(out));
  } catch (e) {
    ComicScan.postMessage(JSON.stringify({error: String(e), url: location.href}));
  }
})();
''';
}
