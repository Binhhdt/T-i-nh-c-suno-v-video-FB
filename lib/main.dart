import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'album_extractor.dart';
import 'audio_converter.dart';
import 'downloader.dart';
import 'neon_theme.dart';
import 'save_folder.dart';
import 'save_folder_card.dart';
import 'session.dart';
import 'suno_crypto.dart';
import 'suno_extractor.dart';
import 'suno_filename.dart';
import 'video_extractor.dart';
import 'web_navigation.dart';

part 'album_tab.dart';

void main() => runApp(const FbVideoDownloaderApp());

class FbVideoDownloaderApp extends StatelessWidget {
  const FbVideoDownloaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tải Video FB',
      debugShowCheckedModeBanner: false,
      theme: neonTheme(),
      home: const DownloaderPage(),
    );
  }
}

enum _Stage { idle, fetching, found, downloading, decrypting, converting, done, error }

/// Màn hình chính: 3 tab — "Video FB" (tải video Facebook),
/// "Nhạc Suno" (tải nhạc Suno, convert MP3/WAV trên máy) và
/// "Album FB" (tải ảnh bài viết nhiều ảnh / album Facebook).
/// Cài đặt "Thư mục lưu" có ở CẢ 2 tab (widget dùng chung) và dùng
/// chung resolver thư mục lưu.
class DownloaderPage extends StatelessWidget {
  const DownloaderPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const GradientText('Tải Video & Nhạc'),
          centerTitle: true,
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Video FB'),
              Tab(text: 'Nhạc Suno'),
              Tab(text: 'Album FB'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _FacebookTab(),
            _SunoTab(),
            _AlbumTab(),
          ],
        ),
      ),
    );
  }
}

class _FacebookTab extends StatefulWidget {
  const _FacebookTab();

  @override
  State<_FacebookTab> createState() => _FacebookTabState();
}

class _FacebookTabState extends State<_FacebookTab> {
  final _linkController = TextEditingController();
  final _extractor = FacebookVideoExtractor();
  final _downloader = VideoDownloader();

  _Stage _stage = _Stage.idle;
  String _status = '';
  VideoInfo? _videoInfo;
  VideoCandidate? _selected;
  double _progress = 0;
  String? _savedPath;

  // Phiên đăng nhập Facebook — chỉ giữ header Cookie trong bộ nhớ,
  // không lưu ra file, không log. Mật khẩu không bao giờ qua app.
  bool _isLoggedIn = false;
  String? _cookieHeader;

  @override
  void dispose() {
    _linkController.dispose();
    super.dispose();
  }

  Future<bool> _ensurePermission() async {
    if (!Platform.isAndroid) return true;
    try {
      var status = await Permission.storage.request();
      if (status.isGranted || status.isLimited) return true;
      // Android 13+: quyền storage cũ không còn tác dụng, xin quyền video.
      final videoStatus = await Permission.videos.request();
      return videoStatus.isGranted || videoStatus.isLimited;
    } catch (_) {
      // Thư mục riêng của app không cần quyền -> vẫn cho tải tiếp.
      return true;
    }
  }

