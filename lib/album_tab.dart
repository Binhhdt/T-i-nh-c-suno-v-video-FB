part of 'main.dart';

/// Đọc header Cookie Facebook từ kho cookie của WebView (đăng nhập ở
/// tab Video FB hoặc tab Album đều dùng chung kho này). Chỉ dùng trong
/// bộ nhớ, không lưu ra file, không log. null nếu chưa đăng nhập.
Future<String?> readFacebookCookieHeader() async {
  try {
    final cookies = await WebViewCookieManager().getCookies(
      domain: Uri.parse('https://www.facebook.com'),
    );
    final map = <String, String>{for (final c in cookies) c.name: c.value};
    if (!FacebookSession.hasLoginCookies(map)) return null;
    return FacebookSession.buildCookieHeader(map);
  } catch (_) {
    return null;
  }
}

/// Tab "Album FB": dán link bài viết nhiều ảnh / album -> lấy ảnh ->
/// chọn ảnh -> tải về (mỗi lần tải 1 thư mục riêng).
///
/// Khác bản lỗi trước: link share được giải ra link bài thật, link dẫn
/// về Bảng tin thì DỪNG (không quét Bảng tin), và chỉ lấy ảnh thuộc
/// đúng bài viết/album.
class _AlbumTab extends StatefulWidget {
  const _AlbumTab();

  @override
  State<_AlbumTab> createState() => _AlbumTabState();
}

class _AlbumTabState extends State<_AlbumTab> {
  final _linkController = TextEditingController();
  final _extractor = FacebookAlbumExtractor();
  final _downloader = VideoDownloader();

  _Stage _stage = _Stage.idle;
  String _status = '';
  AlbumInfo? _info;
  final Set<String> _selected = {};
  int _done = 0;
  int _total = 0;
  String? _savedDir;
  String? _firstSavedFile;
  bool _isLoggedIn = false;

  @override
  void initState() {
    super.initState();
    _refreshLogin();
  }

  @override
  void dispose() {
    _linkController.dispose();
    super.dispose();
  }

  Future<void> _refreshLogin() async {
    final header = await readFacebookCookieHeader();
    if (!mounted) return;
    setState(() => _isLoggedIn = header != null);
  }

