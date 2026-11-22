import 'package:http/http.dart' as http;

/// Một ứng viên file video mp4 tìm được trong HTML của trang Facebook.
class VideoCandidate {
  final String url;
  final String qualityLabel;
  final int qualityScore;

  const VideoCandidate({
    required this.url,
    required this.qualityLabel,
    required this.qualityScore,
  });
}

/// Kết quả trích xuất: danh sách video + ảnh thumbnail (nếu có)
/// + tiêu đề video (nếu lấy được, dùng làm tên file khi tải).
class VideoInfo {
  final List<VideoCandidate> candidates;
  final String? thumbnailUrl;
  final String? title;

  const VideoInfo({required this.candidates, this.thumbnailUrl, this.title});

  VideoCandidate get best => candidates.first;
}

class VideoNotFoundException implements Exception {
  final String message;
  const VideoNotFoundException(this.message);
}

/// Trích xuất video Facebook.
/// Khi [cookieHeader] có giá trị (đã đăng nhập trong WebView), gắn vào
/// request để tải được cả video không công khai mà tài khoản được xem.
/// Khi không đăng nhập, fetch không cookie như v1 (chỉ video công khai).
class FacebookVideoExtractor {
  /// Header trình duyệt đầy đủ: Facebook chặn request thiếu header
  /// (trả 400 ngay cả với User-Agent desktop).
  static const _headers = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/126.0.0.0 Safari/537.36',
    'Accept':
        'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'en-US,en;q=0.9,vi;q=0.8',
    'Upgrade-Insecure-Requests': '1',
  };

  final http.Client _client;

  FacebookVideoExtractor({http.Client? client})
      : _client = client ?? http.Client();

  /// Chuẩn hoá link người dùng dán vào.
  String normalizeUrl(String raw) {
    var url = raw.trim();
    if (url.isEmpty) {
      throw const VideoNotFoundException('Bạn chưa nhập link video.');
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      throw const VideoNotFoundException('Link không hợp lệ.');
    }
    return url;
  }

  /// Tải HTML trang Facebook và tìm link mp4 trực tiếp.
  /// [cookieHeader] là header `Cookie` từ phiên đăng nhập WebView
  /// (chỉ dùng trong bộ nhớ, không lưu trữ).
  Future<VideoInfo> extract(String rawUrl, {String? cookieHeader}) async {
    final url = normalizeUrl(rawUrl);
    late final http.Response response;
    final headers = Map<String, String>.from(_headers);
    if (cookieHeader != null && cookieHeader.isNotEmpty) {
      headers['Cookie'] = cookieHeader;
    }
    try {
      response = await _client
          .get(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const VideoNotFoundException(
        'Không tải được trang Facebook. Kiểm tra mạng và thử lại.',
      );
    }
    if (response.statusCode != 200) {
      throw const VideoNotFoundException(
        'Không tìm thấy video. Có thể video riêng tư hoặc cần đăng nhập.',
      );
    }
    return parseHtml(response.body);
  }

  /// Phân tích HTML (tách riêng để test được mà không cần mạng).
  VideoInfo parseHtml(String html) => _parse(html);

  /// Phân tích trang đã render trong WebView: HTML sau khi JS chạy +
  /// src của các thẻ <video> trong DOM. Src từ DOM được ưu tiên vì đó
  /// là video trình duyệt đang phát thật (HTML thô của Facebook không
  /// chứa link mp4 do trang render bằng JS).
  VideoInfo parseRenderedPage(String html, List<String> videoSrcs) =>
      _parse(html, extraUrls: videoSrcs);

  VideoInfo _parse(String html, {List<String> extraUrls = const []}) {
    final unescaped = _unescapeFacebookHtml(html);

    final candidates = <VideoCandidate>[];
    final seen = <String>{};

    void addCandidate(String rawUrl) {
      final decoded = _fullyDecode(rawUrl);
      if (!decoded.startsWith('http')) return;
      if (!decoded.contains('.mp4')) return;
      if (!seen.add(decoded)) return; // trùng -> bỏ
      candidates.add(VideoCandidate(
        url: decoded,
        qualityLabel: _qualityLabel(decoded),
        qualityScore: _qualityScore(decoded),
      ));
    }

    // 0. Src từ thẻ <video> trong DOM đã render (đáng tin nhất).
    for (final u in extraUrls) {
      addCandidate(u);
    }

    // 1. Ưu tiên thẻ og:video (link video chính của trang).
    final ogVideo = _metaProperty(unescaped, 'og:video');
    if (ogVideo != null) addCandidate(ogVideo);

    // 2. Quét mọi link mp4 trong HTML.
    final mp4Pattern = RegExp(r'https?://\S+?\.mp4\S*');
    final allMp4 = <String>[];
    for (final m in mp4Pattern.allMatches(unescaped)) {
      final cleaned = _cleanUrl(m.group(0)!);
      if (cleaned.contains('.mp4')) allMp4.add(cleaned);
    }
    // Ưu tiên link fbcdn / scontent.
    for (final u in allMp4) {
      if (u.contains('fbcdn') || u.contains('scontent')) addCandidate(u);
    }

    // 3. Fallback: mọi link mp4 bất kỳ trong HTML.
    if (candidates.isEmpty) {
      for (final u in allMp4) {
        addCandidate(u);
      }
    }

    if (candidates.isEmpty) {
      throw const VideoNotFoundException(
        'Không tìm thấy video. Có thể video riêng tư hoặc cần đăng nhập.',
      );
    }

    // Sắp xếp: chất lượng cao nhất lên đầu.
    candidates.sort((a, b) => b.qualityScore.compareTo(a.qualityScore));

    final thumbnail = _metaProperty(unescaped, 'og:image');
    return VideoInfo(
      candidates: candidates,
      thumbnailUrl: thumbnail,
      title: _extractTitle(unescaped),
    );
  }

  /// Tiêu đề video để đặt tên file: og:title -> <title> -> og:description
  /// (dòng đầu, thường là caption). Bỏ hậu tố " | Facebook", bỏ tiêu đề
  /// chung chung ("Facebook") vì đặt tên file bằng nó không có nghĩa.
  /// Trả về null nếu không lấy được tiêu đề có nghĩa.
  String? _extractTitle(String html) {
    String? clean(String? raw) {
      if (raw == null) return null;
      var t = raw.trim();
      // Bỏ hậu tố dạng " | Facebook" / " - Facebook".
      t = t.replaceAll(RegExp(r'\s*[|\-–—]\s*Facebook\s*$'), '').trim();
      if (t.isEmpty) return null;
      if (t.toLowerCase() == 'facebook') return null;
      return t;
    }

    final ogTitle = clean(_metaProperty(html, 'og:title'));
    if (ogTitle != null) return ogTitle;

    final titleMatch = RegExp(
      r'<title>([^<]+)</title>',
      caseSensitive: false,
    ).firstMatch(html);
    final pageTitle = clean(
      titleMatch?.group(1)?.replaceAll(RegExp(r'\s+'), ' '),
    );
    if (pageTitle != null) return pageTitle;

    // Caption (og:description): chỉ lấy dòng đầu.
    final desc = _metaProperty(html, 'og:description');
    if (desc != null) {
      final firstLine = desc.split(RegExp(r'[\r\n]+')).first.trim();
      final cleaned = clean(firstLine);
      if (cleaned != null) return cleaned;
    }
    return null;
  }

  /// Cắt ký tự thừa bám ở cuối URL do quét từ HTML
  /// (dấu ngoặc, phẩy, chấm câu, backslash còn sót).
  String _cleanUrl(String s) {
    var out = s.trim();
    const trailing = '"\'<>\\,.;';
    while (out.isNotEmpty && trailing.contains(out[out.length - 1])) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  /// Facebook escape URL trong HTML: \/ và \u0025 (%), \u0026 (&)...
  String _unescapeFacebookHtml(String html) {
    var out = html.replaceAll(r'\/', '/');
    out = out.replaceAll(r'\u0025', '%');
    out = out.replaceAll(r'\u0026', '&');
    out = out.replaceAll(r'\u0023', '#');
    out = out.replaceAll(r'\u003d', '=');
    out = out.replaceAll('&amp;', '&');
    return out;
  }

  /// Giải mã percent-encoding lặp lại (tối đa 2 lần, tránh vòng lặp).
  String _fullyDecode(String url) {
    var current = url;
    for (var i = 0; i < 2; i++) {
      try {
        final decoded = Uri.decodeFull(current);
        if (decoded == current) break;
        current = decoded;
      } catch (_) {
        break;
      }
    }
    return current;
  }

  /// Lấy nội dung thẻ <meta property="og:xxx" content="..."> (cả 2 thứ tự thuộc tính).
  String? _metaProperty(String html, String property) {
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
      if (m != null) return _fullyDecode(m.group(1)!);
    }
    return null;
  }

  /// Đoán chất lượng từ URL: 1080/720/480/360, hoặc hd/sd.
  int _qualityScore(String url) {
    final lower = url.toLowerCase();
    for (final res in [1080, 720, 480, 360, 240]) {
      if (lower.contains(res.toString())) return res;
    }
    if (lower.contains('hd')) return 720;
    if (lower.contains('sd')) return 360;
    return 0;
  }

  String _qualityLabel(String url) {
    final score = _qualityScore(url);
    if (score >= 1080) return 'Full HD 1080p';
    if (score >= 720) return 'HD 720p';
    if (score >= 480) return '480p';
    if (score > 0) return '${score}p';
    return 'Video';
  }
}
