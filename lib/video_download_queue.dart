import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'downloader.dart';
import 'facebook_video_http.dart';
import 'suno_filename.dart';
import 'video_extractor.dart';

enum VideoJobState {
  queued,
  downloading,
  saving,
  paused,
  complete,
  failed,
  cancelled,
}

class VideoJob {
  VideoJob({
    required this.id,
    required this.page,
    required this.title,
    required this.source,
    this.state = VideoJobState.queued,
    this.destination,
    this.saved,
    this.warning,
    this.error,
    this.received = 0,
    this.total,
  });

  final String id;
  final String page;
  final String title;
  final VideoCandidate source;
  final String? destination;
  VideoJobState state;
  String? saved;
  String? warning;
  String? error;
  int received;
  int? total;
  double speed = 0;
  final stopwatch = Stopwatch();

  bool get active =>
      state == VideoJobState.downloading ||
      state == VideoJobState.queued ||
      state == VideoJobState.saving;
  String get filename {
    final name = StringBuffer();
    var bytes = 0;
    for (final rune in sanitizeSongTitle(title).runes) {
      final character = String.fromCharCode(rune);
      final length = utf8.encode(character).length;
      if (bytes + length > 200) break;
      name.write(character);
      bytes += length;
    }
    return name.isEmpty ? 'fb_video_$id.mp4' : '$name.mp4';
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'page': page,
    'title': title,
    'source': source.toJson(),
    'state': state.name,
    'destination': destination,
    'saved': saved,
    'warning': warning,
    'error': error,
    'received': received,
    'total': total,
  };

  factory VideoJob.fromJson(Map<String, dynamic> json) {
    final state = VideoJobState.values.byName(json['state'] as String);
    return VideoJob(
      id: json['id'] as String,
      page: json['page'] as String,
      title: json['title'] as String,
      source: VideoCandidate.fromJson(json['source'] as Map<String, dynamic>),
      state: switch (state) {
        VideoJobState.downloading ||
        VideoJobState.saving => VideoJobState.queued,
        _ => state,
      },
      destination: json['destination'] as String?,
      saved: json['saved'] as String?,
      warning: json['warning'] as String?,
      error: json['error'] as String?,
      received: json['received'] as int? ?? 0,
      total: json['total'] as int?,
    );
  }
}

class VideoDownloadQueue extends ChangeNotifier {
  VideoDownloadQueue._() {
    platform.setMethodCallHandler((call) async {
      if (call.method == 'sharedLink') {
        _shared.add(null);
      } else if (call.method == 'serviceTimeout') {
        await _pauseForTimeout();
      }
    });
  }

  static final instance = VideoDownloadQueue._();
  static const platform = MethodChannel('com.binh.fb_video_downloader/video');
  final _shared = StreamController<void>.broadcast();
  Stream<void> get sharedLinks => _shared.stream;
  final _jobs = <VideoJob>[];
  List<VideoJob> get jobs => List.unmodifiable(_jobs.reversed);
  final _running = <String, VideoTransferControl>{};
  final _downloader = VideoDownloader();
  final _extractor = FacebookVideoExtractor();
  var _writes = Future<void>.value();
  Future<void>? _loading;
  late Directory _root;
  bool _ready = false;
  bool _starting = false;
  bool _stopping = false;
  bool _foreground = false;
  bool _visible = false;
  int _parallel = 2;
  int get parallel => _parallel;
  String? startupError;

  Future<void> initialize() => _loading ??= _load();
  Future<void> _load() async {
    try {
      _root = Directory(
        '${(await getApplicationSupportDirectory()).path}/facebook-video',
      );
      await _root.create(recursive: true);
      final file = File('${_root.path}/history.json');
      if (await file.exists()) {
        final data =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        _parallel = (data['parallel'] as int? ?? 2).clamp(1, 3);
        _jobs.addAll(
          (data['jobs'] as List).map(
            (e) => VideoJob.fromJson(e as Map<String, dynamic>),
          ),
        );
      }
      for (final job in _jobs.where(
        (job) =>
            job.state == VideoJobState.cancelled ||
            job.state == VideoJobState.complete,
      )) {
        unawaited(_cleanup(job));
      }
      _ready = true;
      notifyListeners();
      await _pump();
    } catch (_) {
      startupError = 'Không mở được hàng đợi video trên thiết bị.';
      notifyListeners();
    }
  }

  Future<void> setVisible(bool visible) async {
    _visible = visible;
    if (visible) await _pump();
  }

  Future<void> setParallel(int value) async {
    await initialize();
    if (!_ready) return;
    final old = _parallel;
    _parallel = value.clamp(1, 3);
    try {
      await _persist();
    } catch (_) {
      _parallel = old;
      rethrow;
    }
    notifyListeners();
    await _pump();
  }