  Future<void> _openLogin() async {
    await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _FacebookLoginPage()),
    );
    await _refreshLogin();
    if (!mounted) return;
    setState(() {
      _status = _isLoggedIn
          ? 'Đã đăng nhập Facebook.'
          : 'Chưa đăng nhập Facebook.';
    });
  }

  Future<bool> _ensurePermission() async {
    if (!Platform.isAndroid) return true;
    try {
      final status = await Permission.storage.request();
      if (status.isGranted || status.isLimited) return true;
      // Android 13+: quyền storage cũ không còn tác dụng, xin quyền ảnh.
      final photos = await Permission.photos.request();
      return photos.isGranted || photos.isLimited;
    } catch (_) {
      return true;
    }
  }

  void _setStatus(String s) {
    if (!mounted) return;
    setState(() => _status = s);
  }

  Future<void> _fetch() async {
    FocusScope.of(context).unfocus();
    final link = _linkController.text.trim();
    if (link.isEmpty) {
      setState(() {
        _stage = _Stage.error;
        _status = 'Bạn chưa nhập link album / bài viết.';
      });
      return;
    }
    setState(() {
      _stage = _Stage.fetching;
      _status = 'Đang mở link...';
      _info = null;
      _selected.clear();
      _savedDir = null;
      _firstSavedFile = null;
      _done = 0;
      _total = 0;
    });

    String url;
    try {
      url = _extractor.normalizeUrl(link);
    } on AlbumNotFoundException catch (e) {
      setState(() {
        _stage = _Stage.error;
        _status = e.message;
      });
      return;
    }

    final cookie = await readFacebookCookieHeader();
    if (!mounted) return;
    setState(() => _isLoggedIn = cookie != null);

    // 1. Giải link share ra link bài viết thật.
    if (FacebookAlbumExtractor.isShareLink(url)) {
      _setStatus('Đang giải link chia sẻ...');
      url = await _extractor.resolveShareUrl(url, cookieHeader: cookie);
      if (!mounted) return;
    }
    if (FacebookAlbumExtractor.isHomeOrFeedUrl(url)) {
      setState(() {
        _stage = _Stage.error;
        _status = const AlbumFeedRedirectException().message;
      });
      return;
    }

    // 2. Đọc trang qua mạng (nhanh, không cần cuộn).
    AlbumInfo? info;
    String? error;
    try {
      info = await _extractor.extract(
        url,
        cookieHeader: cookie,
        onStatus: _setStatus,
      );
    } on AlbumFeedRedirectException catch (e) {
      // Về Bảng tin -> KHÔNG thử tiếp bằng WebView (sẽ lại quét Bảng tin).
      if (!mounted) return;
      setState(() {
        _stage = _Stage.error;
        _status = e.message;
      });
      return;
    } on AlbumNotFoundException catch (e) {
      error = e.message;
    } catch (_) {
      error = null;
    }
    if (!mounted) return;

    // 3. Dự phòng: mở trang trong WebView (đã đăng nhập, chạy JS).
    if (info == null || info.photos.isEmpty) {
      _setStatus('Đang mở trang trong trình duyệt...');
      final result = await Navigator.of(context).push<_AlbumWebResult>(
        MaterialPageRoute(builder: (_) => _AlbumExtractPage(url: url)),
      );
      if (!mounted) return;
      if (result?.info != null && result!.info!.photos.isNotEmpty) {
        info = result.info;
      } else {
        error = result?.error ?? error;
      }
    }

    if (info == null || info.photos.isEmpty) {
      setState(() {
        _stage = _Stage.error;
        _status = error ??
            'Không tìm thấy ảnh. Có thể bài viết riêng tư hoặc cần đăng nhập.';
      });
      return;
    }

    final found = info;
    setState(() {
      _info = found;
      _selected
        ..clear()
        ..addAll(found.photos.map((p) => p.id));
      _stage = _Stage.found;
      final declared = found.declaredCount;
      _status = declared != null && declared > found.photos.length
          ? 'Tìm thấy ${found.photos.length}/$declared ảnh của bài viết '
              '(Facebook không cho xem hết ${declared - found.photos.length} ảnh còn lại).'
          : 'Tìm thấy ${found.photos.length} ảnh của bài viết.';
    });
  }

  Future<void> _download() async {
    final info = _info;
    if (info == null) return;
    final photos =
        info.photos.where((p) => _selected.contains(p.id)).toList();
    if (photos.isEmpty) return;
    await _ensurePermission();
    if (!mounted) return;
    setState(() {
      _stage = _Stage.downloading;
      _done = 0;
      _total = photos.length;
      _status = 'Đang tải ${photos.length} ảnh...';
      _savedDir = null;
      _firstSavedFile = null;
    });

    try {
      final resolved = await resolveUserVisibleSaveDir();
      // Mỗi lần tải 1 thư mục riêng, đặt theo tiêu đề bài viết.
      var base = sanitizeSongTitle(info.title ?? '').replaceAll('.', ' ');
      if (base.length > 50) base = base.substring(0, 50).trim();
      if (base.isEmpty) {
        final n = DateTime.now();
        String two(int v) => v.toString().padLeft(2, '0');
        base = 'FB Album ${n.year}-${two(n.month)}-${two(n.day)} '
            '${two(n.hour)}h${two(n.minute)}';
      }
      final folderName = uniqueFileName(
        resolved.dir.path,
        base,
        exists: (p) => Directory(p).existsSync() || File(p).existsSync(),
      );
      var target = Directory('${resolved.dir.path}/$folderName');
      try {
        await target.create(recursive: true);
        if (!canWriteToSync(target.path)) target = resolved.dir;
      } catch (_) {
        target = resolved.dir;
      }

      final cookie = await readFacebookCookieHeader();
      var ok = 0;
      var small = 0;
      final errors = <String>[];
      var next = 0;

      Future<void> worker() async {
        while (true) {
          final i = next++;
          if (i >= photos.length) return;
          var photo = photos[i];
          if (!photo.isLikelyFullSize) {
            photo = await _extractor.fetchFullSize(
              photo,
              cookieHeader: cookie,
            );
            if (!photo.isLikelyFullSize) small++;
          }
          final name = 'anh_${(i + 1).toString().padLeft(3, '0')}.jpg';
          try {
            final r = await _downloader.download(
              photo.url,
              fileName: name,
              preferredDir: target,
              onProgress: (_) {},
            );
            ok++;
            _firstSavedFile ??= r.file.path;
          } catch (e) {
            errors.add(
              'Ảnh ${i + 1}: ${e.toString().replaceFirst('Exception: ', '')}',
            );
          }
          if (mounted) setState(() => _done++);
        }
      }

      // Tải song song 3 ảnh một lúc.
      await Future.wait([worker(), worker(), worker()]);
      if (!mounted) return;

      final parts = <String>[
        'Đã tải $ok/${photos.length} ảnh.',
      ];
      if (resolved.usedPrivateFallback) {
        parts.add('Không ghi được vào thư mục đã chọn/Downloads, đã lưu vào '
            'thư mục riêng của app.');
      } else if (resolved.usedFallback) {
        parts.add('Thư mục đã chọn không dùng được, đã lưu vào Downloads.');
      }
      if (small > 0) {
        parts.add('$small ảnh chỉ lấy được bản nhỏ (Facebook không trả bản '
            'gốc).');
      }
      if (errors.isNotEmpty) {
        parts.add('Lỗi ${errors.length} ảnh: ${errors.take(3).join('; ')}'
            '${errors.length > 3 ? '...' : ''}');
      }
      setState(() {
        _stage = ok > 0 ? _Stage.done : _Stage.error;
        _savedDir = ok > 0 ? target.path : null;
        _status = parts.join(' ');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.error;
        _status =
            'Tải thất bại: ${e.toString().replaceFirst('Exception: ', '')}';
      });
    }
  }

  Future<void> _openFirst() async {
    final path = _firstSavedFile;
    if (path == null) return;
    await OpenFile.open(path);
  }

  void _onSaveFolderChanged(String? path) {}

  @override
  Widget build(BuildContext context) {
    final busy = _stage == _Stage.fetching || _stage == _Stage.downloading;
    final info = _info;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: _isLoggedIn
                  ? const Row(
                      children: [
                        Icon(Icons.check_circle, color: Colors.green),
                        SizedBox(width: 8),
                        Expanded(child: Text('Đã đăng nhập Facebook')),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Nên đăng nhập Facebook để lấy được đủ ảnh '
                          '(bài không công khai bắt buộc đăng nhập).',
                          style: TextStyle(fontSize: 14),
                        ),
                        const SizedBox(height: 8),
                        GradientButton(
                          onPressed: busy ? null : _openLogin,
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
            onSubmitted: (_) => busy ? null : _fetch(),
            decoration: InputDecoration(
              labelText: 'Dán link album / bài viết Facebook',
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
            onPressed: busy ? null : _fetch,
            icon: Icons.search,
            label: 'Lấy ảnh',
          ),
          const SizedBox(height: 16),
          if (_stage == _Stage.fetching)
            const Center(child: CircularProgressIndicator()),
          if (info != null) _buildGrid(info, busy),
          if (_stage == _Stage.downloading) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(
              value: _total > 0 ? _done / _total : null,
            ),
            const SizedBox(height: 8),
            Text(
              'Đang tải $_done/$_total ảnh...',
              textAlign: TextAlign.center,
            ),
          ],
          if (_stage == _Stage.done && _firstSavedFile != null) ...[
            const SizedBox(height: 16),
            GradientButton(
              onPressed: _openFirst,
              icon: Icons.image,
              label: 'Mở ảnh đầu tiên',
            ),
            if (_savedDir != null) ...[
              const SizedBox(height: 8),
              Text(
                'Đã lưu vào thư mục: $_savedDir',
                style: const TextStyle(fontSize: 12, color: NeonColors.muted),
              ),
            ],
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

  Widget _buildGrid(AlbumInfo info, bool busy) {
    final allSelected = _selected.length == info.photos.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Đã chọn: ${_selected.length}/${info.photos.length} ảnh',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            TextButton(
              onPressed: busy
                  ? null
                  : () => setState(() {
                        if (allSelected) {
                          _selected.clear();
                        } else {
                          _selected.addAll(info.photos.map((p) => p.id));
                        }
                      }),
              child: Text(allSelected ? 'Bỏ chọn tất cả' : 'Chọn tất cả'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: info.photos.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
          ),
          itemBuilder: (context, i) {
            final p = info.photos[i];
            final on = _selected.contains(p.id);
            return GestureDetector(
              onTap: busy
                  ? null
                  : () => setState(() {
                        if (on) {
                          _selected.remove(p.id);
                        } else {
                          _selected.add(p.id);
                        }
                      }),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.network(
                      p.thumbUrl,
                      fit: BoxFit.cover,
                      cacheWidth: 300,
                      errorBuilder: (_, _, _) => Container(
                        color: Colors.black26,
                        child: const Icon(Icons.broken_image),
                      ),
                    ),
                  ),
                  if (on)
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.cyanAccent, width: 3),
                      ),
                    ),
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Icon(
                      on ? Icons.check_circle : Icons.radio_button_unchecked,
                      color: on ? Colors.cyanAccent : Colors.white70,
                      size: 22,
                    ),
                  ),
                  Positioned(
                    left: 4,
                    bottom: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      color: Colors.black54,
                      child: Text(
                        '${i + 1}',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 12),
        GradientButton(
          onPressed: busy || _selected.isEmpty ? null : _download,
          icon: Icons.download,
          label: 'Tải xuống (${_selected.length})',
        ),
      ],
    );
  }
}

