import 'dart:typed_data';

import 'facebook_video_http.dart';

typedef Mp4Metadata = ({
  int? width,
  int? height,
  double? fps,
  String? codec,
  int? bitrate,
  bool audio,
  bool protected,
});

class _Box {
  const _Box(this.type, this.start, this.data, this.end);
  final String type;
  final int start;
  final int data;
  final int end;
}

_Box? _box(ByteData data, int offset, int limit) {
  if (offset + 8 > data.lengthInBytes) return null;
  var size = data.getUint32(offset);
  final type = String.fromCharCodes(
    List.generate(4, (i) => data.getUint8(offset + 4 + i)),
  );
  var header = 8;
  if (size == 1) {
    if (offset + 16 > data.lengthInBytes) return null;
    size = data.getUint64(offset + 8);
    header = 16;
  } else if (size == 0) {
    size = limit - offset;
  }
  if (size < header || size > limit - offset) return null;
  return _Box(type, offset, offset + header, offset + size);
}

Iterable<_Box> _boxes(ByteData data, int start, int limit) sync* {
  for (var offset = start; offset < limit;) {
    final box = _box(data, offset, limit);
    if (box == null) return;
    yield box;
    offset = box.end;
  }
}

Mp4Metadata? parseMp4Metadata(Uint8List input) {
  final data = ByteData.sublistView(input);
  final moov = _boxes(
    data,
    0,
    input.length,
  ).where((b) => b.type == 'moov').firstOrNull;
  if (moov == null || moov.end > input.length) return null;
  Iterable<_Box> children(_Box parent) => _boxes(data, parent.data, parent.end);
  _Box? child(_Box? parent, String type) => parent == null
      ? null
      : children(parent).where((box) => box.type == type).firstOrNull;

  String codeAt(int index) =>
      String.fromCharCodes(List.generate(4, (i) => data.getUint8(index + i)));
  int? width, height, bitrate;
  double? fps;
  String? codec;
  var audio = false;
  var protected = child(moov, 'pssh') != null;
  for (final track in children(moov).where((b) => b.type == 'trak')) {
    final media = child(track, 'mdia');
    final handler = child(media, 'hdlr');
    if (handler == null || handler.data + 12 > handler.end) continue;
    final type = codeAt(handler.data + 8);
    final table = child(child(media, 'minf'), 'stbl');
    final descriptions = child(table, 'stsd');
    if (descriptions == null || descriptions.data + 8 > descriptions.end) {
      continue;
    }
    final entries = _boxes(
      data,
      descriptions.data + 8,
      descriptions.end,
    ).toList();
    protected |= entries.any(
      (b) =>
          b.type == 'encv' ||
          b.type == 'enca' ||
          b.type == 'drmi' ||
          b.type == 'drms',
    );
    if (type == 'soun' && entries.isNotEmpty) audio = true;
    if (type != 'vide' || entries.isEmpty || codec != null) continue;
    final entry = entries.first;
    codec = entry.type;
    if (entry.data + 28 <= entry.end) {
      width = data.getUint16(entry.data + 24);
      height = data.getUint16(entry.data + 26);
    }
    final header = child(media, 'mdhd');
    final times = child(table, 'stts');
    final lengths = child(table, 'stsz');
    if (header == null ||
        times == null ||
        header.data >= header.end ||
        times.data + 8 > times.end) {
      continue;
    }
    final scaleOffset =
        header.data + (data.getUint8(header.data) == 1 ? 20 : 12);
    if (scaleOffset + 4 > header.end) continue;
    final scale = data.getUint32(scaleOffset);
    final count = data.getUint32(times.data + 4);
    if (scale == 0 || count > (times.end - times.data - 8) ~/ 8) continue;
    var frames = 0;
    var ticks = 0;
    for (var i = 0; i < count; i++) {
      final index = times.data + 8 + i * 8;
      final samples = data.getUint32(index);
      frames += samples;
      ticks += samples * data.getUint32(index + 4);
    }
    if (frames != 0 && ticks > 0) fps = frames * scale / ticks;
    if (lengths != null && lengths.data + 12 <= lengths.end && ticks > 0) {
      final fixed = data.getUint32(lengths.data + 4);
      final samples = data.getUint32(lengths.data + 8);
      var bytes = fixed * samples;
      if (fixed == 0 && samples <= (lengths.end - lengths.data - 12) ~/ 4) {
        for (var i = 0; i < samples; i++) {
          bytes += data.getUint32(lengths.data + 12 + i * 4);
        }
      }
      if (bytes > 0) bitrate = (bytes * 8 * scale / ticks).round();
    }
  }
  if (codec == null && !protected) return null;
  return (
    width: width,
    height: height,
    fps: fps,
    codec: codec,
    bitrate: bitrate,
    audio: audio,
    protected: protected,
  );
}

Future<({int? size, Mp4Metadata? metadata})> probeMp4(
  FacebookVideoHttp network,
  Uri uri,
  Future<void> abort,
) async {
  const firstWindow = 96 * 1024;
  const maxWindow = 1024 * 1024;
  Future<({Uint8List bytes, int size})?> range(int start, int end) async {
    final result = await network.send(
      uri,
      abort: abort,
      headers: {'Range': 'bytes=$start-$end'},
    );
    final response = result.response;
    final header = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$')
        .firstMatch(response.headers['content-range'] ?? '');
    final from = int.tryParse(header?[1] ?? '');
    final to = int.tryParse(header?[2] ?? '');
    final total = int.tryParse(header?[3] ?? '');
    final encoding = response.headers['content-encoding'];
    if (response.statusCode != 206 ||
        from != start ||
        to == null ||
        total == null ||
        to < start ||
        to > end ||
        to >= total ||
        (encoding != null && encoding != 'identity')) {
      await FacebookVideoHttp.discard(response);
      return null;
    }
    final out = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (out.length + chunk.length > to - start + 1) return null;
      out.add(chunk);
    }
    return out.length == to - start + 1
        ? (bytes: out.takeBytes(), size: total)
        : null;
  }

  final head = await range(0, firstWindow - 1);
  if (head == null) return (size: null, metadata: null);
  var from = 0;
  var bytes = head.bytes;
  for (var request = 0; request < 3; request++) {
    final data = ByteData.sublistView(bytes);
    int? next;
    for (final box in _boxes(data, 0, head.size - from).take(128)) {
      if (box.type == 'moov') {
        final length = box.end - box.start;
        if (length > maxWindow) return (size: head.size, metadata: null);
        if (box.end <= bytes.length) {
          return (
            size: head.size,
            metadata: parseMp4Metadata(
              Uint8List.sublistView(bytes, box.start, box.end),
            ),
          );
        }
        next = from + box.start;
        final window = await range(next, next + length - 1);
        return (
          size: head.size,
          metadata: window == null || window.size != head.size
              ? null
              : parseMp4Metadata(window.bytes),
        );
      }
      if (from + box.end < head.size) next = from + box.end;
    }
    if (next == null || next <= from) break;
    final window = await range(next, next + firstWindow - 1);
    if (window == null || window.size != head.size) break;
    from = next;
    bytes = window.bytes;
  }
  return (size: head.size, metadata: null);
}
