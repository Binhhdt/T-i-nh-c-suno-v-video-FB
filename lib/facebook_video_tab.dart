import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'facebook_video_http.dart';
import 'neon_theme.dart';
import 'save_folder.dart';
import 'session.dart';
import 'video_download_queue.dart';
import 'video_extractor.dart';

class FacebookVideoTab extends StatefulWidget {
  const FacebookVideoTab({super.key});

  @override
  State<FacebookVideoTab> createState() => _FacebookVideoTabState();
}

class _FacebookVideoTabState extends State<FacebookVideoTab>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  final _queue = VideoDownloadQueue.instance;
  final _extractor = FacebookVideoExtractor();
  final _link = TextEditingController();
  late final StreamSubscription<void> _shares;
  VideoInfo? _video;
  VideoCandidate? _selected;
  String? _page;
  Future<Uint8List?>? _thumbnail;
  String? _destination;
  String? _folderLabel;
  String? _message;
  bool _fetching = false;
  bool _adding = false;
  bool _loggedIn = false;
  String _filter = 'active';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _shares = _queue.sharedLinks.listen((_) => _receiveLink());
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  Future<void> _initialize() async {
    if (!mounted) return;
    unawaited(_queue.setVisible(true));
    await _queue.initialize();
    await _receiveLink();
    await _loadFolder();
    final cookie = await _cookie();
    if (mounted) {
      setState(
        () => _loggedIn =
            cookie != null &&
            cookie.contains('c_user=') &&
            cookie.contains('xs='),
      );
    }
  }

  Future<String?> _cookie() =>
      VideoDownloadQueue.platform.invokeMethod<String>('cookie');

  Future<void> _receiveLink() async {
    final shared = await VideoDownloadQueue.platform.invokeMethod<String>(
      'takeShare',
    );
    if (shared == null || !mounted) return;
    try {
      final normalized = _extractor.normalizeUrl(shared);
      DefaultTabController.of(context).animateTo(0);
      _link.text = normalized;
      setState(() {
        _video = null;
        _selected = null;
        _message = null;
      });
    } on FacebookVideoException catch (e) {
      _show(e.message);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(_queue.setVisible(state == AppLifecycleState.resumed));
    if (state == AppLifecycleState.resumed) unawaited(_loadFolder());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_shares.cancel());
    _link.dispose();
    _extractor.close();
    super.dispose();
  }

  Future<void> _fetch() async {
    if (_fetching) return;
    FocusScope.of(context).unfocus();
    final navigator = Navigator.of(context);
    setState(() {
      _fetching = true;
      _video = null;
      _selected = null;
      _message = null;
    });
    try {
      final page = _extractor.normalizeUrl(_link.text);
      VideoInfo? info;
      try {
        info = await _extractor.extract(page, cookieHeader: await _cookie());
      } catch (firstError) {
        if (!mounted) return;
        info = await navigator.push<VideoInfo>(
          MaterialPageRoute(builder: (_) => _VideoExtractPage(url: page)),
        );
        if (info == null) {
          _show(
            firstError is FacebookVideoException
                ? firstError.message
                : 'Không đọc được video Facebook.',
          );
        }
      }
      if (!mounted || info == null) return;
      final result = info;
      setState(() {
        _page = page;
        _video = result;
        _selected = result.best;
        _thumbnail = _loadThumbnail(result.thumbnailUrl);
      });
    } on FacebookVideoException catch (e) {
      _show(e.message);
    } catch (_) {
      _show('Không lấy được video. Kiểm tra kết nối và thử lại.');
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  Future<Uint8List?> _loadThumbnail(String? url) async {
    if (url == null) return null;
    final network = FacebookVideoHttp();
    try {
      return (await network.read(Uri.parse(url), limit: 4 * 1024 * 1024)).bytes;
    } catch (_) {
      return null;
    } finally {
      network.close();
    }
  }

  Future<void> _login() async {
    final header = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const FacebookLoginPage()),
    );
    if (mounted && header != null) setState(() => _loggedIn = true);
  }

  Future<void> _logout() async {
    try {
      await WebViewCookieManager().clearCookies();
      if (mounted) setState(() => _loggedIn = false);
    } catch (_) {
      _show('Không xóa được phiên đăng nhập Facebook.');
    }
  }

  static const _tree = 'facebook_video_save_tree';
  static const _label = 'facebook_video_save_label';
  static const _legacy = 'facebook_video_save_legacy';

  Future<void> _loadFolder() async {
    final prefs = await SharedPreferences.getInstance();
    final legacy = await SaveFolder.load();
    final useTree =
        prefs.getString(_tree) != null &&
        prefs.getString(_legacy) == (legacy ?? '');
    if (!mounted) return;
    setState(() {
      _destination = useTree ? prefs.getString(_tree) : legacy;
      _folderLabel = useTree ? prefs.getString(_label) : legacy;
    });
  }

  Future<void> _pickFolder() => _act(() async {
    final picked = await VideoDownloadQueue.platform
        .invokeMapMethod<String, String>('pickFolder');
    if (picked == null) return;
    final prefs = await SharedPreferences.getInstance();
    final legacy = await SaveFolder.load();
    await prefs.setString(_label, picked['label']!);
    await prefs.setString(_legacy, legacy ?? '');
    await prefs.setString(_tree, picked['uri']!);
    await _loadFolder();
  });

  Future<void> _resetFolder() => _act(() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tree);
    await SaveFolder.clear();
    await _loadFolder();
  });

  Future<void> _add() async {
    final selected = _selected;
    final page = _page;
    if (selected == null || page == null || _adding) return;
    final title = _video?.title ?? '';
    setState(() => _adding = true);
    try {
      final sdk =
          await VideoDownloadQueue.platform.invokeMethod<int>('sdk') ?? 29;
      if (sdk >= 33) {
        await Permission.notification.request();
      } else if (sdk <= 28 && _destination?.startsWith('content://') != true) {
        await Permission.storage.request();
      }
      await _loadFolder();
      await _queue.add(
        page: page,
        title: title,
        source: selected,
        destination: _destination,
      );
      if (mounted) setState(() => _filter = 'active');
    } on FacebookVideoException catch (e) {
      _show(e.message);
    } catch (_) {
      _show('Không thêm được video vào hàng đợi.');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  void _show(String message) {
    if (mounted) setState(() => _message = message);
  }

  Future<void> _act(Future<void> Function() action) async {
    try {
      await action();
    } on PlatformException catch (e) {
      _show(e.message ?? 'Không thao tác được với video.');
    } catch (_) {
      _show('Không lưu được thay đổi.');
    }
  }

  String _size(int? bytes) => bytes == null
      ? '—'
      : bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(0)} KB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  String _quality(VideoCandidate source) => [
    source.qualityLabel,
    if (source.fps != null)
      '${source.fps!.toStringAsFixed(source.fps! % 1 == 0 ? 0 : 2)} FPS',
    if (source.codec != null) source.codec!,
    if (source.bitrate != null) '${(source.bitrate! / 1000).round()} kb/s',
    if (source.hasAudio != null)
      source.hasAudio! ? 'Có âm thanh' : 'Video im lặng',
    if (source.bytes != null) '≈ ${_size(source.bytes)}',
  ].join(' · ');

  Widget _preview(VideoInfo info) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (info.thumbnailUrl != null)
            FutureBuilder<Uint8List?>(
              future: _thumbnail,
              builder: (_, snapshot) {
                final image = snapshot.data;
                return image == null
                    ? const SizedBox.shrink()
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(
                          image,
                          height: 190,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const SizedBox.shrink(),
                        ),
                      );
              },
            ),
          if (info.title != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                info.title!,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          if (info.candidates.length > 1)
            DropdownButton<VideoCandidate>(
              value: _selected,
              isExpanded: true,
              onChanged: (value) => setState(() => _selected = value),
              items: [
                for (var index = 0; index < info.candidates.length; index++)
                  DropdownMenuItem(
                    value: info.candidates[index],
                    child: Text(
                      '${index + 1}. ${_quality(info.candidates[index])}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            )
          else
            Text(_quality(info.best)),
          const SizedBox(height: 12),
          GradientButton(
            onPressed: _adding ? null : _add,
            icon: Icons.download,
            label: 'Tải xuống',
          ),
        ],
      ),
    ),
  );

  Widget _folder() => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          const Icon(Icons.folder, color: NeonColors.cyan),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Thư mục lưu',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  SaveFolder.label(_folderLabel),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (_destination != null)
            TextButton(onPressed: _resetFolder, child: const Text('Mặc định')),
          TextButton(onPressed: _pickFolder, child: const Text('Đổi thư mục')),
        ],
      ),
    ),
  );

  Future<void> _remove(VideoJob job) async {
    final delete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Xóa mục tải xuống'),
        content: Text(
          job.saved == null
              ? 'Xóa mục này khỏi lịch sử?'
              : 'Bạn muốn giữ hay xóa cả video đã lưu?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Quay lại'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Xóa lịch sử'),
          ),
          if (job.saved != null)
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Xóa cả video'),
            ),
        ],
      ),
    );
    if (delete != null) {
      await _act(() => _queue.removeHistory(job, deleteFile: delete));
    }
  }

  Widget _job(VideoJob job) {
    final total = job.total;
    final progress = total == null || total == 0
        ? null
        : (job.received / total).clamp(0.0, 1.0);
    final remaining = total == null || job.speed <= 0
        ? null
        : Duration(
            seconds: ((total - job.received).clamp(0, total) / job.speed)
                .ceil(),
          );
    final label = switch (job.state) {
      VideoJobState.queued => 'Đang chờ',
      VideoJobState.downloading => 'Đang tải hoặc ghép video',
      VideoJobState.saving => 'Đang lưu video',
      VideoJobState.paused => 'Đã tạm dừng',
      VideoJobState.complete => 'Đã tải xong',
      VideoJobState.failed => 'Tải thất bại',
      VideoJobState.cancelled => 'Đã hủy',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              job.title.isEmpty ? job.filename : job.title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text('$label · ${job.source.qualityLabel}'),
            if (job.state == VideoJobState.downloading ||
                job.state == VideoJobState.paused) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: progress ?? (job.active ? null : 0),
              ),
              const SizedBox(height: 6),
              Text(
                [
                  '${_size(job.received)} / ${_size(total)}',
                  if (progress != null) '${(progress * 100).floor()}%',
                  if (job.speed > 0)
                    '${(job.speed / (1024 * 1024)).toStringAsFixed(2)} MB/s',
                  if (remaining != null)
                    '~${remaining.inMinutes} phút ${remaining.inSeconds % 60} giây',
                ].join(' · '),
              ),
            ],
            if (job.warning != null) Text(job.warning!),
            if (job.error != null)
              Text(job.error!, style: const TextStyle(color: NeonColors.error)),
            Wrap(
              children: [
                if (job.state == VideoJobState.queued ||
                    job.state == VideoJobState.downloading)
                  TextButton(
                    onPressed: () => _act(() => _queue.pause(job)),
                    child: const Text('Tạm dừng'),
                  ),
                if (job.state == VideoJobState.paused ||
                    job.state == VideoJobState.failed)
                  TextButton(
                    onPressed: () => _act(() => _queue.resume(job)),
                    child: const Text('Tiếp tục'),
                  ),
                if (job.state == VideoJobState.queued ||
                    job.state == VideoJobState.downloading ||
                    job.state == VideoJobState.paused ||
                    job.state == VideoJobState.failed)
                  TextButton(
                    onPressed: () => _act(() => _queue.cancel(job)),
                    child: const Text('Hủy'),
                  ),
                if (job.saved != null) ...[
                  TextButton(
                    onPressed: () => _act(
                      () => VideoDownloadQueue.platform.invokeMethod<void>(
                        'open',
                        job.saved,
                      ),
                    ),
                    child: const Text('Mở video'),
                  ),
                  TextButton(
                    onPressed: () => _act(
                      () => VideoDownloadQueue.platform.invokeMethod<void>(
                        'share',
                        job.saved,
                      ),
                    ),
                    child: const Text('Chia sẻ'),
                  ),
                ],
                if (!job.active)
                  TextButton(
                    onPressed: () => _remove(job),
                    child: const Text('Xóa'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListenableBuilder(
      listenable: _queue,
      builder: (context, _) {
        final filtered = _queue.jobs
            .where(
              (job) => switch (_filter) {
                'done' => job.state == VideoJobState.complete,
                'failed' =>
                  job.state == VideoJobState.failed ||
                      job.state == VideoJobState.cancelled,
                _ => job.active || job.state == VideoJobState.paused,
              },
            )
            .toList();
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: filtered.length + 1,
          itemBuilder: (context, index) => index != 0
              ? _job(filtered[index - 1])
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Card(
                      child: ListTile(
                        leading: Icon(
                          _loggedIn ? Icons.check_circle : Icons.login,
                          color: NeonColors.cyan,
                        ),
                        title: Text(
                          _loggedIn
                              ? 'Đã đăng nhập Facebook'
                              : 'Đăng nhập Facebook',
                        ),
                        subtitle: _loggedIn
                            ? null
                            : const Text(
                                'Dùng phiên Facebook để mở video bạn có quyền xem.',
                              ),
                        trailing: _loggedIn
                            ? TextButton(
                                onPressed: _logout,
                                child: const Text('Đăng xuất'),
                              )
                            : null,
                        onTap: _loggedIn ? null : _login,
                      ),
                    ),
                    _folder(),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _link,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _fetch(),
                      decoration: InputDecoration(
                        labelText: 'Dán link video Facebook',
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.paste),
                          tooltip: 'Dán liên kết',
                          onPressed: () async {
                            final data = await Clipboard.getData(
                              Clipboard.kTextPlain,
                            );
                            if (mounted && data?.text != null) {
                              _link.text = data!.text!;
                            }
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    GradientButton(
                      onPressed: _fetching ? null : _fetch,
                      icon: Icons.search,
                      label: _fetching ? 'Đang lấy video…' : 'Lấy video',
                    ),
                    if (_fetching) const LinearProgressIndicator(),
                    if (_video != null) _preview(_video!),
                    if (_message != null)
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(
                          _message!,
                          style: const TextStyle(color: NeonColors.error),
                        ),
                      ),
                    if (_queue.startupError != null) Text(_queue.startupError!),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Hàng đợi và lịch sử',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        DropdownButton<int>(
                          value: _queue.parallel,
                          onChanged: (value) {
                            if (value != null) {
                              unawaited(_act(() => _queue.setParallel(value)));
                            }
                          },
                          items: [
                            for (var i = 1; i <= 3; i++)
                              DropdownMenuItem(
                                value: i,
                                child: Text('$i lượt đồng thời'),
                              ),
                          ],
                        ),
                      ],
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final entry in const {
                          'active': 'Đang tải',
                          'done': 'Hoàn thành',
                          'failed': 'Lỗi / đã hủy',
                        }.entries)
                          ChoiceChip(
                            label: Text(entry.value),
                            selected: _filter == entry.key,
                            onSelected: (_) =>
                                setState(() => _filter = entry.key),
                          ),
                      ],
                    ),
                    if (filtered.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text('Chưa có video trong mục này.'),
                      ),
                  ],
                ),
        );
      },
    );
  }
}