  Future<void> _fetchVideo() async {
    final link = _linkController.text.trim();
    if (link.isEmpty) {
      setState(() {
        _stage = _Stage.error;
        _status = 'Bạn chưa nhập link video.';
      });
      return;
    }
    setState(() {
      _stage = _Stage.fetching;
      _status = 'Đang mở trang video...';
      _videoInfo = null;
      _selected = null;
      _savedPath = null;
      _progress = 0;
    });
    try {
      final normalized = _extractor.normalizeUrl(link);
      // 1. Trích xuất từ trang đã render trong WebView (đã đăng nhập,
      // chạy JS, share link tự theo redirect). Cách này xử lý được
      // trang video Facebook mà HTML thô không chứa link mp4.
      final webInfo = await Navigator.of(context).push<VideoInfo?>(
        MaterialPageRoute(
          builder: (_) => _VideoExtractPage(url: normalized),
        ),
      );
      if (!mounted) return;
      if (webInfo != null) {
        setState(() {
          _videoInfo = webInfo;
          _selected = webInfo.best;
          _stage = _Stage.found;
          _status =
              'Tìm thấy ${webInfo.candidates.length} bản video. Đang chọn bản chất lượng cao nhất.';
        });
        return;
      }
      // 2. Fallback: HTTP GET + cookie (cách cũ) nếu WebView không tìm ra.
      setState(() {
        _status = 'Đang thử cách khác...';
      });
      final info = await _extractor.extract(
        link,
        cookieHeader: _cookieHeader,
      );
      if (!mounted) return;
      setState(() {
        _videoInfo = info;
        _selected = info.best;
        _stage = _Stage.found;
        _status =
            'Tìm thấy ${info.candidates.length} bản video. Đang chọn bản chất lượng cao nhất.';
      });
    } on VideoNotFoundException catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.error;
        _status = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.error;
        _status = 'Có lỗi xảy ra. Kiểm tra mạng và thử lại.';
      });
    }
  }

  /// Mở WebView đăng nhập Facebook. Khi đăng nhập xong, nhận về
  /// header Cookie (chỉ trong bộ nhớ) và hiển thị trạng thái đã đăng nhập.
  Future<void> _openLogin() async {
    final header = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _FacebookLoginPage()),
    );
    if (!mounted) return;
    if (header != null && header.isNotEmpty) {
      setState(() {
        _isLoggedIn = true;
        _cookieHeader = header;
        _status = 'Đã đăng nhập Facebook. Giờ có thể tải video bạn được xem.';
      });
    } else {
      setState(() {
        _status = 'Chưa đăng nhập Facebook. Hãy đăng nhập rồi thử lại.';
      });
    }
  }

  /// Đăng xuất: xoá cookie phiên trong WebView, quên header Cookie.
  Future<void> _logout() async {
    try {
      await WebViewCookieManager().clearCookies();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _isLoggedIn = false;
      _cookieHeader = null;
      _status = 'Đã đăng xuất Facebook.';
    });
  }

  Future<void> _download() async {
    final candidate = _selected;
    if (candidate == null) return;
    await _ensurePermission();
    setState(() {
      _stage = _Stage.downloading;
      _status = 'Đang tải xuống...';
      _progress = 0;
    });
    try {
      // Thư mục lưu dùng chung cả 2 tab: thư mục đã chọn (nếu ghi được)
      // -> Downloads công khai -> thư mục riêng của app (kèm báo rõ).
      final resolved = await resolveUserVisibleSaveDir();
      // Tên file theo TIÊU ĐỀ GỐC của video (vd "Mưa trên phố.mp4") để
      // nhìn tên file là biết video nào. Không có tiêu đề -> tên cũ
      // `fb_video_<timestamp>.mp4`. Trùng tên -> thêm " (1)", " (2)", ...
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final cleanTitle = sanitizeSongTitle(_videoInfo?.title ?? '');
      final baseName = cleanTitle.isEmpty ? 'fb_video_$stamp' : cleanTitle;
      final fileName = uniqueFileName(
        resolved.dir.path,
        '$baseName.mp4',
        exists: (p) => File(p).existsSync(),
      );
      final result = await _downloader.download(
        candidate.url,
        fileName: fileName,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _progress = p < 0 ? 0 : p);
        },
        preferredDir: resolved.dir,
      );
      final fellBack = resolved.usedFallback || result.usedFallback;
      setState(() {
        _stage = _Stage.done;
        _savedPath = result.file.path;
        _status = resolved.usedPrivateFallback
            ? 'Không ghi được vào thư mục đã chọn/Downloads, đã lưu vào thư mục riêng của app (chỉ mở được trong app).'
            : fellBack
                ? 'Thư mục đã chọn không dùng được, đã lưu vào Downloads.'
                : 'Đã tải xong!';
      });
    } catch (e) {
      setState(() {
        _stage = _Stage.error;
        _status = 'Tải thất bại: ${e.toString().replaceFirst('Exception: ', '')}';
      });
    }
  }

  /// Thẻ "Thư mục lưu" dùng chung tự lưu lựa chọn vào prefs — tab chỉ
  /// cần biết để hiển thị trạng thái (resolver đọc lại prefs mỗi lần tải).
  void _onSaveFolderChanged(String? path) {
    if (!mounted) return;
    setState(() {
      _status = path == null
          ? 'Đã quay lại thư mục lưu mặc định (Downloads).'
          : 'Đã chọn thư mục lưu: $path';
    });
  }

  Future<void> _openVideo() async {
    final path = _savedPath;
    if (path == null) return;
    await OpenFile.open(path);
  }

  @override
  Widget build(BuildContext context) {
    final isBusy =
        _stage == _Stage.fetching || _stage == _Stage.downloading;
    return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Card(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'Chỉ tải video của bạn hoặc video được phép tải.',
                  style: TextStyle(fontSize: 14, color: NeonColors.muted),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: _isLoggedIn
                    ? Row(
                        children: [
                          const Icon(Icons.check_circle,
                              color: Colors.green),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text('Đã đăng nhập Facebook'),
                          ),
                          TextButton(
                            onPressed: _logout,
                            child: const Text('Đăng xuất'),
                          ),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'Video không công khai cần đăng nhập Facebook để tải.',
                            style: TextStyle(fontSize: 14),
                          ),
                          const SizedBox(height: 8),
                          GradientButton(
                            onPressed: _openLogin,
                            icon: Icons.login,
                            label: 'Đăng nhập Facebook',
                          ),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 12),
            SaveFolderCard(onChanged: _onSaveFolderChanged),
            const SizedBox(height: 12),
            TextField(
              controller: _linkController,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _fetchVideo(),
              decoration: InputDecoration(
                labelText: 'Dán link video Facebook',
                hintText: 'https://www.facebook.com/...',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.paste),
                  tooltip: 'Dán từ bộ nhớ tạm',
                  onPressed: () async {
                    final data = await Clipboard.getData(Clipboard.kTextPlain);
                    if (data?.text != null) {
                      _linkController.text = data!.text!;
                    }
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),
            GradientButton(
              onPressed: isBusy ? null : _fetchVideo,
              icon: Icons.search,
              label: 'Lấy video',
            ),
            const SizedBox(height: 16),
            if (_stage == _Stage.fetching)
              const Center(child: CircularProgressIndicator()),
            if (_videoInfo != null) _buildPreview(),
            if (_stage == _Stage.downloading) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: _progress > 0 ? _progress : null),
              const SizedBox(height: 8),
              Text(
                _progress > 0
                    ? 'Đang tải... ${(_progress * 100).toStringAsFixed(0)}%'
                    : 'Đang tải...',
                textAlign: TextAlign.center,
              ),
            ],
            if (_stage == _Stage.done && _savedPath != null) ...[
              const SizedBox(height: 16),
              GradientButton(
                onPressed: _openVideo,
                icon: Icons.play_circle_fill,
                label: 'Mở video',
              ),
              const SizedBox(height: 8),
              Text(
                'Đã lưu: $_savedPath',
                style: const TextStyle(fontSize: 12, color: NeonColors.muted),
              ),
            ],
            if (_status.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                _status,
                style: TextStyle(
                  color: _stage == _Stage.error ? NeonColors.error : null,
                ),
              ),
            ],
          ],
        ),
    );
  }

  Widget _buildPreview() {
    final info = _videoInfo!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (info.thumbnailUrl != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  info.thumbnailUrl!,
                  height: 200,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            const SizedBox(height: 12),
            if (info.candidates.length > 1)
              DropdownButton<VideoCandidate>(
                value: _selected,
                isExpanded: true,
                items: info.candidates
                    .map(
                      (c) => DropdownMenuItem(
                        value: c,
                        child: Text('Chất lượng: ${c.qualityLabel}'),
                      ),
                    )
                    .toList(),
                onChanged: (c) => setState(() => _selected = c),
              )
            else
              Text('Chất lượng: ${_selected?.qualityLabel ?? 'Video'}'),
            const SizedBox(height: 12),
            GradientButton(
              onPressed: _stage == _Stage.downloading ? null : _download,
              icon: Icons.download,
              label: 'Tải xuống',
            ),
          ],
        ),
      ),
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
  var srcs = [];
  document.querySelectorAll('video').forEach(function(v){
    if (v.currentSrc) srcs.push(v.currentSrc);
    if (v.src) srcs.push(v.src);
    v.querySelectorAll('source').forEach(function(s){
      if (s.src) srcs.push(s.src);
    });
  });
  var m = document.querySelector('meta[property="og:video"]');
  if (m && m.content) srcs.push(m.content);
  return JSON.stringify({videoSrcs: srcs, html: document.documentElement.outerHTML});
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
              navigationDecisionFor(request.url),
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
            final videoSrcs = (data['videoSrcs'] as List?)
                    ?.map((e) => e.toString())
                    .toList() ??
                const <String>[];
            final html = (data['html'] as String?) ?? '';
            final info = _extractor.parseRenderedPage(html, videoSrcs);
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
class _FacebookLoginPage extends StatefulWidget {
  const _FacebookLoginPage();

