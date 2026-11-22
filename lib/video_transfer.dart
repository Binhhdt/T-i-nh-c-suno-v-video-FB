part of 'downloader.dart';

class VideoTransferControl {
  final _stop = Completer<void>();
  bool get stopped => _stop.isCompleted;
  Future<void> get abort => _stop.future;
  void stop() {
    if (!stopped) _stop.complete();
  }

  void check() {
    if (stopped) throw const VideoTransferStopped();
  }
}

class VideoTransferStopped implements Exception {
  const VideoTransferStopped();
}

typedef TransferProgress = void Function(int received, int? total);
typedef InspectVideo = Future<Map<String, dynamic>> Function(String path);
typedef MuxVideo = Future<bool> Function(
  List<String> arguments,
  VideoTransferControl control,
);

extension FacebookVideoTransfer on VideoDownloader {
  Future<File> downloadFacebookVideo({
    required VideoCandidate source,
    required Directory staging,
    required VideoTransferControl control,
    required TransferProgress onProgress,
    required Future<VideoCandidate> Function() refresh,
    required InspectVideo inspect,
    FacebookVideoHttp? transport,
    MuxVideo? mux,
    Duration backoff = const Duration(seconds: 1),
  }) async {
    await staging.create(recursive: true);
    final network = transport ?? FacebookVideoHttp();
    var option = source;
    var needsRefresh = option.url.isEmpty;
    var refreshed = false;
    var attempts = 0;
    try {
      while (true) {
        control.check();
        try {
          if (needsRefresh) {
            option = await refresh();
            needsRefresh = false;
          }
          return await _downloadFacebookOnce(
            option,
            staging,
            control,
            onProgress,
            inspect,
            network,
            mux ?? _executeVideoMux,
          );
        } catch (e) {
          control.check();
          if (e is FacebookVideoException && e.expired && !refreshed) {
            needsRefresh = true;
            refreshed = true;
            continue;
          }
          final retry =
              e is SocketException ||
              e is TimeoutException ||
              e is http.ClientException ||
              e is HttpException ||
              e is FacebookVideoException && e.retryable;
          if (!retry || attempts >= VideoDownloader.maxAttempts) rethrow;
          await Future.any([
            Future<void>.delayed(backoff * (1 << attempts)),
            control.abort,
          ]);
          attempts++;
        }
      }
    } finally {
      if (transport == null) network.close();
    }
  }

  Future<File> _downloadFacebookOnce(
    VideoCandidate option,
    Directory staging,
    VideoTransferControl control,
    TransferProgress onProgress,
    InspectVideo inspect,
    FacebookVideoHttp network,
    MuxVideo mux,
  ) async {
    final videoParts = option.video ?? [VideoPart(Uri.parse(option.url))];
    final audioParts = option.audio ?? const <VideoPart>[];
    final parts = [...videoParts, ...audioParts];
    if (videoParts.isEmpty) {
      throw const FacebookVideoException('Nguồn video rỗng.');
    }
    final expected = parts.every((p) => p.length != null)
        ? parts.fold<int>(0, (n, p) => n + p.length!)
        : null;
    var previous = 0;
    for (var index = 0; index < parts.length; index++) {
      control.check();
      final part = parts[index];
      final file = File('${staging.path}/part-$index');
      final identity = '${part.url.path}|${part.start}|${part.end}';
      final marker = await _readPartState(file);
      int length;
      if (marker?['identity'] == identity &&
          marker?['complete'] == true &&
          await file.exists() &&
          await file.length() == marker?['length']) {
        length = marker!['length'] as int;
      } else {
        length = await _transferPart(
          network,
          part,
          file,
          identity,
          marker,
          control,
          (bytes, total) => onProgress(
            previous + bytes,
            parts.length == 1 ? total : expected,
          ),
        );
      }
      previous += length;
      onProgress(previous, parts.length == 1 ? length : expected);
    }

    control.check();
    final direct = option.kind == VideoSourceKind.mp4 && audioParts.isEmpty;
    final file = File('${staging.path}/part-0');
    if (direct) {
      try {
        await _verifyVideoFile(
          file,
          inspect,
          requireAudio: option.hasAudio == true,
        );
      } on FacebookVideoException {
        // The partial is retained for diagnosis, but may be replaced on manual retry.
        await File('${file.path}.json').delete();
        rethrow;
      }
      return file;
    }

    final videoPath = await _joinParts(
      staging,
      'video',
      0,
      videoParts.length,
      control,
    );
    final audioPath = audioParts.isEmpty
        ? null
        : await _joinParts(
            staging,
            'audio',
            videoParts.length,
            parts.length,
            control,
          );
    final fileOut = File('${staging.path}/merged.mp4');
    final videoInfo = await inspect(videoPath);
    final audioInfo = audioPath == null ? null : await inspect(audioPath);
    if (videoInfo['encrypted'] == true || audioInfo?['encrypted'] == true) {
      throw const FacebookVideoException('Video được bảo vệ bằng DRM.');
    }
    control.check();
    List<String> input(String path) => [
      '-protocol_whitelist',
      'file',
      '-format_whitelist',
      'mov,mp4,m4a,3gp,3g2,mj2,mpegts,aac,mp3',
      '-i',
      path,
    ];
    final merged = await mux([
      '-nostdin',
      '-loglevel',
      'error',
      '-y',
      ...input(videoPath),
      if (audioPath != null) ...input(audioPath),
      '-map',
      '0:v:0',
      '-map',
      audioPath == null ? '0:a:0?' : '1:a:0',
      '-c',
      'copy',
      '-movflags',
      '+faststart',
      fileOut.path,
    ], control);
    control.check();
    if (!merged) {
      throw const FacebookVideoException(
        'Không ghép được các luồng thành MP4.',
      );
    }
    await _verifyVideoFile(
      fileOut,
      inspect,
      requireAudio: option.hasAudio == true,
    );
    return fileOut;
  }