  Future<void> add({
    required String page,
    required String title,
    required VideoCandidate source,
    String? destination,
  }) async {
    await initialize();
    if (!_ready) {
      throw const FacebookVideoException('Không mở được hàng đợi video.');
    }
    final id =
        '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
    final job = VideoJob(
      id: id,
      page: _extractor.normalizeUrl(page),
      title: title,
      source: source,
      destination: destination,
    );
    _jobs.add(job);
    try {
      await _persist();
    } catch (_) {
      _jobs.remove(job);
      rethrow;
    }
    notifyListeners();
    await _pump();
  }

  Future<void> pause(VideoJob job) => _change(job, VideoJobState.paused, {
    VideoJobState.queued,
    VideoJobState.downloading,
  });
  Future<void> cancel(VideoJob job) => _change(job, VideoJobState.cancelled, {
    VideoJobState.queued,
    VideoJobState.downloading,
    VideoJobState.paused,
    VideoJobState.failed,
  });
  Future<void> resume(VideoJob job) => _change(job, VideoJobState.queued, {
    VideoJobState.paused,
    VideoJobState.failed,
  });

  Future<void> _change(
    VideoJob job,
    VideoJobState target,
    Set<VideoJobState> allowed,
  ) async {
    if (!allowed.contains(job.state)) return;
    job.state = target;
    job.error = null;
    _running[job.id]?.stop();
    await _persist();
    if (target == VideoJobState.cancelled && !_running.containsKey(job.id)) {
      await _cleanup(job);
    }
    notifyListeners();
    await _pump();
  }

  Future<void> removeHistory(VideoJob job, {required bool deleteFile}) async {
    if (job.active || _running.containsKey(job.id)) return;
    if (deleteFile && job.saved != null) {
      await platform.invokeMethod<void>('delete', job.saved);
    }
    final index = _jobs.indexOf(job);
    if (index < 0) return;
    _jobs.removeAt(index);
    try {
      await _persist();
    } catch (_) {
      _jobs.insert(index, job);
      rethrow;
    }
    await _cleanup(job);
    notifyListeners();
  }

  Future<void> _persist() {
    final snapshot = jsonEncode({
      'parallel': _parallel,
      'jobs': _jobs.map((job) => job.toJson()).toList(),
    });
    final next = _writes.then((_) async {
      final file = File('${_root.path}/history.tmp');
      await file.writeAsString(snapshot, flush: true);
      await file.rename('${_root.path}/history.json');
    });
    _writes = next.catchError((Object _) {});
    return next;
  }

  Directory _work(VideoJob job) => Directory('${_root.path}/${job.id}');
  Future<void> _cleanup(VideoJob job) async {
    try {
      final local = _work(job);
      if (await local.exists()) await local.delete(recursive: true);
      if (job.state == VideoJobState.complete ||
          job.state == VideoJobState.cancelled) {
        await platform.invokeMethod<void>('forgetExport', job.id);
      }
    } catch (_) {}
  }

  Future<void> _pauseForTimeout() async {
    _foreground = false;
    for (final job in _jobs.where(
      (job) =>
          job.state == VideoJobState.downloading ||
          job.state == VideoJobState.queued,
    )) {
      job.state = VideoJobState.paused;
      job.error = 'Android đã giới hạn thời gian tải nền.';
      _running[job.id]?.stop();
    }
    await _persist();
    notifyListeners();
  }

  Future<void> _pump() async {
    if (!_ready || _starting || _stopping) return;
    final waiting = _jobs
        .where(
          (j) => j.state == VideoJobState.queued && !_running.containsKey(j.id),
        )
        .toList();
    if (waiting.isEmpty && _running.isEmpty && _foreground) {
      _stopping = true;
      try {
        await platform.invokeMethod<void>('stop');
      } on PlatformException {
        // The activity may have been closed while the worker was draining.
      } finally {
        _stopping = false;
        _foreground = false;
      }
      if (_jobs.any((j) => j.state == VideoJobState.queued)) await _pump();
      return;
    }
    if (waiting.isEmpty || _running.length >= _parallel) return;
    if (!_foreground) {
      if (!_visible) return;
      _starting = true;
      try {
        await platform.invokeMethod<void>('start');
        _foreground = true;
      } on PlatformException {
        for (final job in waiting.where(
          (j) => j.state == VideoJobState.queued,
        )) {
          job.state = VideoJobState.paused;
          job.error = 'Android không cho bắt đầu tải nền. Hãy mở ứng dụng rồi tiếp tục.';
        }
        await _persist();
        notifyListeners();
        return;
      } finally {
        _starting = false;
      }
      await _pump();
      return;
    }
    for (final job in waiting.take(_parallel - _running.length)) {
      final control = VideoTransferControl();
      _running[job.id] = control;
      job.state = VideoJobState.downloading;
      unawaited(_run(job, control));
    }
    notifyListeners();
    _notification();
  }