/// Trang trích xuất video từ trang Facebook ĐÃ RENDER trong WebView.
/// WebView dùng chung kho cookie với trang đăng nhập nên vẫn giữ phiên
/// đăng nhập, tự theo redirect của link share, và chạy JS của Facebook —
/// nhờ đó lấy được link mp4 mà HTML thô không có.
/// Trả về VideoInfo khi tìm thấy, null khi không tìm ra (màn hình chính
/// sẽ fallback sang cách HTTP GET + cookie cũ).
class _VideoExtractPage extends StatefulWidget {
  const _VideoExtractPage({required this.url});

  final String url;

  @override
  State<_VideoExtractPage> createState() => _VideoExtractPageState();
}

class _VideoExtractPageState extends State<_VideoExtractPage> {
  late final WebViewController _controller;
  final _extractor = FacebookVideoExtractor();
  String _status = 'Đang mở trang video...';
  bool _popped = false;
  bool _attempting = false;

  // JS lấy src các thẻ <video> trong DOM + og:video + toàn bộ HTML
  // sau khi trang đã render. Trả về JSON {videoSrcs, html}.
  static const _extractJs = '''
(function(){
  var videos = [];
  document.querySelectorAll('video').forEach(function(v){
    if (v.currentSrc) videos.push({url: v.currentSrc, width: v.videoWidth,
      height: v.videoHeight, has_audio: typeof v.webkitAudioDecodedByteCount === 'number' &&
        v.webkitAudioDecodedByteCount > 0 ? true : null});
    if (v.src) videos.push({url: v.src});
    v.querySelectorAll('source').forEach(function(s){
      if (s.src) videos.push({url: s.src});
    });
  });
  return JSON.stringify({videos: videos, html: document.documentElement.outerHTML,
    page: location.href});
})()
''';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          // Chặn điều hướng ngoài http(s): Facebook hay đẩy link fb://
          // để mở app gốc — WebView không hiểu scheme đó sẽ hiện lỗi
          // ERR_UNKNOWN_URL_SCHEME và làm chết trang đang mở.
          onNavigationRequest: (request) =>
              isFacebookPage(Uri.tryParse(request.url) ?? Uri())
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
          onPageFinished: (_) => _attemptExtract(),
          onWebResourceError: (_) {
            // Lỗi tài nguyên con (ảnh, script phụ) là bình thường,
            // vẫn để vòng thử trích xuất chạy hết rồi mới kết luận.
            // Lỗi KHÔNG được giết quá trình trích xuất.
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  void dispose() {
    _popped = true;
    _extractor.close();
    super.dispose();
  }

  void _pop([VideoInfo? info]) {
    if (_popped) return;
    _popped = true;
    if (mounted) Navigator.of(context).pop(info);
  }

  /// Thử trích xuất vài lần, cách nhau 1,5s — Facebook tải video
  /// lười (lazy-load) nên lần thử đầu có thể chưa có thẻ <video>.
  Future<void> _attemptExtract() async {
    if (_attempting || _popped) return;
    _attempting = true;
    try {
      for (var attempt = 0; attempt < 6; attempt++) {
        if (_popped) return;
        await Future.delayed(const Duration(milliseconds: 1500));
        if (_popped) return;
        try {
          final raw = await _controller.runJavaScriptReturningResult(
            _extractJs,
          );
          final data = _decodeJsResult(raw);
          if (data != null) {
            final videos = (data['videos'] as List? ?? [])
                .whereType<Map<String, dynamic>>()
                .toList();
            final html = data['html'] as String? ?? '';
            final page = data['page'] as String? ?? widget.url;
            final info = await _extractor.extractRendered(html, videos, page);
            _pop(info);
            return;
          }
        } on VideoNotFoundException {
          // Chưa có video trong lần thử này -> thử lại.
        } catch (_) {
          // Lỗi JS / trang chưa sẵn sàng -> thử lại.
        }
        if (mounted) {
          setState(() {
            _status = 'Đang mở trang video... (${attempt + 1}/6)';
          });
        }
      }
    } finally {
      _attempting = false;
    }
    // Hết lượt thử mà không thấy video -> trả null để fallback HTTP GET.
    _pop();
  }

  /// Kết quả JS qua platform channel có thể bị JSON-encode 1-2 lớp:
  /// String -> '"{...}"'. Giải mã lặp đến khi ra Map.
  Map<String, dynamic>? _decodeJsResult(Object raw) {
    dynamic current = raw;
    for (var i = 0; i < 3; i++) {
      if (current is Map<String, dynamic>) return current;
      if (current is String) {
        try {
          current = jsonDecode(current);
        } catch (_) {
          return null;
        }
      } else {
        return null;
      }
    }
    return current is Map<String, dynamic> ? current : null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Đang lấy video'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Hủy',
          onPressed: () => _pop(),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(_status)),
              ],
            ),
          ),
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
    );
  }
}