/// Kết quả trang WebView dự phòng.
class _AlbumWebResult {
  const _AlbumWebResult({this.info, this.error});
  final AlbumInfo? info;
  final String? error;
}

/// Đường dự phòng: mở bài viết/album trong WebView (giao diện máy tính,
/// đã đăng nhập) và CHỈ lấy ảnh thuộc đúng bài/album:
/// - Trang về Bảng tin / đăng nhập -> dừng ngay, báo lỗi.
/// - Ưu tiên dữ liệu `all_subattachments` của bài.
/// - Không có thì chỉ lấy ảnh có link trỏ về đúng bộ ảnh (set=pcb./a.).
/// - Lưới ảnh bài viết chỉ hiện 4-5 ảnh ("+N") -> tự mở trang bộ ảnh
///   của bài để lấy nốt.
class _AlbumExtractPage extends StatefulWidget {
  const _AlbumExtractPage({required this.url});

  final String url;

  @override
  State<_AlbumExtractPage> createState() => _AlbumExtractPageState();
}

class _AlbumExtractPageState extends State<_AlbumExtractPage> {
  late final WebViewController _controller;
  final _extractor = FacebookAlbumExtractor();
  String _status = 'Đang mở bài viết...';
  bool _popped = false;
  bool _running = false;

  List<AlbumPhoto> _photos = const [];
  int? _declared;
  String? _title;
  bool _openedSetPage = false;
  bool _haveSubattachments = false;