  @override
  State<_FacebookLoginPage> createState() => _FacebookLoginPageState();
}

class _FacebookLoginPageState extends State<_FacebookLoginPage> {
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
              navigationDecisionFor(request.url),
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
      final map = <String, String>{
        for (final c in cookies) c.name: c.value,
      };
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
      appBar: AppBar(
        title: const Text('Đăng nhập Facebook'),
      ),
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

/// Tab "Nhạc Suno": dán link bài nhạc Suno -> lấy nhạc -> tải xuống.
/// Chỉ xử lý link bài nhạc công khai, KHÔNG đăng nhập Suno, không hỏi
/// mật khẩu Suno. Dùng chung cài đặt "Thư mục lưu" của tab Video FB.
class _SunoTab extends StatefulWidget {
  const _SunoTab();

  @override
  State<_SunoTab> createState() => _SunoTabState();
}

class _SunoTabState extends State<_SunoTab> {
  final _linkController = TextEditingController();
  final _extractor = SunoExtractor();
  final _downloader = VideoDownloader();
  final _converter = AudioConverter();

  _Stage _stage = _Stage.idle;
  String _status = '';
  SunoSongInfo? _songInfo;
  String _format = 'mp3'; // 'mp3' | 'wav'
  double _progress = 0;
  String? _savedPath;

