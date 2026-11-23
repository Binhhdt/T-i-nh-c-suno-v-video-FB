enum VideoSourceKind { mp4, hls, dash }

class VideoPart {
  const VideoPart(this.url, {this.start, this.end});
  final Uri url;
  final int? start;
  final int? end;
  int? get length => start == null ? null : end! - start! + 1;
}

class VideoCandidate {
  const VideoCandidate({
    required this.url,
    this.kind = VideoSourceKind.mp4,
    this.variant = '',
    this.width,
    this.height,
    this.fps,
    this.codec,
    this.bitrate,
    this.bytes,
    this.hasAudio,
    this.video,
    this.audio,
  });

  final String url;
  final VideoSourceKind kind;
  final String variant;
  final int? width;
  final int? height;
  final double? fps;
  final String? codec;
  final int? bitrate;
  final int? bytes;
  final bool? hasAudio;
  final List<VideoPart>? video;
  final List<VideoPart>? audio;

  int get qualityScore {
    if (height == null) return 0;
    return width == null || width! >= height! ? height! : width!;
  }

  String get qualityLabel {
    if (qualityScore == 0) return 'Chưa rõ độ phân giải';
    if (width != null && width! < height!) return '$width × $height';
    return switch (qualityScore) {
      2160 => '4K 2160p',
      1440 => '2K 1440p',
      1080 => 'Full HD 1080p',
      720 => 'HD 720p',
      _ => '${qualityScore}p',
    };
  }

  static int compare(VideoCandidate a, VideoCandidate b) {
    final resolution = b.qualityScore.compareTo(a.qualityScore);
    if (resolution != 0) return resolution;
    final sound = (b.hasAudio == true ? 1 : 0).compareTo(
      a.hasAudio == true ? 1 : 0,
    );
    if (sound != 0) return sound;
    final frameRate = (b.fps ?? 0).compareTo(a.fps ?? 0);
    if (frameRate != 0) return frameRate;
    return (b.bitrate ?? 0).compareTo(a.bitrate ?? 0);
  }

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'variant': variant,
    'width': width,
    'height': height,
    'fps': fps,
    'codec': codec,
    'bitrate': bitrate,
    'bytes': bytes,
    'audio': hasAudio,
  };

  // URLs and signed query parameters are obtained again from the source page.
  factory VideoCandidate.fromJson(Map<String, dynamic> json) => VideoCandidate(
    url: '',
    kind: VideoSourceKind.values.byName(json['kind'] as String),
    variant: json['variant'] as String,
    width: json['width'] as int?,
    height: json['height'] as int?,
    fps: (json['fps'] as num?)?.toDouble(),
    codec: json['codec'] as String?,
    bitrate: json['bitrate'] as int?,
    bytes: json['bytes'] as int?,
    hasAudio: json['audio'] as bool?,
  );
}
