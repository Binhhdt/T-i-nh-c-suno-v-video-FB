import 'package:http/http.dart' as http;

/// Kết quả trích xuất nhạc Suno: tiêu đề + ảnh bìa + link audio.
///
/// Lưu ý quan trọng về thực tế trang Suno (đã kiểm chứng bằng fetch thật
/// một trang bài nhạc công khai): Suno KHÔNG công khai link MP3/WAV khi
/// chưa đăng nhập. Field `audio_url` trong JSON trang thường là
/// placeholder `https://studio-api.prod.suno.com/api/forbidden`. Link
/// audio thật nằm trong mảng `media_urls` (thường là file .m4a opus,
/// tải được không cần đăng nhập) và `video_url` (.mp4).
/// Vì vậy [audioUrl] có thể là .mp3 (nếu trang có) hoặc .m4a — UI hiển
/// thị đúng định dạng thực tế, không gán nhãn sai. [wavUrl] chỉ có khi
/// trang công khai link WAV (hiếm) — nếu null, UI tắt chọn WAV.
class SunoSongInfo {
  final String title;
  final String? coverUrl;
  final String audioUrl;
  final String? wavUrl;
  final String? videoUrl;

  /// ID clip Suno (UUID) — cần để xin quyền giải mã file audio
  /// (POST /api/mango/rights). Lấy từ URL audio (/clip/<uuid>) hoặc
  /// og:url (/song/<uuid>). Null nếu không xác định được.
  final String? clipId;

  const SunoSongInfo({
    required this.title,
    required this.audioUrl,
    this.coverUrl,
    this.wavUrl,
    this.videoUrl,
    this.clipId,
  });

  /// Đuôi file theo URL audio thực tế (mp3 / m4a / wav).
  String get audioExtension {
    final lower = audioUrl.toLowerCase().split('?').first;
    if (lower.endsWith('.mp3')) return 'mp3';
    if (lower.endsWith('.m4a')) return 'm4a';
    if (lower.endsWith('.wav')) return 'wav';
    return 'mp3';
  }

  /// True khi link audio thực tế KHÔNG phải mp3 (thường là .m4a) —
  /// UI dùng để ghi chú cho người dùng, tránh hiểu lầm là file MP3.
  bool get audioIsNotMp3 => audioExtension != 'mp3';
}

class SunoNotFoundException implements Exception {
  final String message;
  const SunoNotFoundException(this.message);
}

/// Trích xuất nhạc Suno từ link bài nhạc công khai (không đăng nhập).
class SunoExtractor {
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

  SunoExtractor({http.Client? client}) : _client = client ?? http.Client();

  /// Chuẩn hoá link người dùng dán vào. Chỉ nhận link bài nhạc Suno:
  /// suno.com/song/..., suno.com/s/... (link rút gọn), suno.com/embed/...
  String normalizeUrl(String raw) {
    var url = raw.trim();
    if (url.isEmpty) {
      throw const SunoNotFoundException('Bạn chưa nhập link nhạc.');
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      throw const SunoNotFoundException('Link không hợp lệ.');
    }
    final host = uri.host.toLowerCase();
    if (host != 'suno.com' && host != 'www.suno.com') {
      throw const SunoNotFoundException(
        'Link không phải link nhạc Suno (suno.com/song/...).',
      );
    }
    final path = uri.path.toLowerCase();
    if (!path.contains('/song/') &&
        !path.contains('/s/') &&
        !path.contains('/embed/')) {
      throw const SunoNotFoundException(
        'Link không phải link bài nhạc Suno (suno.com/song/...).',
      );
    }
    return url;
  }

  /// Tải HTML trang bài nhạc Suno và tìm link audio.
  Future<SunoSongInfo> extract(String rawUrl) async {
    final url = normalizeUrl(rawUrl);
    late final http.Response response;
    try {
      response = await _client
          .get(Uri.parse(url), headers: _headers)
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const SunoNotFoundException(
        'Không tải được trang Suno. Kiểm tra mạng và thử lại.',
      );
    }
    if (response.statusCode != 200) {
      throw const SunoNotFoundException(
        'Không tìm thấy nhạc. Có thể bài nhạc riêng tư hoặc link không đúng.',
      );
    }
    return parseHtml(response.body);
  }

