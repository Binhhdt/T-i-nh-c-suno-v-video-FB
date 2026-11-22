import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fb_video_downloader/downloader.dart';
import 'package:fb_video_downloader/facebook_video_http.dart';
import 'package:fb_video_downloader/video_download_queue.dart';
import 'package:fb_video_downloader/video_extractor.dart';
import 'package:fb_video_downloader/video_manifest.dart';
import 'package:fb_video_downloader/video_mp4_metadata.dart';
import 'package:fb_video_downloader/video_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

const _base = 'https://video.fbcdn.net/media/';
const _url = '${_base}clip.mp4';
const _source = VideoCandidate(url: _url, hasAudio: true);

class _Transport extends http.BaseClient {
  _Transport(this.respond);
  final Future<http.StreamedResponse> Function(http.BaseRequest) respond;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      respond(request);
}

http.StreamedResponse _response(
  List<int> bytes, {
  int code = 200,
  Map<String, String> headers = const {},
  int? declaredLength,
}) => http.StreamedResponse(
  Stream.value(bytes),
  code,
  headers: headers,
  contentLength: declaredLength ?? bytes.length,
);

Future<void> _ffmpeg(List<String> args) async {
  final result = await Process.run('ffmpeg', [
    '-hide_banner',
    '-loglevel',
    'error',
    '-y',
    ...args,
  ]);
  if (result.exitCode != 0) throw StateError(result.stderr.toString());
}

Future<Map<String, dynamic>> _inspect(String path) async {
  final result = await Process.run('ffprobe', [
    '-v',
    'error',
    '-show_entries',
    'stream=codec_type',
    '-of',
    'json',
    path,
  ]);
  if (result.exitCode != 0) return {};
  final info = jsonDecode(result.stdout as String) as Map<String, dynamic>;
  final codecs = (info['streams'] as List).map((s) => s['codec_type']);
  return {'video': codecs.contains('video'), 'audio': codecs.contains('audio')};
}

