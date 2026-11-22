import 'package:xml/xml.dart';

import 'facebook_video_http.dart';
import 'video_source.dart';

typedef ReadManifest = Future<({String text, Uri uri})> Function(Uri);

Never _unsupported(String format) => throw FacebookVideoException(
  'Nguồn $format này có cấu trúc chưa hỗ trợ hoặc được bảo vệ.',
);

Uri _resolve(Uri base, String link) {
  final uri = base.resolve(link.trim());
  if (!isFacebookMedia(uri)) _unsupported('video');
  return uri;
}

Map<String, String> _attributes(String line) => {
  for (final match in RegExp(r'([\w-]+)=("[^"]*"|[^,]*)').allMatches(line))
    match[1]!: match[2]!.replaceAll('"', ''),
};

List<String> _lines(String text) =>
    text.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
bool _hlsProtected(List<String> lines) => lines.any(
  (line) =>
      (line.startsWith('#EXT-X-KEY:') ||
          line.startsWith('#EXT-X-SESSION-KEY:')) &&
      _attributes(line)['METHOD'] != 'NONE',
);

List<VideoPart> hlsMedia(String text, Uri base) {
  final lines = _lines(text);
  if (lines.isEmpty ||
      lines.first != '#EXTM3U' ||
      !lines.contains('#EXT-X-ENDLIST') ||
      _hlsProtected(lines) ||
      lines.any(
        (s) =>
            s.startsWith('#EXT-X-DISCONTINUITY') ||
            s.startsWith('#EXT-X-GAP') ||
            s.startsWith('#EXT-X-DEFINE'),
      )) {
    _unsupported('HLS');
  }
  final parts = <VideoPart>[];
  ({int length, int? start})? pending;
  VideoPart? lastSegment;
  ({int length, int? start}) range(String value) {
    final fields = value.split('@');
    final length = int.tryParse(fields.first);
    final start = fields.length == 2 ? int.tryParse(fields.last) : null;
    if (length == null ||
        length <= 0 ||
        fields.length > 2 ||
        fields.length == 2 && (start == null || start < 0)) {
      _unsupported('HLS');
    }
    return (length: length, start: start);
  }

  VideoPart part(
    String link,
    ({int length, int? start})? span, {
    VideoPart? previous,
  }) {
    final uri = _resolve(base, link);
    if (span == null) return VideoPart(uri);
    final start =
        span.start ??
        (previous?.url == uri && previous?.end != null
            ? previous!.end! + 1
            : null);
    if (start == null) _unsupported('HLS');
    return VideoPart(uri, start: start, end: start + span.length - 1);
  }

  for (final line in lines) {
    if (line.startsWith('#EXT-X-MAP:')) {
      final attrs = _attributes(line);
      final link = attrs['URI'];
      if (link == null || parts.isNotEmpty) _unsupported('HLS');
      parts.add(
        part(
          link,
          attrs['BYTERANGE'] == null ? null : range(attrs['BYTERANGE']!),
        ),
      );
    } else if (line.startsWith('#EXT-X-BYTERANGE:')) {
      pending = range(line.substring('#EXT-X-BYTERANGE:'.length));
    } else if (!line.startsWith('#')) {
      lastSegment = part(line, pending, previous: lastSegment);
      parts.add(lastSegment);
      pending = null;
    }
    if (parts.length > 10000) _unsupported('HLS');
  }
  if (lastSegment == null || pending != null) _unsupported('HLS');
  return parts;
}