  static const _maxRounds = 16;

  static String _js(bool withHtml) => '''
(function(withHtml){
  var links = [];
  document.querySelectorAll('a[href]').forEach(function(a){
    var h = a.href || '';
    if (h.indexOf('fbid=') < 0 && h.indexOf('/photos/') < 0) return;
    var img = a.querySelector('img');
    links.push({
      href: h,
      src: img ? (img.currentSrc || img.src || '') : '',
      w: img ? (img.naturalWidth || 0) : 0,
      h: img ? (img.naturalHeight || 0) : 0
    });
  });
  window.scrollBy(0, Math.round(window.innerHeight * 0.9));
  return JSON.stringify({
    url: location.href,
    links: links,
    html: withHtml ? document.documentElement.outerHTML : ''
  });
})($withHtml)
''';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // Giao diện máy tính: dữ liệu bài viết đầy đủ hơn bản m.facebook,
      // và link ảnh có set=pcb.<id bài> để lọc đúng bài.
      ..setUserAgent(FacebookAlbumExtractor.desktopUserAgent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) =>
              navigationDecisionFor(request.url),
          onPageFinished: (_) => _run(),
          onWebResourceError: (_) {},
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  void _pop([_AlbumWebResult? result]) {
    if (_popped) return;
    _popped = true;
    if (mounted) Navigator.of(context).pop(result);
  }

  void _finish() {
    if (_photos.isEmpty) {
      _pop(const _AlbumWebResult(
        error: 'Không tìm thấy ảnh của bài viết. Có thể bài riêng tư, cần '
            'đăng nhập, hoặc link không phải bài viết có ảnh.',
      ));
      return;
    }
    _pop(_AlbumWebResult(
      info: AlbumInfo(
        photos: _photos,
        pageUrl: widget.url,
        title: _title,
        declaredCount: _declared,
      ),
    ));
  }