void main() {
  late Directory fixture;
  late Directory job;
  late List<int> mp4;

  setUpAll(() async {
    fixture = await Directory.systemTemp.createTemp('facebook_video_media');
    await _ffmpeg([
      '-f',
      'lavfi',
      '-i',
      'color=blue:size=1280x720:rate=24',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440:sample_rate=44100',
      '-t',
      '2.2',
      '-c:v',
      'libx264',
      '-threads',
      '2',
      '-g',
      '24',
      '-c:a',
      'aac',
      '-movflags',
      '+faststart',
      '${fixture.path}/clip.mp4',
    ]);
    mp4 = await File('${fixture.path}/clip.mp4').readAsBytes();
  });

  setUp(
    () async =>
        job = await Directory.systemTemp.createTemp('facebook_video_job'),
  );
  tearDown(() async => job.delete(recursive: true));
  tearDownAll(() async => fixture.delete(recursive: true));

  Future<File> download(
    Future<http.StreamedResponse> Function(http.BaseRequest) respond, {
    VideoCandidate source = _source,
    VideoTransferControl? control,
    Future<VideoCandidate> Function()? refresh,
    TransferProgress? progress,
    InspectVideo inspect = _inspect,
    Directory? target,
  }) async {
    final http = FacebookVideoHttp(_Transport(respond));
    try {
      return await VideoDownloader().downloadFacebookVideo(
        source: source,
        staging: target ?? job,
        control: control ?? VideoTransferControl(),
        onProgress: progress ?? (_, _) {},
        inspect: inspect,
        refresh:
            refresh ??
            () async => throw StateError('URL should not be refreshed'),
        transport: http,
        backoff: Duration.zero,
        mux: (args, _) async {
          await _ffmpeg(args);
          return true;
        },
      );
    } finally {
      http.close();
    }
  }

  test('reads true HD, FPS, codec, sound and duration-based bitrate from MP4 boxes', () async {
    final metadata = parseMp4Metadata(
      await File('${fixture.path}/clip.mp4').readAsBytes(),
    )!;
    expect(metadata.width, 1280);
    expect(metadata.height, 720);
    expect(metadata.fps, 24);
    expect(metadata.codec, 'avc1');
    expect(metadata.audio, isTrue);
    expect(metadata.bitrate, greaterThan(0));
  });

  test('short link forwards cookies only to Facebook and measures the selected MP4', () async {
    final extractor = FacebookVideoExtractor(
      client: _Transport((req) async {
        if (req.url.host == 'fb.watch') {
          expect(req.headers['Cookie'], isNull);
          return _response(
            [],
            code: 302,
            headers: {'location': 'https://www.facebook.com/reel/123'},
          );
        }
        if (req.url.host == 'www.facebook.com') {
          expect(req.headers['Cookie'], 'c_user=test; xs=test');
          return _response(
            utf8.encode('<meta property="og:video" content="$_url">'),
          );
        }
        expect(req.headers['Cookie'], isNull);
        expect(req.headers['range'], startsWith('bytes=0-'));
        return _response(
          mp4,
          code: 206,
          headers: {'content-range': 'bytes 0-${mp4.length - 1}/${mp4.length}'},
        );
      }),
    );
    addTearDown(extractor.close);
    final info = await extractor.extract(
      'Video https://fb.watch/x/',
      cookieHeader: 'c_user=test; xs=test',
    );
    expect(info.best.height, 720);
    expect(info.best.bytes, mp4.length);
    expect(info.best.hasAudio, isTrue);
  });

  test(
    'blocks redirect to third-party, local, credentialed and non-HTTPS sources',
    () async {
      for (final redirect in [
        'https://localhost/',
        'https://127.0.0.1/',
        'http://www.facebook.com/watch',
        'https://user@www.facebook.com/watch',
        'https://www.facebook.com.evil.test/watch',
      ]) {
        var calls = 0;
        final network = FacebookVideoHttp(
          _Transport((_) async {
            calls++;
            return _response([], code: 302, headers: {'location': redirect});
          }),
        );
        await expectLater(
          network.send(Uri.parse('https://fb.watch/abc/'), page: true),
          throwsA(isA<FacebookVideoException>()),
        );
        network.close();
        expect(calls, 1);
      }
    },
  );

  test(
    'downloads a direct MP4 and verifies tracks before reporting completion',
    () async {
      final result = await download((_) async => _response(mp4));
      expect(await result.readAsBytes(), mp4);
    },
  );

  test('pauses and resumes after reopening with Range and If-Range', () async {
    final control = VideoTransferControl();
    const cut = 4096;
    await expectLater(
      download(
        (_) async => http.StreamedResponse(
          Stream.fromIterable([mp4.sublist(0, cut), mp4.sublist(cut)]),
          200,
          headers: {'etag': '"clip"'},
          contentLength: mp4.length,
        ),
        control: control,
        progress: (bytes, _) {
          if (bytes == cut) control.stop();
        },
      ),
      throwsA(isA<VideoTransferStopped>()),
    );
    expect(await File('${job.path}/part-0').length(), cut);
    final result = await download(
      (request) async {
        expect(request.headers['range'], 'bytes=$cut-');
        expect(request.headers['if-range'], '"clip"');
        return _response(
          mp4.sublist(cut),
          code: 206,
          headers: {
            'etag': '"clip"',
            'content-range': 'bytes $cut-${mp4.length - 1}/${mp4.length}',
          },
        );
      },
      source: VideoCandidate.fromJson(_source.toJson()),
      refresh: () async => _source,
    );
    expect(await result.readAsBytes(), mp4);
  });

  test('network drops and a server without Range restarts from a verified 200 response', () async {
    var calls = 0;
    final result = await download((request) async {
      if (++calls == 1) {
        Stream<List<int>> disconnect() async* {
          yield mp4.sublist(0, 4096);
          throw const SocketException('network lost');
        }

        return http.StreamedResponse(
          disconnect(),
          200,
          headers: {'etag': '"old"'},
          contentLength: mp4.length,
        );
      }
      expect(request.headers['range'], 'bytes=4096-');
      return _response(mp4, headers: {'etag': '"new"'});
    });
    expect(calls, 2);
    expect(await result.readAsBytes(), mp4);
  });

  test('streams a large verified MP4 in bounded chunks', () async {
    const extra = 12 * 1024 * 1024;
    final start = ByteData(8)
      ..setUint32(0, extra)
      ..setUint32(4, 0x66726565);
    final block = Uint8List(1024 * 1024);
    Stream<List<int>> large() async* {
      yield mp4;
      yield start.buffer.asUint8List();
      for (var part = 0; part < 11; part++) {
        yield block;
      }
      yield Uint8List.sublistView(block, 0, block.length - 8);
    }

    final result = await download(
      (_) async => http.StreamedResponse(
        large(),
        200,
        contentLength: mp4.length + extra,
      ),
    );
    expect(await result.length(), mp4.length + extra);
  });

  test('reports an out-of-space write without reporting success', () async {
    final full = File('/dev/full');
    expect(await full.exists(), isTrue);
    await Link('${job.path}/part-0').create(full.path);
    await expectLater(
      download((_) async => _response(mp4)),
      throwsA(
        isA<FileSystemException>().having(
          (error) => error.osError?.errorCode,
          'errno',
          28,
        ),
      ),
    );
  });

  test('maximum of three retries when server is unavailable', () async {
    var calls = 0;
    await expectLater(
      download((_) async {
        calls++;
        return _response([], code: 503);
      }),
      throwsA(isA<FacebookVideoException>()),
    );
    expect(calls, 4);
  });

  test(
    'refreshes an expired media URL only once and keeps quality choice',
    () async {
      var refreshes = 0;
      final result = await download(
        (request) async {
          if (request.url.query.isEmpty) return _response([], code: 403);
          expect(request.url.query, 'renewed=1');
          return _response(mp4);
        },
        refresh: () async {
          refreshes++;
          return const VideoCandidate(url: '$_url?renewed=1', hasAudio: true);
        },
      );
      expect(await result.length(), mp4.length);
      expect(refreshes, 1);
    },
  );

  test('preserves name and state for three independent tasks and never queues a cancelled task', () async {
    final jobs = [
      for (final state in [
        VideoJobState.downloading,
        VideoJobState.paused,
        VideoJobState.cancelled,
      ])
        VideoJob(
          id: state.name,
          page: 'https://www.facebook.com/watch/?v=123',
          title: 'Mưa trên phố',
          source: _source,
          state: state,
        ),
    ];
    final entries = jobs
        .map((j) => VideoJob.fromJson(jsonDecode(jsonEncode(j.toJson()))))
        .toList();
    expect(entries.map((j) => j.state), [
      VideoJobState.queued,
      VideoJobState.paused,
      VideoJobState.cancelled,
    ]);
    expect(entries.map((j) => j.filename), everyElement('Mưa trên phố.mp4'));
    expect(entries.map((j) => j.source.url), everyElement(isEmpty));

    final downloaded = await Future.wait(
      List.generate(
        3,
        (i) => download(
          (_) async => _response(mp4),
          target: Directory('${job.path}/$i'),
        ),
      ),
    );
    expect(downloaded.map((f) => f.path).toSet(), hasLength(3));
  });

  test(
    'downloads independent video and audio files, then remuxes real MP4',
    () async {
      for (final track in ['video', 'audio']) {
        await _ffmpeg([
          '-i',
          '${fixture.path}/clip.mp4',
          track == 'video' ? '-an' : '-vn',
          '-c',
          'copy',
          '${fixture.path}/$track.mp4',
        ]);
      }
      final result = await download(
        (req) async => _response(
          await File('${fixture.path}/${req.url.pathSegments.last}')
              .readAsBytes(),
        ),
        source: VideoCandidate(
          url: _url,
          hasAudio: true,
          video: [VideoPart(Uri.parse('${_base}video.mp4'))],
          audio: [VideoPart(Uri.parse('${_base}audio.mp4'))],
        ),
      );
      expect(await _inspect(result.path), {'video': true, 'audio': true});
    },
  );

  test('downloads and remuxes a real clear HLS VOD playlist and its MPEG-TS segments', () async {
    await _ffmpeg([
      '-i',
      '${fixture.path}/clip.mp4',
      '-c',
      'copy',
      '-f',
      'hls',
      '-hls_time',
      '1',
      '-hls_playlist_type',
      'vod',
      '${fixture.path}/clear.m3u8',
    ]);
    final manifest = await File('${fixture.path}/clear.m3u8').readAsString();
    final variants = await hlsCandidates(
      manifest,
      Uri.parse('${_base}clear.m3u8'),
      (_) async => throw StateError('Unexpected nested playlist'),
    );
    expect(variants.single.video!.length, greaterThan(1));
    final result = await download(
      (req) async => _response(
        await File('${fixture.path}/${req.url.pathSegments.last}')
            .readAsBytes(),
      ),
      source: variants.single,
    );
    expect(await _inspect(result.path), {'video': true, 'audio': true});
  });

  test(
    'downloads a real DASH fMP4 timeline with separate audio and remuxes MP4',
    () async {
      await _ffmpeg([
        '-i',
        '${fixture.path}/clip.mp4',
        '-c',
        'copy',
        '-f',
        'dash',
        '-seg_duration',
        '1',
        '${fixture.path}/clear.mpd',
      ]);
      final manifest = await File('${fixture.path}/clear.mpd').readAsString();
      final source = dashCandidates(
        manifest,
        Uri.parse('${_base}clear.mpd'),
      ).single;
      expect(source.audio, isNotEmpty);
      expect(source.height, 720);
      expect(source.fps, 24);
      final result = await download(
        (req) async => _response(
          await File('${fixture.path}/${req.url.pathSegments.last}')
              .readAsBytes(),
        ),
        source: source,
      );
      expect(await _inspect(result.path), {'video': true, 'audio': true});
    },
  );

  test(
    'rejects encrypted HLS and protected DASH before fetching any segment',
    () {
      final uri = Uri.parse('${_base}manifest');
      expect(
        () => hlsMedia(
          '#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="key"\nvideo.ts\n#EXT-X-ENDLIST',
          uri,
        ),
        throwsA(isA<FacebookVideoException>()),
      );
      expect(
        () => dashCandidates(
          '<MPD><Period><ContentProtection/></Period></MPD>',
          uri,
        ),
        throwsA(isA<FacebookVideoException>()),
      );
    },
  );
}