Future<List<VideoCandidate>> hlsCandidates(
  String text,
  Uri base,
  ReadManifest read,
) async {
  final lines = _lines(text);
  if (lines.isEmpty || lines.first != '#EXTM3U' || _hlsProtected(lines)) {
    _unsupported('HLS');
  }
  final audioGroups = <String, Map<String, String>>{};
  for (final line in lines.where((s) => s.startsWith('#EXT-X-MEDIA:'))) {
    final attrs = _attributes(line);
    final id = attrs['GROUP-ID'];
    if (attrs['TYPE'] == 'AUDIO' &&
        id != null &&
        (!audioGroups.containsKey(id) || attrs['DEFAULT'] == 'YES')) {
      audioGroups[id] = attrs;
    }
  }
  final variants = <VideoCandidate>[];
  var master = false;
  final loadedAudio = <Uri, List<VideoPart>>{};
  for (var i = 0; i < lines.length; i++) {
    if (!lines[i].startsWith('#EXT-X-STREAM-INF:')) continue;
    master = true;
    if (variants.length == 16) break;
    final attrs = _attributes(lines[i]);
    if (i + 1 == lines.length || lines[i + 1].startsWith('#')) {
      _unsupported('HLS');
    }
    final resolution = (attrs['RESOLUTION'] ?? '').split('x');
    final codecs = attrs['CODECS'];
    final group = attrs['AUDIO'];
    final audio = audioGroups[group]?['URI'];
    if (group != null && !audioGroups.containsKey(group)) continue;
    final uri = _resolve(base, lines[i + 1]);
    try {
      final playlist = await read(uri);
      final video = hlsMedia(playlist.text, playlist.uri);
      List<VideoPart>? audioParts;
      if (audio != null) {
        final audioUri = _resolve(base, audio);
        audioParts = loadedAudio[audioUri];
        if (audioParts == null) {
          final playlist = await read(audioUri);
          audioParts = loadedAudio[audioUri] = hlsMedia(
            playlist.text,
            playlist.uri,
          );
        }
      }
      variants.add(
        VideoCandidate(
          url: base.toString(),
          kind: VideoSourceKind.hls,
          variant: [
            attrs['RESOLUTION'],
            attrs['FRAME-RATE'],
            attrs['BANDWIDTH'],
            codecs,
            group,
          ].join(':'),
          width: resolution.length == 2 ? int.tryParse(resolution[0]) : null,
          height: resolution.length == 2 ? int.tryParse(resolution[1]) : null,
          fps: double.tryParse(attrs['FRAME-RATE'] ?? ''),
          codec: codecs,
          bitrate: int.tryParse(
            attrs['AVERAGE-BANDWIDTH'] ?? attrs['BANDWIDTH'] ?? '',
          ),
          hasAudio:
              audioParts != null ||
                  group != null ||
                  RegExp(
                    r'mp4a|ac-3|ec-3|opus',
                    caseSensitive: false,
                  ).hasMatch(codecs ?? '')
              ? true
              : null,
          video: video,
          audio: audioParts,
        ),
      );
    } on FacebookVideoException catch (e) {
      if (e.expired || e.retryable) rethrow;
    }
  }
  if (!master) {
    variants.add(
      VideoCandidate(
        url: base.toString(),
        kind: VideoSourceKind.hls,
        video: hlsMedia(text, base),
      ),
    );
  }
  if (variants.isEmpty) _unsupported('HLS');
  return variants;
}

XmlElement? _child(XmlElement node, String name) =>
    node.findElements(name).firstOrNull;
int? _int(XmlElement? node, String attr) =>
    int.tryParse(node?.getAttribute(attr) ?? '');

Uri _base(XmlElement element, Uri parent) {
  final selected = _child(element, 'BaseURL')?.innerText;
  return selected == null ? parent : _resolve(parent, selected);
}

double? frameRate(String? raw) {
  if (raw == null) return null;
  final fields = raw.split('/');
  final first = double.tryParse(fields.first);
  final second = fields.length == 2 ? double.tryParse(fields.last) : 1.0;
  if (first == null || second == null || second <= 0 || !first.isFinite) {
    return null;
  }
  return first / second;
}

double? _duration(String? raw) {
  if (raw == null) return null;
  final match = RegExp(r'^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?$')
      .firstMatch(raw);
  if (match == null) return null;
  return (int.tryParse(match[1] ?? '') ?? 0) * 3600 +
      (int.tryParse(match[2] ?? '') ?? 0) * 60 +
      (double.tryParse(match[3] ?? '') ?? 0);
}