/// Người dùng tự gõ tài khoản/mật khẩu vào trang Facebook — app KHÔNG
/// hỏi, KHÔNG đọc, KHÔNG lưu mật khẩu. Khi phát hiện đủ cookie phiên
/// (c_user + xs) thì trả về header Cookie và đóng trang.
/// Trang đăng nhập Facebook trong WebView.
class FacebookLoginPage extends StatefulWidget {
  const FacebookLoginPage({super.key});

  @override
  State<FacebookLoginPage> createState() => _FacebookLoginPageState();
}

class _FacebookLoginPageState extends State<FacebookLoginPage> {
  late final WebViewController _controller;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          // Chặn điều hướng ngoài http(s) (fb://, intent://...):
          // WebView không hiểu các scheme đó, sẽ hiện lỗi
          // ERR_UNKNOWN_URL_SCHEME thay cho trang đăng nhập.
          onNavigationRequest: (request) =>
              isFacebookPage(Uri.tryParse(request.url) ?? Uri())
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
          onPageFinished: (_) => _checkLogin(auto: true),
        ),
      )
      ..loadRequest(Uri.parse('https://www.facebook.com/login'));
  }

  /// Đọc cookie Facebook từ WebView. Nếu đủ c_user + xs -> coi như
  /// đăng nhập xong, trả header Cookie về màn hình chính.
  Future<void> _checkLogin({bool auto = false}) async {
    if (_checking) return;
    _checking = true;
    // Lấy sẵn Navigator/Messenger trước khi await (tránh lint async gap).
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final cookies = await WebViewCookieManager().getCookies(
        domain: Uri.parse('https://www.facebook.com'),
      );
      final map = <String, String>{for (final c in cookies) c.name: c.value};
      if (FacebookSession.hasLoginCookies(map)) {
        final header = FacebookSession.buildCookieHeader(map);
        if (mounted) {
          Future.microtask(() => navigator.pop(header));
        }
        return;
      }
      if (!auto && mounted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Chưa đăng nhập. Hãy đăng nhập vào Facebook rồi thử lại.',
            ),
          ),
        );
      }
    } catch (_) {
      if (!auto && mounted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Không kiểm tra được đăng nhập. Thử lại.'),
          ),
        );
      }
    } finally {
      _checking = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Đăng nhập Facebook')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'Nhập tài khoản vào trang Facebook bên dưới. '
              'App không thấy và không lưu mật khẩu của bạn.',
              style: TextStyle(fontSize: 14),
            ),
          ),
          Expanded(child: WebViewWidget(controller: _controller)),
          Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              child: GradientButton(
                onPressed: () => _checkLogin(),
                icon: Icons.check,
                label: 'Kiểm tra đăng nhập',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
