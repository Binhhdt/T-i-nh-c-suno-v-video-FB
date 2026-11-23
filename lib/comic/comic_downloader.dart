import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'comic_log.dart';
import 'comic_models.dart';
import 'image_validator.dart';

/// Engine tải ảnh trang truyện:
/// - Tên file theo thứ tự: 001.jpg, 002.webp, ... (đuôi theo định dạng
///   thật của ảnh).
/// - Gửi Referer = trang chapter, User-Agent + cookie của trình duyệt đã
///   mở trang (giống hệt khi trình duyệt tự tải ảnh).
/// - Retry khi lỗi mạng / 5xx / 408 / 429 (chờ 1s, 2s, 4s...).
/// - Kiểm tra mã HTTP, Content-Type, Content-Length, kích thước, định
///   dạng thật và file cụt; ghi ra file tạm `.part` rồi mới đổi tên.
/// - File đã có và hợp lệ -> bỏ qua, không tải lại.
/// - Mọi lỗi đều ghi log kèm URL + lý do.
class ComicDownloader {
  ComicDownloader({
    http.Client? client,
    this.maxRetries = 3,
    this.concurrency = 3,
    this.headerTimeout = const Duration(seconds: 30),
    this.idleTimeout = const Duration(seconds: 30),
    this.retryBaseDelay = const Duration(seconds: 1),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final int maxRetries;
  final int concurrency;
  final Duration headerTimeout;
  final Duration idleTimeout;
  final Duration retryBaseDelay;

  static const _exts = ['jpg', 'png', 'webp', 'gif', 'avif', 'bmp'];

  /// Tải mọi ảnh vào [dir].
  /// [cookiesByHost]: header Cookie theo host ảnh (lấy từ WebView).
  /// [onProgress]: gọi sau mỗi trang xong (done = số trang đã xử lý).
  /// [isCancelled]: trả true để dừng (trang đang tải dở được bỏ).
  Future<DownloadReport> downloadAll({
    required List<ChapterImage> images,
    required Directory dir,
    required String referer,
    required String userAgent,
    required ComicLog log,
    Map<String, String> cookiesByHost = const {},
    void Function(int done, int total, PageResult last)? onProgress,
    bool Function()? isCancelled,
  }) async {
    await dir.create(recursive: true);
    final results = List<PageResult?>.filled(images.length, null);
    var next = 0;
    var done = 0;

    Future<void> worker() async {
      while (true) {
        if (isCancelled?.call() ?? false) return;
        final i = next++;
        if (i >= images.length) return;
        final img = images[i];
        final r = await _downloadOne(
          img,
          dir,
          referer: referer,
          userAgent: userAgent,
          cookie: cookiesByHost[Uri.tryParse(img.url)?.host ?? ''],
          log: log,
          isCancelled: isCancelled,
        );
        results[i] = r;
        done++;
        onProgress?.call(done, images.length, r);
      }
    }

    final n = concurrency < 1 ? 1 : concurrency;
    await Future.wait([for (var k = 0; k < n; k++) worker()]);

    final list = <PageResult>[];
    for (var i = 0; i < images.length; i++) {
      list.add(results[i] ??
          PageResult(
            image: images[i],
            state: PageState.failed,
            reason: 'đã dừng trước khi tải',
          ));
    }
    final report = DownloadReport(list);
    log.info('Xong: tải mới ${report.ok}, bỏ qua (đã có) ${report.skipped}, '
        'lỗi ${report.failed} / ${images.length} trang');
    return report;
  }

  /// File đã có cho trang này (001.jpg / 001.webp / ...), nếu có.
  Future<File?> _existing(Directory dir, String base) async {
    for (final e in _exts) {
      final f = File('${dir.path}/$base.$e');
      if (await f.exists()) return f;
    }
    return null;
  }

  Future<PageResult> _downloadOne(
    ChapterImage img,
    Directory dir, {
    required String referer,
    required String userAgent,
    required String? cookie,
    required ComicLog log,
    bool Function()? isCancelled,
  }) async {
    final base = img.baseName;

    // 1. Đã có file hợp lệ -> bỏ qua.
    final old = await _existing(dir, base);
    if (old != null) {
      final v = await ImageValidator.validateFile(old);
      if (v.error == null) {
        return PageResult(
          image: img,
          state: PageState.skipped,
          filePath: old.path,
          reason: 'đã có file hợp lệ',
        );
      }
      log.warn('Trang $base: file cũ không hợp lệ (${v.error}) -> tải lại');
      try {
        await old.delete();
      } catch (_) {}
    }

    // 2. Tải, retry khi lỗi tạm thời.
    String reason = 'không rõ';
    for (var attempt = 1; attempt <= maxRetries; attempt++) {
      if (isCancelled?.call() ?? false) {
        return PageResult(
          image: img,
          state: PageState.failed,
          reason: 'đã dừng',
          attempts: attempt - 1,
        );
      }
      final part = File('${dir.path}/$base.part');
      try {
        final ext = await _fetchTo(
          img.url,
          part,
          referer: referer,
          userAgent: userAgent,
          cookie: cookie,
        );
        final target = File('${dir.path}/$base.$ext');
        if (await target.exists()) await target.delete();
        await part.rename(target.path);
        if (attempt > 1) log.info('Trang $base: thành công ở lần thử $attempt');
        return PageResult(
          image: img,
          state: PageState.done,
          filePath: target.path,
          attempts: attempt,
        );
      } on _PermanentError catch (e) {
        reason = e.message;
        await _safeDelete(part);
        log.error('Trang $base: $reason — ${img.url}');
        return PageResult(
          image: img,
          state: PageState.failed,
          reason: reason,
          attempts: attempt,
        );
      } catch (e) {
        reason = e is _RetryableError
            ? e.message
            : e is TimeoutException
                ? 'hết thời gian chờ (mạng chậm hoặc máy chủ không trả lời)'
                : e is SocketException
                    ? 'lỗi mạng: ${e.message}'
                    : e is HttpException
                        ? 'lỗi HTTP: ${e.message}'
                        : e.toString();
        await _safeDelete(part);
        if (attempt < maxRetries) {
          final wait = retryBaseDelay * (1 << (attempt - 1));
          log.warn('Trang $base: lần $attempt lỗi ($reason) -> thử lại sau '
              '${wait.inMilliseconds} ms');
          await Future.delayed(wait);
        }
      }
    }
    log.error('Trang $base: bỏ cuộc sau $maxRetries lần — $reason — ${img.url}');
    return PageResult(
      image: img,
      state: PageState.failed,
      reason: reason,
      attempts: maxRetries,
    );
  }

  /// Tải 1 lần vào [part], kiểm tra đủ thứ, trả về đuôi file thật.
  Future<String> _fetchTo(
    String url,
    File part, {
    required String referer,
    required String userAgent,
    required String? cookie,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      throw _PermanentError('link ảnh không hợp lệ');
    }
    final req = http.Request('GET', uri);
    req.headers['Accept'] =
        'image/avif,image/webp,image/apng,image/*,*/*;q=0.8';
    if (userAgent.isNotEmpty) req.headers['User-Agent'] = userAgent;
    if (referer.isNotEmpty) req.headers['Referer'] = referer;
    if (cookie != null && cookie.isNotEmpty) req.headers['Cookie'] = cookie;

    final resp = await _client.send(req).timeout(headerTimeout);
    final code = resp.statusCode;
    if (code != 200) {
      // Đọc bỏ body để giải phóng kết nối.
      unawaited(resp.stream.drain<void>().catchError((_) {}));
      if (code == 408 || code == 429 || code >= 500) {
        throw _RetryableError('máy chủ trả mã $code');
      }
      if (code == 401 || code == 403) {
        throw _PermanentError('bị từ chối (mã $code) — trang không cho tải '
            'ảnh này hoặc cần đăng nhập trong trình duyệt của tab');
      }
      if (code == 404 || code == 410) {
        throw _PermanentError('không tìm thấy ảnh (mã $code)');
      }
      throw _PermanentError('máy chủ trả mã $code');
    }

    final declared = resp.contentLength;
    if (declared != null && declared > ImageValidator.maxBytes) {
      unawaited(resp.stream.drain<void>().catchError((_) {}));
      throw _PermanentError('file quá lớn ($declared byte)');
    }

    final sink = part.openWrite();
    final head = <int>[];
    var received = 0;
    try {
      await for (final chunk in resp.stream.timeout(idleTimeout)) {
        if (head.length < 32) {
          head.addAll(chunk.take(32 - head.length));
          // Kiểm tra Content-Type ngay khi có vài byte đầu: trả HTML ->
          // dừng sớm, không tải hết.
          if (head.length >= 12 || received + chunk.length >= 12) {
            final ctErr = ImageValidator.checkContentType(
              resp.headers['content-type'],
              head,
            );
            if (ctErr != null) throw _PermanentError(ctErr);
          }
        }
        received += chunk.length;
        if (received > ImageValidator.maxBytes) {
          throw _PermanentError('file quá lớn (> ${ImageValidator.maxBytes} byte)');
        }
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
    if (head.length < 12) {
      final ctErr = ImageValidator.checkContentType(
        resp.headers['content-type'],
        head,
      );
      if (ctErr != null) throw _PermanentError(ctErr);
    }

    final v = await ImageValidator.validateFile(
      part,
      expectedLength: declared,
    );
    if (v.error != null) {
      // Thiếu byte / cụt: thường do mạng -> thử lại được.
      if (v.error!.contains('thiếu') || v.error!.contains('cụt')) {
        throw _RetryableError(v.error!);
      }
      throw _PermanentError(v.error!);
    }
    return v.ext!;
  }

  Future<void> _safeDelete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

class _RetryableError implements Exception {
  _RetryableError(this.message);
  final String message;
  @override
  String toString() => message;
}

class _PermanentError implements Exception {
  _PermanentError(this.message);
  final String message;
  @override
  String toString() => message;
}