List<VideoCandidate> dashCandidates(String text, Uri uri) {
  if (text.contains('<!DOCTYPE') || text.contains('<!ENTITY')) {
    _unsupported('DASH');
  }
  final mpd = XmlDocument.parse(text).rootElement;
  if (mpd.name.local != 'MPD' ||
      mpd.getAttribute('type') == 'dynamic' ||
      mpd.descendantElements.any(
        (e) => {
          'ContentProtection',
          'pssh',
          'laurl',
          'Laurl',
        }.contains(e.name.local),
      )) {
    _unsupported('DASH');
  }
  final period = mpd.findElements('Period').singleOrNull;
  if (period == null) _unsupported('DASH');
  final seconds = _duration(
    period.getAttribute('duration') ??
        mpd.getAttribute('mediaPresentationDuration'),
  );
  final periodBase = _base(period, _base(mpd, uri));
  final tracks =
      <
        ({XmlElement rep, XmlElement set, String type, List<VideoPart> parts})
      >[];
  for (final set in period.findElements('AdaptationSet')) {
    for (final rep in set.findElements('Representation')) {
      final mime =
          rep.getAttribute('mimeType') ?? set.getAttribute('mimeType') ?? '';
      final type =
          rep.getAttribute('contentType') ??
          set.getAttribute('contentType') ??
          mime.split('/').first;
      if (!{'video', 'audio'}.contains(type) ||
          mime.isNotEmpty && !mime.endsWith('/mp4')) {
        continue;
      }
      try {
        final parts = _dashParts(
          period,
          set,
          rep,
          _base(rep, _base(set, periodBase)),
          uri,
          seconds,
        );
        tracks.add((rep: rep, set: set, type: type, parts: parts));
      } on FacebookVideoException {
        continue;
      }
    }
  }
  final audios = tracks.where((track) => track.type == 'audio').toList()
    ..sort(
      (a, b) => (_int(b.rep, 'bandwidth') ?? 0).compareTo(
        _int(a.rep, 'bandwidth') ?? 0,
      ),
    );
  final audio = audios.firstOrNull;
  // Do not offer silently muted variants when an advertised audio track cannot be read.
  if (audio == null &&
      period
          .findElements('AdaptationSet')
          .any(
            (set) =>
                set.getAttribute('contentType') == 'audio' ||
                (set.getAttribute('mimeType') ?? '').startsWith('audio/') ||
                set
                    .findElements('Representation')
                    .any(
                      (rep) => (rep.getAttribute('mimeType') ?? '').startsWith(
                        'audio/',
                      ),
                    ),
          )) {
    _unsupported('DASH');
  }
  final options = <VideoCandidate>[];
  for (final track in tracks.where((t) => t.type == 'video')) {
    final rep = track.rep;
    final set = track.set;
    final bitrate = _int(rep, 'bandwidth');
    final allParts = [...track.parts, ...?audio?.parts];
    options.add(
      VideoCandidate(
        url: uri.toString(),
        kind: VideoSourceKind.dash,
        variant: [
          set.getAttribute('id'),
          rep.getAttribute('id'),
          _int(rep, 'width'),
          _int(rep, 'height'),
          bitrate,
          audio?.rep.getAttribute('id'),
        ].join(':'),
        width: _int(rep, 'width') ?? _int(set, 'width'),
        height: _int(rep, 'height') ?? _int(set, 'height'),
        fps: frameRate(
          rep.getAttribute('frameRate') ?? set.getAttribute('frameRate'),
        ),
        codec: rep.getAttribute('codecs') ?? set.getAttribute('codecs'),
        bitrate: bitrate,
        bytes: allParts.every((p) => p.length != null)
            ? allParts.fold<int>(0, (sum, p) => sum + p.length!)
            : seconds != null && bitrate != null
            ? (seconds * (bitrate + (_int(audio?.rep, 'bandwidth') ?? 0)) / 8)
                  .round()
            : null,
        hasAudio: audio != null ? true : null,
        video: track.parts,
        audio: audio?.parts,
      ),
    );
  }
  if (options.isEmpty) _unsupported('DASH');
  return options;
}