  Future<bool> _executeVideoMux(
    List<String> arguments,
    VideoTransferControl control,
  ) async {
    final completed = Completer<bool>();
    final session = await FFmpegKit.executeWithArgumentsAsync(arguments, (
      session,
    ) async {
      try {
        completed.complete(ReturnCode.isSuccess(await session.getReturnCode()));
      } catch (e, stack) {
        completed.completeError(e, stack);
      }
    });
    final result = await Future.any([
      completed.future,
      control.abort.then((_) => false),
    ]);
    if (control.stopped) {
      await FFmpegKit.cancel(session.getSessionId());
      try {
        await completed.future;
      } catch (_) {}
      control.check();
    }
    return result;
  }

  Future<String> _joinParts(
    Directory staging,
    String name,
    int first,
    int end,
    VideoTransferControl control,
  ) async {
    if (end - first == 1) return '${staging.path}/part-$first';
    final file = File('${staging.path}/$name.bin');
    final sink = await file.open(mode: FileMode.write);
    try {
      for (var index = first; index < end; index++) {
        await for (final bytes in File(
          '${staging.path}/part-$index',
        ).openRead()) {
          control.check();
          await sink.writeFrom(bytes);
        }
      }
    } finally {
      await sink.close();
    }
    return file.path;
  }

