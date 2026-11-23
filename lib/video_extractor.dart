import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'facebook_video_http.dart';
import 'video_manifest.dart';
import 'video_mp4_metadata.dart';
import 'video_source.dart';

export 'video_source.dart' show VideoCandidate, VideoSourceKind;

class VideoInfo {
  const VideoInfo({required this.candidates, this.thumbnailUrl, this.title});
  final List<VideoCandidate> candidates;
  final String? thumbnailUrl;
  final String? title;
  VideoCandidate get best => candidates.first;
}

class VideoNotFoundException extends FacebookVideoException {
  const VideoNotFoundException(super.message);
}

class FacebookVideoExtractor {
  FacebookVideoExtractor({http.Client? client})
    : _network = FacebookVideoHttp(client);

  final FacebookVideoHttp _network;

  String normalizeUrl(String raw) {
    final input = raw.trim();
    if (input.isEmpty) {
      throw const VideoNotFoundException('Bạn chưa nhập link video.');
    }
    final shared = RegExp(
      r'https?://[^\s<>]+',
      caseSensitive: false,
    ).firstMatch(input)?.group(0);
    final url = shared ?? (input.contains('://') ? input : 'https://$input');
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort &&
            uri.port != 443 &&
            !(uri.scheme == 'http' && uri.port == 80) ||
        !{'http', 'https'}.contains(uri.scheme)) {
      throw const VideoNotFoundException('Link Facebook không hợp lệ.');
    }
    final secure = uri.replace(scheme: 'https', port: 443).removeFragment();
    if (!isFacebookPage(secure)) {
      throw const VideoNotFoundException('Chỉ hỗ trợ liên kết video Facebook.');
    }
    return secure.toString();
  }

  Future<VideoInfo> extract(
    String rawUrl, {
    String? cookieHeader,
    Future<void>? abort,
  }) async {
    final url = Uri.parse(normalizeUrl(rawUrl));
    final response = await _network.read(
      url,
      page: true,
      cookie: cookieHeader,
      limit: 12 * 1024 * 1024,
      abort: abort,
    );
    return _complete(
      _parse(FacebookVideoHttp.text(response.bytes), page: response.uri),
      abort: abort,
    );
  }

  VideoInfo parseHtml(String html) => _requireVideo(_parse(html));
  VideoInfo parseRenderedPage(String html, List<String> videoSrcs) =>
      _requireVideo(
        _parse(
          html,
          rendered: [
            for (final url in videoSrcs) {'url': url},
          ],
        ),
      );

  Future<VideoInfo> extractRendered(
    String html,
    List<Map<String, dynamic>> videos,
    String page,
  ) => _complete(
    _parse(html, rendered: videos, page: Uri.parse(normalizeUrl(page))),
  );

  void close() => _network.close();

  VideoInfo _requireVideo(VideoInfo info) {
    if (info.candidates.isEmpty) {
      throw const VideoNotFoundException(
        'Không tìm thấy video có thể tải. Video có thể yêu cầu đăng nhập.',
      );
    }
    return info;
  }

  Future<VideoInfo> _complete(VideoInfo info, {Future<void>? abort}) async {
    final output = <VideoCandidate>[];
    FacebookVideoException? lastError;
    for (final candidate in info.candidates) {
      if (candidate.video != null || candidate.kind == VideoSourceKind.mp4) {
        output.add(candidate);
        continue;
      }
      try {
        Future<({String text, Uri uri})> read(Uri uri) async {
          final data = await _network.read(uri, abort: abort);
          return (text: FacebookVideoHttp.text(data.bytes), uri: data.uri);
        }

        final manifest = await read(Uri.parse(candidate.url));
        output.addAll(
          candidate.kind == VideoSourceKind.hls
              ? await hlsCandidates(manifest.text, manifest.uri, read)
              : dashCandidates(manifest.text, manifest.uri),
        );
      } on FacebookVideoException catch (e) {
        lastError = e;
      } on FormatException {
        lastError = const VideoNotFoundException(
          'Manifest video không hợp lệ.',
        );
      } catch (_) {
        lastError = const FacebookVideoException(
          'Không đọc được manifest video.',
          retryable: true,
        );
      }
    }
    if (output.isEmpty && lastError != null) throw lastError;
    final direct = output
        .where((item) => item.kind == VideoSourceKind.mp4 && item.video == null)
        .take(8)
        .toList();
    final probes = await Future.wait(
      direct.map((item) async {
        final deadline = Completer<void>();
        final timer = Timer(const Duration(seconds: 5), deadline.complete);
        final stop = abort == null
            ? deadline.future
            : Future.any([abort, deadline.future]);
        try {
          final url = Uri.parse(item.url);
          final result = await probeMp4(_network, url, stop);
          final metadata = result.metadata;
          if (metadata?.protected == true) return null;
          var size = result.size ?? item.bytes;
          if (size == null) {
            final head = await _network.send(url, method: 'HEAD', abort: stop);
            await FacebookVideoHttp.discard(head.response);
            if (head.response.statusCode == 200 &&
                head.response.headers['content-type']?.contains('text/html') !=
                    true) {
              size = head.response.contentLength;
            }
          }
          return VideoCandidate(
            url: item.url,
            variant: item.variant,
            width: metadata?.width ?? item.width,
            height: metadata?.height ?? item.height,
            fps: metadata?.fps ?? item.fps,
            codec: metadata?.codec ?? item.codec,
            bitrate: metadata?.bitrate ?? item.bitrate,
            bytes: size != null && size > 0 ? size : null,
            hasAudio: metadata?.audio ?? item.hasAudio,
          );
        } catch (_) {
          return item;
        } finally {
          timer.cancel();
        }
      }),
    );
    for (var i = 0; i < direct.length; i++) {
      final result = probes[i];
      if (result == null) {
        output.remove(direct[i]);
      } else {
        output[output.indexOf(direct[i])] = result;
      }
    }
    output.sort(VideoCandidate.compare);
    return _requireVideo(
      VideoInfo(
        candidates: output,
        thumbnailUrl: info.thumbnailUrl,
        title: info.title,
      ),
    );
  }

  VideoInfo _parse(
    String html, {
    List<Map<String, dynamic>> rendered = const [],
    Uri? page,
  }) {
    final candidates = <String, VideoCandidate>{};
    final rejected = <String>{};
    int? positiveInt(Object? value) {
      final number = int.tryParse(value?.toString() ?? '');
      return number != null && number > 0 ? number : null;
    }

    void add(String? raw, {String? key, Map<String, dynamic>? metadata}) {
      if (raw == null) return;
      final url = _entities(raw);
      final uri = Uri.tryParse(url);
      if (uri == null ||
          !isFacebookMedia(uri) ||
          rejected.contains(url) ||
          candidates.length >= 32 && !candidates.containsKey(url)) {
        return;
      }
      final path = uri.path.toLowerCase();
      final kind = path.endsWith('.m3u8') || key == 'hls_manifest_url'
          ? VideoSourceKind.hls
          : path.endsWith('.mpd') || key == 'dash_manifest_url'
          ? VideoSourceKind.dash
          : VideoSourceKind.mp4;
      if (kind == VideoSourceKind.mp4 &&
          !path.endsWith('.mp4') &&
          key == null) {
        return;
      }
      final old = candidates[url];
      final data = metadata ?? const <String, dynamic>{};
      final audio = data['has_audio'];
      final audioUrl = Uri.tryParse(
        _entities(data['audio_url']?.toString() ?? ''),
      );
      final paired =
          audioUrl != null && isFacebookMedia(audioUrl) && uri != audioUrl;
      if (paired) candidates.remove(audioUrl.toString());
      candidates[url] = VideoCandidate(
        url: url,
        kind: kind,
        variant: old?.variant.isNotEmpty == true ? old!.variant : key ?? '',
        width: positiveInt(data['width']) ?? old?.width,
        height: positiveInt(data['height']) ?? old?.height,
        fps:
            frameRate((data['fps'] ?? data['frame_rate'])?.toString()) ??
            old?.fps,
        codec: (data['codec'] ?? data['codecs'])?.toString() ?? old?.codec,
        bitrate: positiveInt(data['bitrate']) ?? old?.bitrate,
        bytes:
            positiveInt(data['content_length'] ?? data['filesize']) ??
            old?.bytes,
        hasAudio: paired
            ? true
            : audio is bool
            ? audio
            : old?.hasAudio,
        video: paired ? [VideoPart(uri)] : old?.video,
        audio: paired ? [VideoPart(audioUrl)] : old?.audio,
      );
    }

    final recognized = RegExp(
      r'"(playable_url(?:_quality_hd)?|browser_native_(?:hd|sd)_url|native_(?:hd|sd)_url|hls_manifest_url|dash_manifest_url|dash_manifest|base_url)"\s*:\s*("(?:\\.|[^"\\])*")',
    );
    // Read adjacent metadata only when the URL belongs to the same JSON object.
    Map<String, dynamic>? objectAt(int index) {
      var start = index - 1;
      while (start >= 0 &&
          index - start < 4096 &&
          !'{}<>'.contains(html[start])) {
        start--;
      }
      if (start < 0 || html[start] != '{') return null;
      final end = html.indexOf('}', index);
      if (end < 0 || end - start > 65536) return null;
      try {
        final object = jsonDecode(html.substring(start, end + 1));
        return object is Map<String, dynamic> ? object : null;
      } on FormatException {
        return null;
      }
    }

    final manifests = <VideoCandidate>[];
    for (final match in recognized.allMatches(html)) {
      final key = match[1]!;
      final raw = jsonDecode(match[2]!) as String;
      if (key == 'dash_manifest' && page != null) {
        try {
          manifests.addAll(dashCandidates(_entities(raw), page));
        } on FormatException {
          continue;
        } on FacebookVideoException {
          continue;
        }
        continue;
      }
      final object = objectAt(match.start);
      final metadata =
          key.endsWith('_hd') ||
              key.contains('_hd_') ||
              key.contains('_sd_') ||
              object?['dash_manifest'] != null
          ? null
          : object;
      if (object?['is_drm'] == true ||
          object?['is_protected'] == true ||
          object?['drm_info'] != null) {
        rejected.add(_entities(raw));
        candidates.remove(_entities(raw));
        continue;
      }
      if (key == 'base_url' &&
          !(raw.contains('.mpd') || raw.contains('.m3u8'))) {
        continue;
      }
      add(raw, key: key, metadata: metadata);
    }

    final og = _meta(html, 'og:video:secure_url') ?? _meta(html, 'og:video');
    final ogType = _meta(html, 'og:video:type');
    add(
      og,
      key: ogType?.contains('mpegurl') == true
          ? 'hls_manifest_url'
          : ogType?.contains('dash+xml') == true
          ? 'dash_manifest_url'
          : ogType == 'video/mp4'
          ? 'og:video'
          : null,
      metadata: {
        'width': _meta(html, 'og:video:width'),
        'height': _meta(html, 'og:video:height'),
      },
    );
    for (final data in rendered) {
      add(data['url']?.toString(), key: 'dom', metadata: data);
    }
    if (candidates.isEmpty && manifests.isEmpty && rejected.isEmpty) {
      final unescaped = html.replaceAll(r'\/', '/').replaceAll(r'\u0026', '&');
      for (final match in RegExp(
        r'''https://[^\s"'<>\\]+?\.(?:mp4|m3u8|mpd)(?:\?[^\s"'<>\\]+)?''',
        caseSensitive: false,
      ).allMatches(unescaped).take(24)) {
        add(match[0]);
      }
    }
    final options = [...candidates.values, ...manifests]
      ..sort(VideoCandidate.compare);
    final thumb = Uri.tryParse(_meta(html, 'og:image') ?? '');
    return VideoInfo(
      candidates: options,
      thumbnailUrl: thumb != null && isFacebookMedia(thumb)
          ? thumb.toString()
          : null,
      title: _title(html),
    );
  }

  String? _title(String html) {
    for (final raw in [
      _meta(html, 'og:title'),
      RegExp(
        r'<title>([^<]+)</title>',
        caseSensitive: false,
      ).firstMatch(html)?[1],
      _meta(html, 'og:description')?.split(RegExp(r'[\r\n]+')).first,
    ]) {
      final title = _entities(raw ?? '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .replaceAll(
            RegExp(r'\s*[|\-–—]\s*Facebook\s*$', caseSensitive: false),
            '',
          )
          .trim();
      if (title.isNotEmpty && title.toLowerCase() != 'facebook') return title;
    }
    return null;
  }

  String? _meta(String html, String property) {
    for (final match in RegExp(
      r'<meta\b[^>]+>',
      caseSensitive: false,
    ).allMatches(html)) {
      final attributes = {
        for (final attr in RegExp(
          r'''([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')''',
        ).allMatches(match[0]!))
          attr[1]!.toLowerCase(): attr[2] ?? attr[3]!,
      };
      if ((attributes['property'] ?? attributes['name']) == property) {
        final value = attributes['content'];
        return value == null ? null : _entities(value);
      }
    }
    return null;
  }

  String _entities(String value) => value.replaceAllMapped(
    RegExp(r'&(?:amp|quot|apos|lt|gt|#x[0-9a-fA-F]+|#\d+);'),
    (m) {
      final key = m[0]!.substring(1, m[0]!.length - 1);
      final number = key.startsWith('#x')
          ? int.tryParse(key.substring(2), radix: 16)
          : key.startsWith('#')
          ? int.tryParse(key.substring(1))
          : null;
      return switch (key) {
        'amp' => '&',
        'quot' => '"',
        'apos' => "'",
        'lt' => '<',
        'gt' => '>',
        _ =>
          number != null && number > 0 && number <= 0x10ffff
              ? String.fromCharCode(number)
              : m[0]!,
      };
    },
  );
}
