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

  /// File ảnh đã tải của lần tải gần nhất, đúng thứ tự trong bài.
  List<String> _savedFiles = const [];

  // Tạo PDF
  bool _makingPdf = false;
  int _pdfDone = 0;
  int _pdfTotal = 0;
  String _pdfStatus = '';
  String? _pdfPath;
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
      MaterialPageRoute(builder: (_) => const FacebookLoginPage()),
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
        MaterialPageRoute(builder: (_) => _AlbumExtractPage(url: url, initial: info)),
      );
      if (!mounted) return;
      if (result?.info != null && result!.info!.photos.isNotEmpty) {
        info = result.info;
      } else {
        error = result?.error ?? error;
      }
    }

    // 4. Bỏ ảnh trùng theo nhận dạng TRƯỚC khi đếm còn thiếu bao nhiêu.
    var dupRemoved = 0;
    if (info != null && info.photos.isNotEmpty) {
      final unique = FacebookAlbumExtractor.dedupePhotos(info.photos);
      dupRemoved = info.photos.length - unique.length;
      info = _withPhotos(info, unique);
    }

    // 5. Còn thiếu ảnh (vd 24/42): duyệt trình xem ảnh của bài — mở ảnh
    // đầu, bấm "ảnh tiếp theo" lần lượt đến hết. Thử qua mạng trước
    // (nhanh, không hiện gì), không đủ thì duyệt trong WebView.
    // Chưa đăng nhập: Facebook chặn trình xem ảnh bằng khung "Xem thêm
    // trên Facebook" -> không duyệt (vô ích), báo người dùng đăng nhập.
    bool stillMissing(AlbumInfo? i) =>
        cookie != null &&
        i != null &&
        i.photos.isNotEmpty &&
        i.setId != null &&
        (i.declaredCount ?? 0) > i.photos.length + dupRemoved;
    String? startIdOf(AlbumInfo i) {
      for (final p in i.photos) {
        if (RegExp(r'^\d+$').hasMatch(p.id)) return p.id;
      }
      return null;
    }

    if (stillMissing(info)) {
      final have = info!;
      final declared = have.declaredCount!;
      final startId = startIdOf(have);
      if (startId != null) {
        _setStatus('Đang duyệt từng ảnh của bài '
            '(${have.photos.length}/$declared)...');
        try {
          final walked = await _extractor.walkPhotoSet(
            startId: startId,
            setId: have.setId!,
            maxCount: declared,
            cookieHeader: cookie,
            onProgress: (n) =>
                _setStatus('Đang duyệt từng ảnh của bài... $n/$declared'),
          );
          if (!mounted) return;
          info = _withPhotos(
            have,
            FacebookAlbumExtractor.mergePhotos(have.photos, walked),
          );
        } catch (_) {}
      }
    }

    if (stillMissing(info)) {
      final have = info!;
      final startId = startIdOf(have);
      if (startId != null) {
        _setStatus('Đang mở trình xem ảnh để lấy nốt...');
        final walked = await Navigator.of(context).push<List<AlbumPhoto>>(
          MaterialPageRoute(
            builder: (_) => _PhotoWalkPage(
              setId: have.setId!,
              startId: startId,
              maxCount: have.declaredCount!,
            ),
          ),
        );
        if (!mounted) return;
        if (walked != null && walked.isNotEmpty) {
          info = _withPhotos(
            have,
            FacebookAlbumExtractor.mergePhotos(have.photos, walked),
          );
        }
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

    // 5. Bỏ ảnh trùng: cùng khoá nhận dạng (id/tên file), rồi so "vân
    // tay" hình ảnh của ảnh nhỏ — 2 ảnh nhìn giống hệt nhau chỉ giữ 1.
    var unique = FacebookAlbumExtractor.dedupePhotos(info.photos);
    var removed = info.photos.length - unique.length;
    if (unique.length > 1) {
      _setStatus('Đang kiểm tra ảnh trùng...');
      final visual = await _removeVisualDuplicates(unique);
      if (!mounted) return;
      removed += unique.length - visual.length;
      unique = visual;
    }
    final found = AlbumInfo(
      photos: unique,
      pageUrl: info.pageUrl,
      title: info.title,
      declaredCount: info.declaredCount,
      setId: info.setId,
    );
    removed += dupRemoved;
    final removedNote = removed > 0 ? ' Đã bỏ $removed ảnh trùng nhau.' : '';
    setState(() {
      _info = found;
      _selected
        ..clear()
        ..addAll(found.photos.map((p) => p.id));
      _stage = _Stage.found;
      final declared = found.declaredCount;
      final missing = (declared ?? 0) - found.photos.length - removed;
      _status = declared != null && missing > 0 && !_isLoggedIn
          ? 'Tìm thấy ${found.photos.length}/$declared ảnh. Bạn CHƯA ĐĂNG '
              'NHẬP Facebook nên Facebook chỉ cho xem bấy nhiêu ảnh. Bấm '
              '"Đăng nhập Facebook" ở trên, đăng nhập xong bấm "Lấy ảnh" '
              'lại để lấy đủ $declared ảnh.'
          : declared != null && missing > 0
          ? 'Tìm thấy ${found.photos.length}/$declared ảnh của bài viết. '
              'Còn $missing ảnh chưa lấy được: bấm '
              '"Lấy ảnh" lần nữa, hoặc dán link 1 ảnh trong bài (bấm ảnh → '
              '"..." → Sao chép liên kết).'
          : 'Tìm thấy ${found.photos.length} ảnh của bài viết.';
      _status += removedNote;
    });
  }

  AlbumInfo _withPhotos(AlbumInfo i, List<AlbumPhoto> photos) => AlbumInfo(
        photos: photos,
        pageUrl: i.pageUrl,
        title: i.title,
        declaredCount: i.declaredCount,
        setId: i.setId,
      );

  /// Tải ảnh nhỏ của từng ảnh, tính "vân tay" (dHash 16x16 = 256 bit)
  /// rồi bỏ ảnh nhìn giống hệt 1 ảnh đứng trước nó. Ảnh tải lỗi / không
  /// đọc được thì GIỮ LẠI (không bỏ nhầm).
  Future<List<AlbumPhoto>> _removeVisualDuplicates(
    List<AlbumPhoto> photos,
  ) async {
    final hashes = List<List<int>?>.filled(photos.length, null);
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= photos.length) return;
        hashes[i] = await _imageHash(photos[i].thumbUrl);
      }
    }

    await Future.wait([worker(), worker(), worker(), worker()]);
    final out = <AlbumPhoto>[];
    final kept = <List<int>>[];
    for (var i = 0; i < photos.length; i++) {
      final h = hashes[i];
      if (h != null &&
          kept.any((k) => FacebookAlbumExtractor.hammingDistance(h, k) <= 10)) {
        continue; // giống hệt 1 ảnh đã giữ -> bỏ
      }
      out.add(photos[i]);
      if (h != null) kept.add(h);
    }
    return out;
  }

  Future<List<int>?> _imageHash(String url) async {
    try {
      final res = await http.get(
        Uri.parse(url),
        headers: const {
          'User-Agent': FacebookAlbumExtractor.desktopUserAgent,
        },
      ).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return null;
      const w = 17, h = 16;
      final codec = await ui.instantiateImageCodec(
        res.bodyBytes,
        targetWidth: w,
        targetHeight: h,
      );
      final frame = await codec.getNextFrame();
      final data =
          await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      frame.image.dispose();
      codec.dispose();
      if (data == null || data.lengthInBytes < w * h * 4) return null;
      final gray = List<int>.generate(w * h, (i) {
        final o = i * 4;
        return (data.getUint8(o) * 299 +
                data.getUint8(o + 1) * 587 +
                data.getUint8(o + 2) * 114) ~/
            1000;
      });
      return FacebookAlbumExtractor.dHashFromGray(gray, w, h);
    } catch (_) {
      return null;
    }
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
      _savedFiles = const [];
      _pdfPath = null;
      _pdfStatus = '';
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
      final savedByIndex = List<String?>.filled(photos.length, null);

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
            savedByIndex[i] = r.file.path;
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
        _savedFiles = savedByIndex.whereType<String>().toList();
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

  /// Đọc 1 file ảnh thành dữ liệu trang PDF: JPEG giữ nguyên byte,
  /// định dạng khác giải mã ra điểm ảnh rồi nén không mất dữ liệu.
  Future<PdfImageData?> _loadPdfImage(String path) async {
    final bytes = await File(path).readAsBytes();
    final jpeg = jpegToPdfImage(bytes);
    if (jpeg != null) return jpeg;
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final w = image.width;
    final h = image.height;
    image.dispose();
    codec.dispose();
    if (data == null) return null;
    return rgbaToPdfImage(data.buffer.asUint8List(), w, h);
  }

  /// Ghép [paths] (đúng thứ tự) thành 1 file PDF trong [outDir].
  Future<void> _makePdf(
    List<String> paths,
    Directory outDir,
    String baseName,
  ) async {
    if (paths.isEmpty || _makingPdf) return;
    setState(() {
      _makingPdf = true;
      _pdfDone = 0;
      _pdfTotal = paths.length;
      _pdfPath = null;
      _pdfStatus = 'Đang tạo PDF...';
    });
    try {
      var base = sanitizeSongTitle(baseName);
      if (base.isEmpty) base = 'Album';
      final name = uniqueFileName(
        outDir.path,
        '$base.pdf',
        exists: (p) => File(p).existsSync(),
      );
      final outPath = '${outDir.path}/$name';
      final pages = await writeImagesPdf(
        outPath: outPath,
        pageCount: paths.length,
        loadPage: (i) => _loadPdfImage(paths[i]),
        onProgress: (d) {
          if (mounted) setState(() => _pdfDone = d);
        },
      );
      if (!mounted) return;
      setState(() {
        if (pages == 0) {
          _pdfStatus = 'Không tạo được PDF: không đọc được ảnh nào.';
        } else {
          _pdfPath = outPath;
          final skipped = paths.length - pages;
          _pdfStatus = 'Đã tạo PDF $pages trang: $outPath'
              '${skipped > 0 ? ' (bỏ qua $skipped ảnh không đọc được)' : ''}';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _pdfStatus =
            'Tạo PDF thất bại: ${e.toString().replaceFirst('Exception: ', '')}';
      });
    } finally {
      if (mounted) setState(() => _makingPdf = false);
    }
  }

  /// PDF từ ảnh vừa tải (lưu cùng thư mục, tên = tên thư mục).
  Future<void> _pdfFromDownloaded() async {
    final dir = _savedDir;
    if (dir == null || _savedFiles.isEmpty) return;
    final folderName = dir.split('/').where((s) => s.isNotEmpty).last;
    await _makePdf(_savedFiles, Directory(dir), folderName);
  }

  Future<void> _openPdf() async {
    final path = _pdfPath;
    if (path == null) return;
    await OpenFile.open(path);
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
            if (_savedFiles.isNotEmpty) ...[
              const SizedBox(height: 12),
              GradientButton(
                onPressed: _makingPdf ? null : _pdfFromDownloaded,
                icon: Icons.picture_as_pdf,
                label: 'Tạo file PDF (${_savedFiles.length} ảnh)',
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
          const SizedBox(height: 20),
          _buildPdfCard(busy),
        ],
      ),
    );
  }

  /// Khu "Chuyển ảnh thành PDF": tiến độ, nút mở PDF, nút chọn ảnh máy.
  /// Tiến độ / kết quả của nút "Tạo file PDF" (PDF từ ảnh vừa tải).
  /// Chọn ảnh trong máy -> PDF đã chuyển sang tab "PDF" riêng.
  Widget _buildPdfCard(bool busy) {
    if (!_makingPdf && _pdfPath == null && _pdfStatus.isEmpty) {
      return const SizedBox.shrink();
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Row(
              children: [
                Icon(Icons.picture_as_pdf),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'PDF từ ảnh vừa tải',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            if (_makingPdf) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: _pdfTotal > 0 ? _pdfDone / _pdfTotal : null,
              ),
              const SizedBox(height: 6),
              Text(
                'Đang tạo PDF $_pdfDone/$_pdfTotal trang...',
                textAlign: TextAlign.center,
              ),
            ],
            if (_pdfPath != null && !_makingPdf) ...[
              const SizedBox(height: 12),
              GradientButton(
                onPressed: _openPdf,
                icon: Icons.open_in_new,
                label: 'Mở file PDF',
              ),
            ],
            if (_pdfStatus.isNotEmpty && !_makingPdf) ...[
              const SizedBox(height: 8),
              Text(
                _pdfStatus,
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ],
        ),
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
  const _AlbumExtractPage({required this.url, this.initial});

  final String url;

  /// Ảnh đã có sẵn (lấy qua mạng) — trang này chỉ lấy thêm ảnh còn thiếu.
  final AlbumInfo? initial;

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

  int get _maxRounds => widget.initial != null ? 45 : 16;

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
    final init = widget.initial;
    if (init != null) {
      _photos = init.photos;
      _declared = init.declaredCount;
      _title = init.title;
      _haveSubattachments = true; // đã có dữ liệu bài, chỉ cần quét lưới
      _openedSetPage = FacebookAlbumExtractor.isAlbumUrl(widget.url);
      _status = 'Đang lấy thêm ảnh (${init.photos.length}/'
          '${init.declaredCount ?? '?'})...';
    }
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
        pageUrl: widget.initial?.pageUrl ?? widget.url,
        title: _title,
        declaredCount: _declared,
        setId: widget.initial?.setId,
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
          setState(() => _status = _declared != null
              ? 'Đã tìm thấy ${_photos.length}/$_declared ảnh của bài...'
              : 'Đã tìm thấy ${_photos.length} ảnh của bài...');
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
        if (_declared != null && _photos.length >= _declared!) break;
        final patience = widget.initial != null ? 6 : 3;
        if (_photos.isNotEmpty && stableRounds >= patience) break;
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

/// Duyệt trình xem ảnh của bài trong WebView: mở ảnh đầu của bộ ảnh
/// (`set=pcb.<id bài>`), đọc ảnh đang hiện, bấm "ảnh tiếp theo", lặp lại
/// đến khi quay về ảnh đã gặp / đủ số ảnh / không chuyển được nữa.
/// Mỗi ảnh chỉ nhận khi tên file ảnh khớp fbid trên thanh địa chỉ.
class _PhotoWalkPage extends StatefulWidget {
  const _PhotoWalkPage({
    required this.setId,
    required this.startId,
    required this.maxCount,
  });

  final String setId;
  final String startId;
  final int maxCount;

  @override
  State<_PhotoWalkPage> createState() => _PhotoWalkPageState();
}

class _PhotoWalkPageState extends State<_PhotoWalkPage> {
  late final WebViewController _controller;
  final List<AlbumPhoto> _found = [];
  final Set<String> _visited = {};
  final Set<String> _acceptedKeys = {};
  bool _running = false;
  bool _popped = false;
  String _status = 'Đang mở trình xem ảnh...';

  static const _readJs = r"""
(function(){
  var best = null, area = 0;
  document.querySelectorAll('img').forEach(function(im){
    var s = im.currentSrc || im.src || '';
    if (s.indexOf('fbcdn') < 0 && s.indexOf('scontent') < 0) return;
    var w = im.naturalWidth || 0, h = im.naturalHeight || 0;
    if (w * h > area) { area = w * h; best = {src: s, w: w, h: h}; }
  });
  return JSON.stringify({url: location.href, img: best});
})()
""";

  static const _nextJs = r"""
(function(){
  var labels = ['Next photo', 'Ảnh tiếp theo', 'Ảnh tiếp', 'Next', 'Tiếp'];
  for (var i = 0; i < labels.length; i++) {
    var b = document.querySelector('[aria-label="' + labels[i] + '"]');
    if (b) { b.click(); return 'click'; }
  }
  var all = document.querySelectorAll('[aria-label]');
  for (var j = 0; j < all.length; j++) {
    var l = (all[j].getAttribute('aria-label') || '').toLowerCase();
    if ((l.indexOf('next') >= 0 || l.indexOf('tiếp') >= 0) &&
        l.indexOf('story') < 0 && l.indexOf('tin') !== 0) {
      all[j].click(); return 'click2';
    }
  }
  var ev = {key: 'ArrowRight', code: 'ArrowRight', keyCode: 39, which: 39, bubbles: true};
  document.dispatchEvent(new KeyboardEvent('keydown', ev));
  (document.activeElement || document.body).dispatchEvent(new KeyboardEvent('keydown', ev));
  return 'key';
})()
""";

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(FacebookAlbumExtractor.desktopUserAgent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) =>
              navigationDecisionFor(request.url),
          onPageFinished: (_) => _run(),
          onWebResourceError: (_) {},
        ),
      )
      ..loadRequest(Uri.parse(
        'https://www.facebook.com/photo/?fbid=${widget.startId}'
        '&set=${widget.setId}',
      ));
  }

  void _pop() {
    if (_popped) return;
    _popped = true;
    if (mounted) Navigator.of(context).pop(List<AlbumPhoto>.of(_found));
  }

  Map<String, dynamic>? _decode(Object raw) {
    dynamic current = raw;
    for (var i = 0; i < 3; i++) {
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

  Future<void> _run() async {
    if (_running || _popped) return;
    _running = true;
    String? lastId;
    var stuck = 0;
    try {
      final maxTicks = widget.maxCount * 4 + 20;
      for (var tick = 0; tick < maxTicks; tick++) {
        await Future.delayed(const Duration(milliseconds: 1300));
        if (_popped) return;
        final current = await _controller.currentUrl() ?? '';
        if (FacebookAlbumExtractor.isHomeOrFeedUrl(current) ||
            FacebookAlbumExtractor.isLoginUrl(current)) {
          break;
        }
        Map<String, dynamic>? data;
        try {
          data = _decode(
            await _controller.runJavaScriptReturningResult(_readJs),
          );
        } catch (_) {}
        final pageUrl = (data?['url'] as String?) ?? current;
        final id = FacebookAlbumExtractor.photoIdFromUrl(pageUrl);
        final img = data?['img'];

        if (id != null && id != lastId && _visited.contains(id)) {
          break; // đã quay về ảnh đã duyệt -> hết bộ ảnh
        }
        if (id != null && img is Map && !_visited.contains(id)) {
          final src = img['src']?.toString() ?? '';
          final w = img['w'];
          final h = img['h'];
          final area = (w is num ? w.toInt() : 0) * (h is num ? h.toInt() : 0);
          final key = FacebookAlbumExtractor.photoKey(src);
          // Nhận ảnh khi: thanh địa chỉ đã sang ảnh mới VÀ ảnh lớn đang hiện
          // cũng đã đổi (khác mọi ảnh đã nhận) — nếu ảnh chưa đổi kịp thì
          // đợi lượt sau. Bỏ qua ảnh nhỏ (avatar, icon).
          if (src.startsWith('http') &&
              FacebookAlbumExtractor.isContentPhotoUrl(src) &&
              !_acceptedKeys.contains(key) &&
              area >= 250 * 250) {
            _visited.add(id);
            _acceptedKeys.add(key);
            _found.add(AlbumPhoto(
              id: id,
              url: src,
              thumbUrl: src,
              width: w is num ? w.toInt() : 0,
              height: h is num ? h.toInt() : 0,
            ));
            if (mounted) {
              setState(() => _status =
                  'Đã duyệt ${_found.length}/${widget.maxCount} ảnh...');
            }
          }
        }
        if (_found.length >= widget.maxCount) break;

        if (id == lastId) {
          stuck++;
          // không chuyển sang ảnh tiếp được nữa (lần đầu chờ trang tải lâu hơn)
          if (stuck >= (_found.isEmpty ? 15 : 8)) break;
        } else {
          stuck = 0;
          lastId = id;
        }
        // Chỉ bấm "tiếp" khi đã lấy được ảnh hiện tại.
        if (id != null && _visited.contains(id)) {
          try {
            await _controller.runJavaScript(_nextJs);
          } catch (_) {}
        }
      }
    } finally {
      _running = false;
    }
    _pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Đang duyệt ảnh'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Dừng',
          onPressed: _pop,
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