  Future<void> _run() async {
    if (_running || _popped) return;
    _running = true;
    var stableRounds = 0;
    var lastCount = -1;
    try {
      for (var round = 0; round < _maxRounds; round++) {
        await Future.delayed(const Duration(milliseconds: 1500));
        if (_popped) return;
        final current = await _controller.currentUrl() ?? '';
        if (FacebookAlbumExtractor.isHomeOrFeedUrl(current)) {
          _pop(_AlbumWebResult(
            error: const AlbumFeedRedirectException().message,
          ));
          return;
        }
        if (FacebookAlbumExtractor.isLoginUrl(current)) {
          _pop(const _AlbumWebResult(
            error: 'Facebook yêu cầu đăng nhập để xem bài này. Bấm "Đăng '
                'nhập Facebook" rồi thử lại.',
          ));
          return;
        }
        if (FacebookAlbumExtractor.isShareLink(current)) {
          continue; // vẫn đang chuyển hướng
        }

        Map<String, dynamic>? data;
        try {
          final raw = await _controller.runJavaScriptReturningResult(
            _js(!_haveSubattachments),
          );
          data = _decode(raw);
        } catch (_) {}
        if (data == null) continue;

        final pageUrl = (data['url'] as String?) ?? current;
        if (FacebookAlbumExtractor.isHomeOrFeedUrl(pageUrl)) {
          _pop(_AlbumWebResult(
            error: const AlbumFeedRedirectException().message,
          ));
          return;
        }
        final links = ((data['links'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => m.cast<String, dynamic>())
            .toList();
        final html = (data['html'] as String?) ?? '';

        if (html.isNotEmpty) {
          _title ??= FacebookAlbumExtractor.titleFromHtml(html);
          final sub = _extractor.parseSubattachments(html);
          if (sub.photos.isNotEmpty) {
            _haveSubattachments = true;
            _declared = sub.count;
            _photos = FacebookAlbumExtractor.mergePhotos(_photos, sub.photos);
          }
        }
        final fromLinks =
            _extractor.photosFromDomLinks(links, pageUrl: pageUrl);
        if (fromLinks.isNotEmpty) {
          _photos = FacebookAlbumExtractor.mergePhotos(_photos, fromLinks);
        }
        // Bài 1 ảnh (không có lưới ảnh) -> og:image của bài.
        if (_photos.isEmpty &&
            html.isNotEmpty &&
            !FacebookAlbumExtractor.isAlbumUrl(pageUrl) &&
            round >= 2) {
          try {
            final single = _extractor.parseAlbumHtml(html, pageUrl: pageUrl);
            _photos = single.photos;
          } catch (_) {}
        }

        if (mounted) {
          setState(() => _status = 'Đã tìm thấy ${_photos.length} ảnh của bài...');
        }

        // Lưới ảnh bài viết chỉ hiện 4-5 ảnh -> mở trang bộ ảnh của bài.
        final target = FacebookAlbumExtractor.targetSetFor(links, pageUrl);
        final needMore = (_declared != null && _declared! > _photos.length) ||
            (!_haveSubattachments && _photos.length >= 4);
        if (!_openedSetPage &&
            target != null &&
            target.startsWith('pcb.') &&
            !FacebookAlbumExtractor.isAlbumUrl(pageUrl) &&
            needMore &&
            round >= 2) {
          _openedSetPage = true;
          stableRounds = 0;
          lastCount = -1;
          if (mounted) {
            setState(() => _status = 'Đang mở trang bộ ảnh của bài...');
          }
          await _controller.loadRequest(
            Uri.parse('https://www.facebook.com/media/set/?set=$target&type=3'),
          );
          continue;
        }

        if (_photos.length == lastCount) {
          stableRounds++;
        } else {
          stableRounds = 0;
          lastCount = _photos.length;
        }
        if (_photos.isNotEmpty && stableRounds >= 3) break;
      }
    } finally {
      _running = false;
    }
    _finish();
  }

  Map<String, dynamic>? _decode(Object raw) {
    dynamic current = raw;
    for (var i = 0; i < 3; i++) {
      if (current is Map<String, dynamic>) return current;
      if (current is Map) return current.cast<String, dynamic>();
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
    return current is Map ? current.cast<String, dynamic>() : null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Đang lấy ảnh'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Dừng',
          onPressed: _finish,
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