List<VideoPart> _dashParts(
  XmlElement period,
  XmlElement set,
  XmlElement rep,
  Uri base,
  Uri origin,
  double? seconds,
) {
  VideoPart part(String? path, [String? range]) {
    final uri = path == null ? base : _resolve(base, path);
    if (uri == origin) _unsupported('DASH');
    if (range == null) return VideoPart(uri);
    final fields = range.split('-');
    final start = int.tryParse(fields.first);
    final end = int.tryParse(fields.last);
    if (fields.length != 2 ||
        start == null ||
        end == null ||
        start < 0 ||
        end < start) {
      _unsupported('DASH');
    }
    return VideoPart(uri, start: start, end: end);
  }

  final parents = [rep, set, period];
  final layout = parents
      .expand((e) => e.childElements)
      .firstWhere(
        (e) => {
          'SegmentList',
          'SegmentTemplate',
          'SegmentBase',
        }.contains(e.name.local),
        orElse: () => XmlElement(XmlName('BaseURL')),
      )
      .name
      .local;
  final configs = parents.map((e) => _child(e, layout)).nonNulls.toList();
  String? attr(String name) =>
      configs.map((e) => e.getAttribute(name)).nonNulls.firstOrNull;
  XmlElement? child(String name) =>
      configs.map((e) => _child(e, name)).nonNulls.firstOrNull;

  if (layout == 'SegmentList') {
    final init = child('Initialization');
    final segments = configs
        .map((e) => e.findElements('SegmentURL'))
        .firstWhere((e) => e.isNotEmpty, orElse: () => []);
    if (segments.isEmpty || segments.length > 10000) _unsupported('DASH');
    return [
      if (init != null)
        part(init.getAttribute('sourceURL'), init.getAttribute('range')),
      for (final entry in segments)
        part(entry.getAttribute('media'), entry.getAttribute('mediaRange')),
    ];
  }
  if (layout != 'SegmentTemplate') return [part(null)];
  final media = attr('media');
  final init = attr('initialization');
  if (media == null || init == null) _unsupported('DASH');
  final timescale = int.tryParse(attr('timescale') ?? '1') ?? 0;
  var number = int.tryParse(attr('startNumber') ?? '1') ?? 1;
  final offset = int.tryParse(attr('presentationTimeOffset') ?? '0') ?? 0;
  if (timescale <= 0 || number < 0 || offset < 0) _unsupported('DASH');
  String expand(String value, int time) => value.replaceAllMapped(
    RegExp(r'\$(?:\$|(RepresentationID|Bandwidth|Time|Number)(?:%0(\d+)d)?\$)'),
    (match) {
      final field = match[1];
      final replacement = switch (field) {
        null => r'$',
        'RepresentationID' => rep.getAttribute('id'),
        'Bandwidth' => rep.getAttribute('bandwidth'),
        'Time' => time.toString(),
        _ => number.toString(),
      };
      final padding = int.tryParse(match[2] ?? '') ?? 0;
      if (replacement == null || padding > 20) _unsupported('DASH');
      return replacement.padLeft(padding, '0');
    },
  );

  final timeline = child('SegmentTimeline')?.findElements('S').toList();
  final parts = [part(expand(init, 0))];
  void add(int time) {
    if (parts.length >= 10001) _unsupported('DASH');
    parts.add(part(expand(media, time)));
    number++;
  }

  if (timeline == null) {
    final duration = int.tryParse(attr('duration') ?? '');
    if (duration == null || duration <= 0 || seconds == null) {
      _unsupported('DASH');
    }
    final count = (seconds * timescale / duration).ceil();
    for (var index = 0; index < count; index++) {
      add(index * duration + offset);
    }
  } else {
    var time = 0;
    for (var index = 0; index < timeline.length; index++) {
      final segment = timeline[index];
      time = _int(segment, 't') ?? time;
      final duration = _int(segment, 'd');
      if (duration == null || duration <= 0 || time < 0) _unsupported('DASH');
      final repeat = _int(segment, 'r') ?? 0;
      final end = index + 1 < timeline.length
          ? _int(timeline[index + 1], 't')
          : seconds == null
          ? null
          : (seconds * timescale).ceil() + offset;
      if (repeat < 0 && (end == null || end <= time)) _unsupported('DASH');
      final count = repeat >= 0
          ? repeat + 1
          : ((end! - time) / duration).ceil();
      for (var entry = 0; entry < count; entry++) {
        add(time);
        time += duration;
      }
    }
  }
  if (parts.length == 1) _unsupported('DASH');
  return parts;
}