  Future<Map<String, dynamic>?> _readPartState(File file) async {
    try {
      final value = jsonDecode(await File('${file.path}.json').readAsString());
      return value is Map<String, dynamic> ? value : null;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<void> _writePartState(File file, Map<String, Object?> value) async {
    final pending = File('${file.path}.json.tmp');
    await pending.writeAsString(jsonEncode(value), flush: true);
    await pending.rename('${file.path}.json');
  }

  Future<int> _transferPart(
    FacebookVideoHttp network,
    VideoPart part,
    File file,
    String identity,
    Map<String, dynamic>? marker,
    VideoTransferControl control,
    TransferProgress onProgress,
  ) async {
    final exists = await file.exists();
    final validator = marker?['identity'] == identity
        ? (marker?['etag'] as String?)
        : null;
    final partialLength = exists && validator != null ? await file.length() : 0;
    var offset = partialLength;
    // A crash can happen after all bytes reached disk and before completion was journaled.
    if (offset > 0 && offset == marker?['length']) {
      await _writePartState(file, {...marker!, 'complete': true});
      return offset;
    }
    if (part.length != null && offset >= part.length!) offset = 0;
    final requestedStart = (part.start ?? 0) + offset;
    final wantsRange = part.start != null || offset > 0;
    final result = await network.send(
      part.url,
      abort: control.abort,
      headers: {
        if (wantsRange) 'Range': 'bytes=$requestedStart-${part.end ?? ''}',
        if (offset > 0) 'If-Range': validator!,
      },
    );
    final response = result.response;
    Future<Never> reject(String reason, {bool retryable = false}) async {
      await FacebookVideoHttp.discard(response);
      throw FacebookVideoException(reason, retryable: retryable);
    }

    if (response.statusCode == 416 && offset > 0) {
      await FacebookVideoHttp.discard(response);
      return _transferPart(
        network,
        part,
        file,
        identity,
        null,
        control,
        onProgress,
      );
    }
    if (response.statusCode != 200 && response.statusCode != 206) {
      await FacebookVideoHttp.discard(response);
      FacebookVideoHttp.checkStatus(response.statusCode);
    }
    final encoding = response.headers['content-encoding'];
    if (encoding != null && encoding.toLowerCase() != 'identity' ||
        response.headers['content-type']?.toLowerCase().startsWith(
              'text/html',
            ) ==
            true) {
      await reject('Máy chủ trả nội dung khác với luồng video.');
    }
    final etag = response.headers['etag'];
    final strong = etag != null && etag.startsWith('"') && etag.endsWith('"')
        ? etag
        : null;
    int? total;
    int? expectedBody = response.contentLength;
    if (response.statusCode == 206) {
      final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$')
          .firstMatch(response.headers['content-range'] ?? '');
      final start = int.tryParse(range?[1] ?? '');
      final end = int.tryParse(range?[2] ?? '');
      final resourceSize = int.tryParse(range?[3] ?? '');
      if (!wantsRange ||
          start != requestedStart ||
          end == null ||
          resourceSize == null ||
          end < requestedStart ||
          resourceSize <= end ||
          end != (part.end ?? resourceSize - 1) ||
          offset > 0 && strong != validator) {
        if (offset > 0) {
          await FacebookVideoHttp.discard(response);
          return _transferPart(
            network,
            part,
            file,
            identity,
            null,
            control,
            onProgress,
          );
        }
        await reject('Phạm vi tải tiếp không khớp với file đã lưu.');
      }
      total = part.length ?? resourceSize;
      final rangeBody = end - requestedStart + 1;
      if (expectedBody != null && expectedBody != rangeBody) {
        await reject('Dung lượng tải tiếp không khớp.');
      }
      expectedBody = rangeBody;
    } else {
      if (part.start != null) {
        await reject(
          'Máy chủ không cung cấp phạm vi byte mà manifest yêu cầu.',
        );
      }
      offset = 0;
      total = expectedBody;
    }

    RandomAccessFile? handle;
    var received = 0;
    var subscribed = false;
    try {
      control.check();
      handle = await file.open(
        mode: offset == 0 ? FileMode.write : FileMode.append,
      );
      await _writePartState(file, {
        'identity': identity,
        'etag': strong,
        'length': total,
        'complete': false,
      });
      onProgress(offset, total);
      subscribed = true;
      await for (final chunk in response.stream.timeout(idleTimeout)) {
        control.check();
        if (expectedBody != null && received + chunk.length > expectedBody) {
          await handle.truncate(offset);
          throw const FacebookVideoException(
            'Phản hồi dài hơn Content-Length.',
          );
        }
        await handle.writeFrom(chunk);
        received += chunk.length;
        onProgress(offset + received, total);
      }
      control.check();
      if (received == 0 || expectedBody != null && received != expectedBody) {
        throw const FacebookVideoException(
          'Luồng video bị ngắt trước khi đủ dữ liệu.',
          retryable: true,
        );
      }
      await handle.flush();
      await _writePartState(file, {
        'identity': identity,
        'etag': strong,
        'length': received + offset,
        'complete': true,
      });
      return received + offset;
    } catch (_) {
      if (!subscribed) await FacebookVideoHttp.discard(response);
      rethrow;
    } finally {
      await handle?.close();
    }
  }

  Future<void> _verifyVideoFile(
    File file,
    InspectVideo inspect, {
    required bool requireAudio,
  }) async {
    final reader = await file.open();
    try {
      final length = await reader.length();
      var offset = 0;
      final boxes = <String>{};
      while (offset + 8 <= length) {
        if (boxes.length > 128) break;
        await reader.setPosition(offset);
        final sizeBytes = await reader.read(4);
        final type = String.fromCharCodes(await reader.read(4));
        var size = sizeBytes.fold<int>(0, (n, byte) => (n << 8) | byte);
        var header = 8;
        if (size == 1 && offset + 16 <= length) {
          size = (await reader.read(8))
              .fold<int>(0, (n, byte) => (n << 8) | byte);
          header = 16;
        } else if (size == 0) {
          size = length - offset;
        }
        if (size < header || size > length - offset) break;
        if (type != 'mdat' || size > header) boxes.add(type);
        offset += size;
      }
      if (offset != length || !boxes.containsAll({'ftyp', 'moov', 'mdat'})) {
        throw const FacebookVideoException(
          'File tải về thiếu dữ liệu hoặc sai định dạng MP4.',
        );
      }
    } finally {
      await reader.close();
    }
    final media = await inspect(file.path);
    if (media['encrypted'] == true) {
      throw const FacebookVideoException('Video được bảo vệ bằng DRM.');
    }
    if (media['video'] != true || requireAudio && media['audio'] != true) {
      throw const FacebookVideoException(
        'File MP4 thiếu luồng video hoặc âm thanh đã chọn.',
      );
    }
  }
}