  @override
  void dispose() {
    _linkController.dispose();
    super.dispose();
  }

  Future<bool> _ensurePermission() async {
    if (!Platform.isAndroid) return true;
    try {
      var status = await Permission.storage.request();
      if (status.isGranted || status.isLimited) return true;
      final audioStatus = await Permission.audio.request();
      return audioStatus.isGranted || audioStatus.isLimited;
    } catch (_) {
      // Thư mục riêng của app không cần quyền -> vẫn cho tải tiếp.
      return true;
    }
  }

  Future<void> _fetchSong() async {
    final link = _linkController.text.trim();
    if (link.isEmpty) {
      setState(() {
        _stage = _Stage.error;
        _status = 'Bạn chưa nhập link nhạc.';
      });
      return;
    }
    setState(() {
      _stage = _Stage.fetching;
      _status = 'Đang lấy thông tin bài nhạc...';
      _songInfo = null;
      _savedPath = null;
      _progress = 0;
    });
    try {
      final info = await _extractor.extract(link);
      if (!mounted) return;
      setState(() {
        _songInfo = info;
        _format = 'mp3';
        _stage = _Stage.found;
        _status = 'Đã tìm thấy bài nhạc.';
      });
    } on SunoNotFoundException catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.error;
        _status = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.error;
        _status = 'Có lỗi xảy ra. Kiểm tra mạng và thử lại.';
      });
    }
  }

  /// Kế hoạch tải: tải URL nào, đuôi file gốc là gì, có cần chuyển đổi
  /// sang định dạng đích trên máy không.
  /// - WAV gốc công khai (hiếm) -> tải thẳng, không chuyển đổi.
  /// - Còn lại: tải file audio gốc (thường .m4a), rồi convert sang
  ///   định dạng đã chọn nếu đuôi gốc khác định dạng đích.
  ({String url, String sourceExt, bool needsConversion})? _downloadPlan() {
    final info = _songInfo;
    if (info == null) return null;
    if (_format == 'wav' && info.wavUrl != null) {
      return (url: info.wavUrl!, sourceExt: 'wav', needsConversion: false);
    }
    final srcExt = info.audioExtension;
    return (
      url: info.audioUrl,
      sourceExt: srcExt,
      needsConversion: needsConversion(srcExt, _format),
    );
  }

  /// Tên file đích theo TIÊU ĐỀ GỐC của bài nhạc (vd "Tình khúc ngày cũ.wav").
  /// Nếu tiêu đề trống/sau làm sạch không còn gì thì fallback `suno_<ts>`.
  /// Tránh ghi đè: file trùng tên thì thêm " (1)", " (2)", ...
  String _uniqueTitleFileName(Directory dir, String ext, int stamp) {
    final clean = sanitizeSongTitle(_songInfo?.title ?? '');
    final base = clean.isEmpty ? 'suno_$stamp' : clean;
    return uniqueFileName(
      dir.path,
      '$base.$ext',
      exists: (p) => File(p).existsSync(),
    );
  }

  Future<void> _download() async {
    final plan = _downloadPlan();
    if (plan == null) return;
    await _ensurePermission();
    setState(() {
      _stage = _Stage.downloading;
      _status = 'Đang tải xuống...';
      _progress = 0;
    });
    try {
      // Thư mục lưu dùng chung cả 2 tab: thư mục đã chọn (nếu ghi được)
      // -> Downloads công khai -> thư mục riêng của app (kèm báo rõ).
      final resolved = await resolveUserVisibleSaveDir();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      // 1. Tải file GỐC về thư mục tạm (cache của app), không tải thẳng
      // vào thư mục lưu — để sau chuyển đổi không để lại file tạm thừa.
      final tempDir = await getTemporaryDirectory();
      final sourceName = 'suno_${stamp}_source.${plan.sourceExt}';
      final result = await _downloader.download(
        plan.url,
        fileName: sourceName,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _progress = p < 0 ? 0 : p);
        },
        preferredDir: tempDir,
      );
      var sourceFile = result.file;

      // 2. GIẢI MÃ (nếu file chưa phải media thường). File audio Suno
      // từ media_urls được mã hoá AES — ffmpeg không convert được file
      // chưa giải mã. File nào đã là media thường (mp3 cũ, wav gốc)
      // thì bỏ qua bước này.
      if (!await isPlayableMediaFile(sourceFile.path)) {
        if (mounted) {
          setState(() {
            _stage = _Stage.decrypting;
            _status = 'Đang giải mã...';
          });
        }
        final clipId = _songInfo?.clipId;
        if (clipId == null) {
          throw const SunoCryptoException(
            'Không xác định được mã bài nhạc để giải mã.',
          );
        }
        try {
          final rights = await fetchRights(clipId);
          final decryptedPath =
              '${tempDir.path}/suno_${stamp}_decrypted.${plan.sourceExt}';
          await decryptAudioFile(
            inputPath: sourceFile.path,
            outputPath: decryptedPath,
            clipId: clipId,
            rights: rights,
          );
          try {
            await sourceFile.delete();
          } catch (_) {}
          sourceFile = File(decryptedPath);
        } on SunoCryptoException catch (e) {
          // Giải mã lỗi -> KHÔNG lưu file mã hoá (mở không nghe được).
          try {
            await sourceFile.delete();
          } catch (_) {}
          throw SunoCryptoException(
            'Không giải mã được file nhạc: ${e.message}',
          );
        }
      }

      // 3. Chuyển đổi (nếu cần) hoặc chép file vào thư mục lưu.
      // File fallback khi convert lỗi là file ĐÃ GIẢI MÃ (nghe được),
      // không phải file mã hoá gốc.
      late final String savedPath;
      String? convertNote;
      if (!plan.needsConversion) {
        final dest = File(
          '${resolved.dir.path}/${_uniqueTitleFileName(resolved.dir, plan.sourceExt, stamp)}',
        );
        if (sourceFile.path != dest.path) {
          await sourceFile.copy(dest.path);
          try {
            await sourceFile.delete();
          } catch (_) {}
        }
        savedPath = dest.path;
      } else {
        if (mounted) {
          setState(() {
            _stage = _Stage.converting;
            _status = 'Đang chuyển đổi...';
          });
        }
        final destPath =
            '${resolved.dir.path}/${_uniqueTitleFileName(resolved.dir, _format, stamp)}';
        final conv = await _converter.convert(
          inputPath: sourceFile.path,
          outputPath: destPath,
          format: _format,
        );
        if (conv.ok) {
          try {
            await sourceFile.delete();
          } catch (_) {}
          savedPath = destPath;
        } else {
          // Chuyển đổi lỗi -> giữ file đã giải mã, báo LỖI THẬT của
          // ffmpeg (mã + log) thay vì thông báo chung chung.
          final fallbackFile = File(
            '${resolved.dir.path}/${_uniqueTitleFileName(resolved.dir, plan.sourceExt, stamp)}',
          );
          if (sourceFile.path != fallbackFile.path) {
            await sourceFile.copy(fallbackFile.path);
            try {
              await sourceFile.delete();
            } catch (_) {}
          }
          savedPath = fallbackFile.path;
          final detail = conv.errorOutput.isNotEmpty
              ? ' (${conv.errorOutput})'
              : '';
          convertNote = 'Convert lỗi (mã ${conv.returnCode ?? '?'}):'
              '${detail.isEmpty ? ' không rõ nguyên nhân' : detail}'
              ' Đã lưu file gốc đã giải mã.';
        }
      }
      if (!mounted) return;
      final statusParts = <String>[];
      if (resolved.usedPrivateFallback) {
        statusParts.add(
          'Không ghi được vào thư mục đã chọn/Downloads, đã lưu vào '
          'thư mục riêng của app (chỉ mở được trong app).',
        );
      } else if (resolved.usedFallback) {
        statusParts.add(
          'Thư mục đã chọn không dùng được, đã lưu vào Downloads.',
        );
      }
      if (convertNote != null) statusParts.add(convertNote);
      setState(() {
        _stage = _Stage.done;
        _savedPath = savedPath;
        _status =
            statusParts.isEmpty ? 'Đã tải xong!' : statusParts.join(' ');
      });
    } catch (e) {
      setState(() {
        _stage = _Stage.error;
        _status = 'Tải thất bại: ${e.toString().replaceFirst('Exception: ', '')}';
      });
    }
  }

  Future<void> _openFile() async {
    final path = _savedPath;
    if (path == null) return;
    await OpenFile.open(path);
  }

  /// Thẻ "Thư mục lưu" dùng chung tự lưu lựa chọn vào prefs — tab này
  /// không cần giữ state riêng (resolver đọc lại prefs mỗi lần tải).
  void _onSaveFolderChanged(String? path) {}

  @override
  Widget build(BuildContext context) {
    final isBusy = _stage == _Stage.fetching ||
        _stage == _Stage.downloading ||
        _stage == _Stage.decrypting ||
        _stage == _Stage.converting;
    final info = _songInfo;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Card(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Chỉ tải nhạc của bạn hoặc nhạc được phép tải.',
                style: TextStyle(fontSize: 14, color: NeonColors.muted),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SaveFolderCard(onChanged: _onSaveFolderChanged),
          TextField(
            controller: _linkController,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _fetchSong(),
            decoration: InputDecoration(
              labelText: 'Dán link nhạc Suno (suno.com/song/...)',
              hintText: 'https://suno.com/song/...',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(Icons.paste),
                tooltip: 'Dán từ bộ nhớ tạm',
                onPressed: () async {
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  if (data?.text != null) {
                    _linkController.text = data!.text!;
                  }
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
          GradientButton(
            onPressed: isBusy ? null : _fetchSong,
            icon: Icons.search,
            label: 'Lấy nhạc',
          ),
          const SizedBox(height: 16),
          if (_stage == _Stage.fetching)
            const Center(child: CircularProgressIndicator()),
          if (info != null) _buildPreview(),
          if (_stage == _Stage.decrypting) ...[
            const SizedBox(height: 16),
            const Center(child: CircularProgressIndicator()),
            const SizedBox(height: 8),
            const Text(
              'Đang giải mã...',
              textAlign: TextAlign.center,
            ),
          ],
          if (_stage == _Stage.converting) ...[
            const SizedBox(height: 16),
            const Center(child: CircularProgressIndicator()),
            const SizedBox(height: 8),
            const Text(
              'Đang chuyển đổi...',
              textAlign: TextAlign.center,
            ),
          ],
          if (_stage == _Stage.downloading) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(value: _progress > 0 ? _progress : null),
            const SizedBox(height: 8),
            Text(
              _progress > 0
                  ? 'Đang tải... ${(_progress * 100).toStringAsFixed(0)}%'
                  : 'Đang tải...',
              textAlign: TextAlign.center,
            ),
          ],
          if (_stage == _Stage.done && _savedPath != null) ...[
            const SizedBox(height: 16),
            GradientButton(
              onPressed: _openFile,
              icon: Icons.audio_file,
              label: 'Mở file',
            ),
            const SizedBox(height: 8),
            Text(
              'Đã lưu: $_savedPath',
              style: const TextStyle(fontSize: 12, color: NeonColors.muted),
            ),
          ],
          if (_status.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              _status,
              style: TextStyle(
                color: _stage == _Stage.error ? NeonColors.error : null,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPreview() {
    final info = _songInfo!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (info.coverUrl != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  info.coverUrl!,
                  height: 200,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const CoverPlaceholder(),
                ),
              )
            else
              const CoverPlaceholder(),
            const SizedBox(height: 12),
            Text(
              info.title,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 12),
            const Text('Định dạng tải xuống:'),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'mp3',
                  label: Text('MP3'),
                ),
                ButtonSegment(
                  value: 'wav',
                  label: Text('WAV'),
                ),
              ],
              selected: {_format},
              onSelectionChanged: (s) => setState(() => _format = s.first),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'MP3/WAV được chuyển đổi từ file gốc của Suno ngay trên '
                'máy — chất lượng bằng file gốc, không tăng thêm.',
                style: TextStyle(fontSize: 12, color: NeonColors.muted),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'WAV nặng hơn nhiều (~gấp 10 lần MP3).',
                style: TextStyle(fontSize: 12, color: NeonColors.muted),
              ),
            ),
            const SizedBox(height: 12),
            GradientButton(
              onPressed: _stage == _Stage.downloading ||
                      _stage == _Stage.decrypting ||
                      _stage == _Stage.converting
                  ? null
                  : _download,
              icon: Icons.download,
              label: 'Tải xuống',
            ),
          ],
        ),
      ),
    );
  }
}