  /// Phân tích HTML (tách riêng để test được mà không cần mạng).
  SunoSongInfo parseHtml(String html) {
    final unescaped = _unescape(html);

    final title = _extractTitle(unescaped);
    final coverUrl = _metaProperty(unescaped, 'og:image') ??
        _jsonStringField(unescaped, 'image_large_url') ??
        _jsonStringField(unescaped, 'image_url');
    final videoUrl = _jsonStringField(unescaped, 'video_url');
    final wavUrl = _findWavUrl(unescaped);

    // 1. Ưu tiên mảng media_urls (link audio thật): .mp3 trước, rồi .m4a.
    String? audioUrl = _findMediaAudioUrl(unescaped);

    // 2. Field audio_url — bỏ qua placeholder "forbidden".
    audioUrl ??= _findRealAudioUrlField(unescaped);

    // 3. Fallback: quét link mp3 trên CDN Suno trong HTML.
    audioUrl ??= _findCdnMp3(unescaped);

    if (audioUrl == null) {
      throw const SunoNotFoundException(
        'Không tìm thấy nhạc. Có thể bài nhạc riêng tư hoặc link không đúng.',
      );
    }
    return SunoSongInfo(
      title: title,
      coverUrl: coverUrl,
      audioUrl: audioUrl,
      wavUrl: wavUrl,
      videoUrl: videoUrl,
      clipId: _extractClipId(unescaped, audioUrl),
    );
  }

  /// ID clip (UUID) từ URL audio (/clip/<uuid>.m4a) hoặc og:url
  /// (/song/<uuid>). Cần để xin quyền giải mã file audio.
  String? _extractClipId(String html, String audioUrl) {
    final uuidPattern =
        RegExp(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}');
    final fromAudio = uuidPattern.firstMatch(audioUrl);
    if (fromAudio != null) return fromAudio.group(0);
    final ogUrl = _metaProperty(html, 'og:url');
    if (ogUrl != null) {
      final fromOg = uuidPattern.firstMatch(ogUrl);
      if (fromOg != null) return fromOg.group(0);
    }
    return null;
  }

  String _extractTitle(String html) {
    final ogTitle = _metaProperty(html, 'og:title');
    if (ogTitle != null && ogTitle.isNotEmpty) return ogTitle;
    final m = RegExp(r'<title>([^<]+)</title>', caseSensitive: false)
        .firstMatch(html);
    if (m != null) {
      var t = m.group(1)!.trim();
      // "Tên bài by Tác giả | Suno" -> giữ "Tên bài by Tác giả".
      t = t.replaceAll(RegExp(r'\s*\|\s*Suno\s*$'), '');
      if (t.isNotEmpty) return t;
    }
    return 'Bài nhạc Suno';
  }

  /// Tìm link audio trong mảng media_urls: [{"url": "...", "content_type": "..."}].
  /// Ưu tiên .mp3, sau đó lấy entry đầu tiên (thường là .m4a opus).
  String? _findMediaAudioUrl(String html) {
    final block = RegExp(
      r'"media_urls"\s*:\s*\[(.*?)\]',
      dotAll: true,
    ).firstMatch(html);
    if (block == null) return null;
    final body = block.group(1)!;
    final urls = <String>[];
    final urlPattern = RegExp(r'"url"\s*:\s*"([^"]+)"');
    for (final m in urlPattern.allMatches(body)) {
      final cleaned = _cleanUrl(_fullyDecode(m.group(1)!));
      if (cleaned.startsWith('http') && !_isBlocked(cleaned)) {
        urls.add(cleaned);
      }
    }
    if (urls.isEmpty) return null;
    for (final u in urls) {
      if (u.toLowerCase().split('?').first.endsWith('.mp3')) return u;
    }
    return urls.first;
  }