  Future<VideoCandidate> _refresh(
    VideoJob job,
    VideoTransferControl control,
  ) async {
    final cookie = await platform.invokeMethod<String>('cookie');
    final available = await _extractor.extract(
      job.page,
      cookieHeader: cookie,
      abort: control.abort,
    );
    final matches = available.candidates
        .where(
          (option) =>
              job.source.kind == option.kind &&
              job.source.variant == option.variant &&
              (job.source.width == null || job.source.width == option.width) &&
              (job.source.height == null ||
                  job.source.height == option.height) &&
              (job.source.hasAudio != true || option.hasAudio == true),
        )
        .toList();
    if (matches.length == 1) return matches.single;
    throw const FacebookVideoException(
      'Phiên truy cập hoặc bản chất lượng này không còn khả dụng. Hãy lấy lại video.',
    );
  }

  Future<void> _run(VideoJob job, VideoTransferControl control) async {
    var sampleAt = 0;
    var sampleBytes = 0;
    job.stopwatch.reset();
    job.stopwatch.start();
    try {
      await _persist();
      final recovered = await platform.invokeMapMethod<String, dynamic>(
        'recoverExport',
        job.id,
      );
      control.check();
      if (recovered != null) {
        job.saved = recovered['uri'] as String;
        job.warning = recovered['warning'] as String?;
      } else {
        final output = await _downloader.downloadFacebookVideo(
          source: job.source,
          staging: _work(job),
          control: control,
          refresh: () => _refresh(job, control),
          inspect: (path) async =>
              await platform.invokeMapMethod<String, dynamic>(
                'inspect',
                path,
              ) ??
              {},
          onProgress: (bytes, total) {
            job.received = bytes;
            job.total = total;
            final now = job.stopwatch.elapsedMilliseconds;
            if (now - sampleAt < 350) return;
            job.speed = max(0, (bytes - sampleBytes) * 1000 / (now - sampleAt));
            sampleAt = now;
            sampleBytes = bytes;
            notifyListeners();
            _notification();
          },
        );
        control.check();
        job.state = VideoJobState.saving;
        notifyListeners();
        await _persist();
        final result = await platform.invokeMapMethod<String, dynamic>(
          'export',
          {
            'source': output.path,
            'name': job.filename,
            'id': job.id,
            'destination': job.destination,
          },
        );
        job.saved = result!['uri'] as String;
        job.warning = result['warning'] as String?;
      }
      job.state = VideoJobState.complete;
      job.error = null;
    } on VideoTransferStopped {
      // Pause and cancel already record the user's chosen state.
    } on FacebookVideoException catch (e) {
      if (!control.stopped) {
        job.state = VideoJobState.failed;
        job.error = e.message;
      }
    } on FileSystemException catch (e) {
      if (!control.stopped) {
        job.state = VideoJobState.failed;
        job.error = e.osError?.errorCode == 28
            ? 'Không đủ dung lượng lưu trữ. Hãy giải phóng chỗ trống rồi tiếp tục.'
            : 'Không ghi được dữ liệu video trên thiết bị.';
      }
    } on PlatformException catch (e) {
      if (!control.stopped) {
        job.state = VideoJobState.failed;
        job.error = e.message ?? 'Android không xử lý được video.';
      }
    } catch (_) {
      if (!control.stopped) {
        job.state = VideoJobState.failed;
        job.error = 'Tải video bị gián đoạn. Kiểm tra kết nối và thử tiếp tục.';
      }
    } finally {
      job.stopwatch.stop();
      job.speed = 0;
      try {
        await _persist();
        if (job.state == VideoJobState.complete ||
            job.state == VideoJobState.cancelled) {
          await _cleanup(job);
        }
      } catch (_) {
        job.error = 'Không ghi được trạng thái tải xuống trên thiết bị.';
      }
      _running.remove(job.id);
      notifyListeners();
      _notification();
      unawaited(_pump());
    }
  }

  int _lastNotification = 0;
  void _notification() {
    if (!_foreground) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastNotification < 700) return;
    _lastNotification = now;
    final active = _jobs.where((job) => job.active).toList();
    final known =
        active.isNotEmpty && active.every((job) => (job.total ?? 0) > 0);
    final total = active.fold<int>(0, (sum, job) => sum + (job.total ?? 0));
    final bytes = active.fold<int>(0, (sum, job) => sum + job.received);
    unawaited(
      platform
          .invokeMethod<void>('progress', {
            'count': active.length,
            'percent': known
                ? (100 * bytes / total).round().clamp(0, 99)
                : null,
          })
          .catchError((Object _) {}),
    );
  }
}