  /// Field audio_url — Suno thường đặt placeholder "forbidden" khi chưa
  /// đăng nhập nên phải bỏ qua, nếu không sẽ tải về file lỗi.
  String? _findRealAudioUrlField(String html) {
    final v = _jsonStringField(html, 'audio_url') ??
        _jsonStringField(html, 'audioUrl');
    if (v == null) return null;
    final cleaned = _cleanUrl(_fullyDecode(v));
    if (!_isBlocked(cleaned) && cleaned.startsWith('http')) return cleaned;
    return null;
  }

  /// Link mp3 trên CDN Suno trong HTML (bỏ file im lặng sil-100.mp3).
  String? _findCdnMp3(String html) {
    final pattern =
        RegExp(r'https?://cdn[0-9a-z.-]*\.suno\.ai/[^\s\\]*\.mp3[^\s"\\]*');
    for (final m in pattern.allMatches(html)) {
      final cleaned = _cleanUrl(_fullyDecode(m.group(0)!));
      if (cleaned.contains('sil-100')) continue;
      if (cleaned.startsWith('http')) return cleaned;
    }
    return null;
  }

  /// Link WAV nếu trang công khai (field wav_url/wavUrl hoặc URL .wav).
  String? _findWavUrl(String html) {
    final v = _jsonStringField(html, 'wav_url') ??
        _jsonStringField(html, 'wavUrl');
    if (v != null) {
      final cleaned = _cleanUrl(_fullyDecode(v));
      if (!_isBlocked(cleaned) && cleaned.startsWith('http')) return cleaned;
    }
    final pattern = RegExp(r'https?://\S+?\.wav\b');
    for (final m in pattern.allMatches(html)) {
      final cleaned = _cleanUrl(_fullyDecode(m.group(0)!));
      if (!_isBlocked(cleaned) && cleaned.startsWith('http')) {
        return cleaned;
      }
    }
    return null;
  }

  /// URL bị chặn / placeholder — không phải file nhạc thật.
  bool _isBlocked(String url) {
    final lower = url.toLowerCase();
    return lower.contains('forbidden') || lower.contains('sil-100');
  }

  /// Giá trị chuỗi của field JSON "key": "value".
  String? _jsonStringField(String html, String key) {
    final m = RegExp('"$key"\\s*:\\s*"([^"]+)"').firstMatch(html);
    return m?.group(1);
  }

  /// Lấy nội dung thẻ <meta property="og:xxx" content="..."> (cả 2 thứ tự).
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

  /// Cắt ký tự thừa bám ở cuối URL do quét từ HTML.
  String _cleanUrl(String s) {
    var out = s.trim();
    const trailing = '"\'<>\\,.;';
    while (out.isNotEmpty && trailing.contains(out[out.length - 1])) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  /// Giải escape kiểu JSON/HTML: \/ , \u0026 (&), \u0025 (%), &amp; ...
  ///
  /// QUAN TRỌNG (bug 15/10, link /s/ "Tình khúc ngày cũ"): trang Suno thật
  /// nhúng dữ liệu clip trong payload RSC (Next.js `self.__next_f.push`)
  /// với MỌI dấu " đã escape thành \" — nếu không gỡ escape này thì mọi
  /// regex tìm "media_urls" / "audio_url" đều trượt và app báo sai là
  /// "Không tìm thấy nhạc". Lặp tối đa 3 lần để xử lý cả escape lồng nhau
  /// (\\\" -> \" -> ").
  String _unescape(String html) {
    var out = html;
    for (var i = 0; i < 3; i++) {
      final next = out.replaceAll(r'\"', '"');
      if (next == out) break;
      out = next;
    }
    out = out.replaceAll(r'\/', '/');
    out = out.replaceAll(r'\u0022', '"');
    out = out.replaceAll(r'\u0025', '%');
    out = out.replaceAll(r'\u0026', '&');
    out = out.replaceAll(r'\u0023', '#');
    out = out.replaceAll(r'\u003d', '=');
    out = out.replaceAll('&amp;', '&');
    return out;
  }

  /// Giải mã percent-encoding lặp lại (tối đa 2 lần).
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
}
