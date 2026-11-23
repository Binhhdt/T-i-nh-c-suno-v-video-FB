import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../neon_theme.dart';
import '../save_folder.dart';
import '../save_folder_card.dart';
import '../suno_filename.dart';
import 'cbz_writer.dart';
import 'comic_downloader.dart';
import 'comic_log.dart';
import 'comic_models.dart';
import 'comic_scan_page.dart';

/// Tab "Truyện": tải ảnh trang của 1 chapter từ URL người dùng nhập, trên
/// trang mà người dùng có quyền tải. Quét bằng trình duyệt thật
/// (WebView), tải ảnh theo thứ tự 001, 002..., xuất thư mục ảnh / CBZ.
class ComicTab extends StatefulWidget {
  const ComicTab({super.key});

  @override
  State<ComicTab> createState() => _ComicTabState();
}

class _ComicTabState extends State<ComicTab>
    with AutomaticKeepAliveClientMixin {
  /// Giữ tab sống khi chuyển sang tab khác -> tải dở không bị huỷ.
  @override
  bool get wantKeepAlive => true;

  final _urlController = TextEditingController();
  final _log = ComicLog();
  final _downloader = ComicDownloader();

  bool _desktop = false;
  ExportMode _mode = ExportMode.folder;
  ScanResult? _scan;

  bool _downloading = false;
  bool _cancel = false;
  int _done = 0;
  int _total = 0;
  int _ok = 0;
  int _skipped = 0;
  int _failed = 0;

  String _status = '';
  bool _statusIsError = false;
  String? _outDir;
  String? _cbzPath;
  String? _firstFile;

  // Tải nhiều chapter
  final Set<String> _selectedChapters = {};
  final _fromCtl = TextEditingController();
  final _toCtl = TextEditingController();
  int _batchTotal = 0;
  int _batchIndex = 0;
  String _batchLabel = '';
  int _chapOk = 0;
  int _chapFail = 0;

  @override
  void initState() {
    super.initState();
    _log.onChanged = () {
      if (mounted) setState(() {});
    };
  }

  @override
  void dispose() {
    _log.onChanged = null;
    _urlController.dispose();
    _fromCtl.dispose();
    _toCtl.dispose();
    super.dispose();
  }

  void _setStatus(String s, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _status = s;
      _statusIsError = error;
    });
  }

  String? _normalizeUrl(String raw) {
    var u = raw.trim();
    final found = RegExp(r'https?://\S+').firstMatch(u);
    if (found != null) u = found.group(0)!;
    if (u.isEmpty) return null;
    if (!u.startsWith('http://') && !u.startsWith('https://')) u = 'https://$u';
    final uri = Uri.tryParse(u);
    if (uri == null || uri.host.isEmpty) return null;
    return uri.toString();
  }

  Future<void> _startScan() async {
    FocusScope.of(context).unfocus();
    final url = _normalizeUrl(_urlController.text);
    if (url == null) {
      _setStatus('Link chapter không hợp lệ.', error: true);
      return;
    }
    setState(() {
      _scan = null;
      _selectedChapters.clear();
      _batchTotal = 0;
      _outDir = null;
      _cbzPath = null;
      _firstFile = null;
      _done = _total = _ok = _skipped = _failed = 0;
    });
    _log.clear();
    _log.info('Quét: $url${_desktop ? ' (giao diện máy tính)' : ''}');
    _setStatus('Đang mở trang trong trình duyệt...');
    final result = await Navigator.of(context).push<ScanResult>(
      MaterialPageRoute(
        builder: (_) => ComicScanPage(url: url, desktop: _desktop),
      ),
    );
    if (!mounted) return;
    if (result == null) {
      _log.warn('Đã đóng trang quét, không có kết quả.');
      _setStatus('Chưa quét được trang nào.', error: true);
      return;
    }
    _log.addAll(result.log);
    setState(() => _scan = result);
    final listing = _isListing(result);
    _setStatus(
      listing
          ? 'Trang giới thiệu bộ truyện: ${result.chapters.length} chapter. '
              'Tích chọn chapter rồi bấm tải.'
          : 'Tìm thấy ${result.images.length} trang — nguồn: '
              '${result.chosenSource}.'
              '${result.warning != null ? ' Xem cảnh báo bên trên.' : ''}',
      error: !listing && result.warning != null,
    );
  }

  /// Trang giới thiệu bộ truyện: có danh sách chapter và ảnh tìm được là
  /// ảnh bìa (cảnh báo) hoặc không có ảnh trang nào.
  bool _isListing(ScanResult r) =>
      r.chapters.isNotEmpty &&
      (r.images.isEmpty || (r.warning?.contains('GIỚI THIỆU') ?? false));

  /// Băm FNV-1a 32 bit -> 6 ký tự hex: phân biệt chapter cùng tiêu đề,
  /// và quét lại cùng link thì ra cùng thư mục (để bỏ qua file đã có).
  String _hash6(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0').substring(0, 6);
  }

  Future<void> _ensurePermission() async {
    if (!Platform.isAndroid) return;
    try {
      final s = await Permission.storage.request();
      if (s.isGranted || s.isLimited) return;
      await Permission.photos.request();
    } catch (_) {}
  }

  /// Cookie của trình duyệt cho từng host ảnh (giống trình duyệt gửi khi
  /// tự tải ảnh). Không lưu ra đâu cả.
  Future<Map<String, String>> _cookiesFor(Iterable<String> hosts) async {
    final out = <String, String>{};
    for (final h in hosts) {
      try {
        final cookies = await WebViewCookieManager().getCookies(
          domain: Uri.parse('https://$h'),
        );
        final header = cookies
            .where((c) => c.name.isNotEmpty)
            .map((c) => '${c.name}=${c.value}')
            .join('; ');
        if (header.isNotEmpty) out[h] = header;
      } catch (_) {}
    }
    return out;
  }

  /// Tên thư mục an toàn từ tiêu đề + mã băm của link (ổn định).
  String _folderName(String title, String url, {String fallback = 'Chapter'}) {
    var t = sanitizeSongTitle(title).replaceAll('.', ' ').trim();
    if (t.length > 60) t = t.substring(0, 60).trim();
    if (t.isEmpty) t = fallback;
    return '$t (${_hash6(url)})';
  }

  /// Tải ảnh của 1 chapter đã quét vào [parent] (+ CBZ nếu chọn).
  /// Dùng chung cho tải 1 chapter và tải nhiều chapter.
  Future<({DownloadReport report, Directory imgDir, String? cbzPath})>
      _downloadScan(
    ScanResult scan, {
    required Directory parent,
    String? titleHint,
  }) async {
    final folderName = _folderName(
      (titleHint == null || titleHint.isEmpty) ? scan.title : titleHint,
      scan.pageUrl,
      fallback: Uri.tryParse(scan.pageUrl)?.host ?? 'Chapter',
    );
    // CBZ-only: ảnh để trong bộ nhớ đệm của app (vẫn bỏ qua file đã có
    // khi tải lại), chỉ file .cbz nằm ở thư mục lưu.
    final Directory imgDir;
    if (_mode == ExportMode.cbz) {
      final cache = await getTemporaryDirectory();
      imgDir = Directory('${cache.path}/comic/${_hash6(scan.pageUrl)}');
    } else {
      imgDir = Directory('${parent.path}/$folderName');
    }
    _log.info('Lưu ảnh vào: ${imgDir.path}');

    final hosts = scan.images
        .map((e) => Uri.tryParse(e.url)?.host ?? '')
        .where((h) => h.isNotEmpty)
        .toSet();
    final cookies = await _cookiesFor(hosts);

    if (mounted) {
      setState(() {
        _done = 0;
        _total = scan.images.length;
        _ok = _skipped = _failed = 0;
      });
    }
    final report = await _downloader.downloadAll(
      images: scan.images,
      dir: imgDir,
      referer: scan.pageUrl,
      userAgent: scan.userAgent,
      log: _log,
      cookiesByHost: cookies,
      isCancelled: () => _cancel,
      onProgress: (done, total, last) {
        if (!mounted) return;
        setState(() {
          _done = done;
          if (last.state == PageState.done) _ok++;
          if (last.state == PageState.skipped) _skipped++;
          if (last.state == PageState.failed) _failed++;
        });
      },
    );

    final files = report.filesInOrder;
    String? cbzPath;
    if (_mode != ExportMode.folder && files.isNotEmpty) {
      cbzPath = '${parent.path}/$folderName.cbz';
      if (report.failed > 0) {
        _log.warn('CBZ sẽ thiếu ${report.failed} trang bị lỗi.');
      }
      try {
        await parent.create(recursive: true);
        await CbzWriter.write(
          cbzPath,
          [for (final f in files) File(f)],
          title: (titleHint == null || titleHint.isEmpty) ? scan.title : titleHint,
          sourceUrl: scan.pageUrl,
        );
        _log.info('Đã tạo CBZ: $cbzPath (${files.length} trang)');
      } catch (e) {
        _log.error('Tạo CBZ thất bại: $e');
        cbzPath = null;
      }
    }
    // Ghi log cạnh kết quả.
    if (_mode == ExportMode.cbz) {
      await _log.saveTo('${parent.path}/$folderName.log.txt');
    } else {
      await _log.saveTo('${imgDir.path}/_log.txt');
    }
    return (report: report, imgDir: imgDir, cbzPath: cbzPath);
  }

  void _logSaveDir(ResolvedSaveDir resolved) {
    if (resolved.usedPrivateFallback) {
      _log.warn('Không ghi được vào thư mục đã chọn/Downloads -> dùng thư '
          'mục riêng của app.');
    } else if (resolved.usedFallback) {
      _log.warn('Thư mục đã chọn không dùng được -> dùng Downloads.');
    }
  }

  /// Tải 1 chapter (trang đang quét).
  Future<void> _download() async {
    final scan = _scan;
    if (scan == null || scan.images.isEmpty || _downloading) return;
    await _ensurePermission();
    if (!mounted) return;
    setState(() {
      _downloading = true;
      _cancel = false;
      _batchTotal = 0;
      _outDir = null;
      _cbzPath = null;
      _firstFile = null;
    });
    _setStatus('Đang tải ${scan.images.length} trang...');
    try {
      final resolved = await resolveUserVisibleSaveDir();
      _logSaveDir(resolved);
      final r = await _downloadScan(scan, parent: resolved.dir);
      if (!mounted) return;
      final report = r.report;
      final files = report.filesInOrder;
      final parts = <String>[
        'Tải mới ${report.ok}, bỏ qua (đã có) ${report.skipped}, '
            'lỗi ${report.failed} / ${scan.images.length} trang.',
      ];
      if (report.failed > 0) {
        parts.add('Xem "Nhật ký" bên dưới để biết lý do từng trang lỗi.');
      }
      if (_mode != ExportMode.folder) {
        parts.add(r.cbzPath != null ? 'Đã tạo CBZ.' : 'Không tạo được CBZ.');
      }
      setState(() {
        _outDir = _mode == ExportMode.cbz ? null : r.imgDir.path;
        _cbzPath = r.cbzPath;
        _firstFile = files.isNotEmpty ? files.first : null;
      });
      _setStatus(parts.join(' '), error: files.isEmpty);
    } catch (e) {
      _log.error('Lỗi khi tải: $e');
      _setStatus('Tải thất bại: $e', error: true);
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  /// Tải NHIỀU chapter đã chọn từ trang giới thiệu: lần lượt mở từng
  /// chapter trong trình duyệt -> quét -> tải. Mỗi chapter 1 thư mục con
  /// trong thư mục bộ truyện. Nghỉ 1,5 giây giữa các chapter để không
  /// dồn request vào máy chủ. Chapter đã tải rồi thì file hợp lệ được bỏ
  /// qua (tải tiếp được khi bị ngắt giữa chừng).
  Future<void> _downloadChapters() async {
    final scan = _scan;
    if (scan == null || _downloading) return;
    final chosen = scan.chapters
        .where((c) => _selectedChapters.contains(c.url))
        .toList();
    if (chosen.isEmpty) return;
    await _ensurePermission();
    if (!mounted) return;
    setState(() {
      _downloading = true;
      _cancel = false;
      _batchTotal = chosen.length;
      _batchIndex = 0;
      _chapOk = _chapFail = 0;
      _outDir = null;
      _cbzPath = null;
      _firstFile = null;
    });
    final failedChaps = <String>[];
    try {
      final resolved = await resolveUserVisibleSaveDir();
      _logSaveDir(resolved);
      final seriesDir = Directory(
        '${resolved.dir.path}/${_folderName(scan.title, scan.pageUrl, fallback: 'Bo truyen')}',
      );
      await seriesDir.create(recursive: true);
      _log.info('Tải ${chosen.length} chapter vào: ${seriesDir.path}');

      for (var i = 0; i < chosen.length; i++) {
        if (_cancel || !mounted) break;
        final chap = chosen[i];
        setState(() {
          _batchIndex = i + 1;
          _batchLabel = chap.title;
          _done = _total = _ok = _skipped = _failed = 0;
        });
        _setStatus('Chapter ${i + 1}/${chosen.length}: đang quét "${chap.title}"...');
        _log.info('=== Chapter ${i + 1}/${chosen.length}: ${chap.title} — ${chap.url}');

        final result = await Navigator.of(context).push<ScanResult>(
          MaterialPageRoute(
            builder: (_) => ComicScanPage(
              url: chap.url,
              desktop: _desktop,
              batchLabel: 'Chap ${chap.numberLabel} (${i + 1}/${chosen.length})',
              giveUpAfter: const Duration(seconds: 120),
            ),
          ),
        );
        if (!mounted) return;
        if (result == null) {
          _log.error('${chap.title}: không quét được (quá 2 phút hoặc bị đóng) — bỏ qua');
          failedChaps.add(chap.title);
          setState(() => _chapFail++);
          if (_cancel) break;
          continue;
        }
        _log.addAll(result.log);
        if (result.images.isEmpty) {
          _log.error('${chap.title}: không tìm thấy ảnh trang truyện — bỏ qua');
          failedChaps.add(chap.title);
          setState(() => _chapFail++);
          continue;
        }
        if (result.warning != null && result.warning!.contains('GIỚI THIỆU')) {
          _log.error('${chap.title}: link mở ra trang giới thiệu, không phải '
              'chapter — bỏ qua');
          failedChaps.add(chap.title);
          setState(() => _chapFail++);
          continue;
        }
        _setStatus('Chapter ${i + 1}/${chosen.length}: đang tải '
            '${result.images.length} trang...');
        final r = await _downloadScan(
          result,
          parent: seriesDir,
          titleHint: chap.title,
        );
        if (!mounted) return;
        final rep = r.report;
        if (rep.filesInOrder.isEmpty) {
          failedChaps.add(chap.title);
          setState(() => _chapFail++);
        } else {
          setState(() {
            _chapOk++;
            _firstFile ??= rep.filesInOrder.first;
            _cbzPath = r.cbzPath ?? _cbzPath;
          });
          if (rep.failed > 0) {
            failedChaps.add('${chap.title} (thiếu ${rep.failed} trang)');
          }
        }
        // Nghỉ giữa các chapter.
        if (i < chosen.length - 1 && !_cancel) {
          await Future.delayed(const Duration(milliseconds: 1500));
        }
      }
      await _log.saveTo('${seriesDir.path}/_log.txt');
      if (!mounted) return;
      setState(() => _outDir = seriesDir.path);
      final parts = <String>[
        '${_cancel ? 'Đã dừng. ' : ''}Xong $_chapOk/${chosen.length} chapter.',
      ];
      if (failedChaps.isNotEmpty) {
        parts.add('Có vấn đề: ${failedChaps.take(5).join(', ')}'
            '${failedChaps.length > 5 ? '...' : ''} — xem Nhật ký. Bấm tải lại '
            'để thử tiếp (trang đã có sẽ được bỏ qua).');
      }
      _setStatus(parts.join(' '), error: _chapOk == 0);
    } catch (e) {
      _log.error('Lỗi khi tải nhiều chapter: $e');
      _setStatus('Tải thất bại: $e', error: true);
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  /// Chọn các chapter có số trong khoảng [from, to].
  void _selectRange() {
    final scan = _scan;
    if (scan == null) return;
    final from = double.tryParse(_fromCtl.text.trim().replaceAll(',', '.'));
    final to = double.tryParse(_toCtl.text.trim().replaceAll(',', '.'));
    if (from == null && to == null) return;
    final lo = from ?? double.negativeInfinity;
    final hi = to ?? double.infinity;
    setState(() {
      _selectedChapters
        ..clear()
        ..addAll(scan.chapters
            .where((c) => c.number != null && c.number! >= lo && c.number! <= hi)
            .map((c) => c.url));
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scan = _scan;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Card(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Chỉ dùng với trang bạn có quyền tải nội dung. App mở trang '
                'bằng trình duyệt như bạn tự xem — không vượt CAPTCHA, đăng '
                'nhập hay trả phí. Nếu trang cần xác nhận, bạn tự làm trong '
                'khung trình duyệt rồi bấm "Quét lại".',
                style: TextStyle(fontSize: 13, color: NeonColors.muted),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SaveFolderCard(onChanged: (_) {}),
          const SizedBox(height: 12),
          TextField(
            controller: _urlController,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _downloading ? null : _startScan(),
            decoration: InputDecoration(
              labelText: 'Dán link chapter',
              hintText: 'https://...',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(Icons.paste),
                tooltip: 'Dán từ bộ nhớ tạm',
                onPressed: () async {
                  final d = await Clipboard.getData(Clipboard.kTextPlain);
                  if (d?.text != null) _urlController.text = d!.text!;
                },
              ),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Mở bằng giao diện máy tính'),
            subtitle: const Text(
              'Bật nếu bản điện thoại của trang không hiện đủ ảnh',
              style: TextStyle(fontSize: 12),
            ),
            value: _desktop,
            onChanged: _downloading ? null : (v) => setState(() => _desktop = v),
          ),
          GradientButton(
            onPressed: _downloading ? null : _startScan,
            icon: Icons.travel_explore,
            label: 'Quét trang',
          ),
          if (scan != null) ...[
            const SizedBox(height: 16),
            Text(
              _isListing(scan)
                  ? 'Bộ truyện: ${scan.title.isEmpty ? scan.pageUrl : scan.title}'
                  : '${scan.images.length} trang — ${scan.title.isEmpty ? scan.pageUrl : scan.title}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            if (scan.warning != null) ...[
              const SizedBox(height: 8),
              Card(
                color: Colors.orange.withValues(alpha: 0.18),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.warning_amber, color: Colors.orange),
                      const SizedBox(width: 8),
                      Expanded(child: Text(scan.warning!)),
                    ],
                  ),
                ),
              ),
            ],
            if (!_isListing(scan) && scan.images.isNotEmpty) ...[
              const SizedBox(height: 8),
              _buildGrid(scan),
            ],
            const SizedBox(height: 12),
            const Text('Xuất ra:'),
            const SizedBox(height: 6),
            SegmentedButton<ExportMode>(
              segments: const [
                ButtonSegment(value: ExportMode.folder, label: Text('Thư mục ảnh')),
                ButtonSegment(value: ExportMode.cbz, label: Text('CBZ')),
                ButtonSegment(value: ExportMode.both, label: Text('Cả hai')),
              ],
              selected: {_mode},
              onSelectionChanged: _downloading
                  ? null
                  : (s) => setState(() => _mode = s.first),
            ),
            if (!_isListing(scan) && scan.images.isNotEmpty) ...[
              const SizedBox(height: 12),
              GradientButton(
                onPressed: _downloading ? null : _download,
                icon: Icons.download,
                label: 'Tải ${scan.images.length} trang',
              ),
            ],
            if (scan.chapters.isNotEmpty) ...[
              const SizedBox(height: 12),
              _buildChapterList(scan),
            ],
          ],
          if (_downloading) ...[
            const SizedBox(height: 16),
            if (_batchTotal > 0) ...[
              Text(
                'Chapter $_batchIndex/$_batchTotal: $_batchLabel',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              LinearProgressIndicator(
                value: _batchIndex > 0 ? (_batchIndex - 1) / _batchTotal : 0,
                minHeight: 6,
              ),
              const SizedBox(height: 4),
              Text(
                'Xong $_chapOk chapter, lỗi $_chapFail',
                style: const TextStyle(fontSize: 12, color: NeonColors.muted),
              ),
              const SizedBox(height: 10),
            ],
            LinearProgressIndicator(value: _total > 0 ? _done / _total : null),
            const SizedBox(height: 6),
            Text(
              'Trang: $_done/$_total — mới $_ok, đã có $_skipped, lỗi $_failed',
              textAlign: TextAlign.center,
            ),
            TextButton(
              onPressed: _cancel ? null : () => setState(() => _cancel = true),
              child: Text(_cancel ? 'Đang dừng...' : 'Dừng'),
            ),
          ],
          if (!_downloading && (_firstFile != null || _cbzPath != null)) ...[
            const SizedBox(height: 12),
            if (_firstFile != null && _mode != ExportMode.cbz)
              GradientButton(
                onPressed: () => OpenFile.open(_firstFile!),
                icon: Icons.image,
                label: 'Mở trang đầu',
              ),
            if (_cbzPath != null) ...[
              const SizedBox(height: 8),
              GradientButton(
                onPressed: () => OpenFile.open(_cbzPath!),
                icon: Icons.menu_book,
                label: 'Mở file CBZ',
              ),
            ],
            if (_outDir != null) ...[
              const SizedBox(height: 6),
              Text('${_batchTotal > 0 ? 'Thư mục bộ truyện' : 'Thư mục ảnh'}: $_outDir',
                  style: const TextStyle(fontSize: 12, color: NeonColors.muted)),
            ],
            if (_cbzPath != null) ...[
              const SizedBox(height: 4),
              Text('File CBZ: $_cbzPath',
                  style: const TextStyle(fontSize: 12, color: NeonColors.muted)),
            ],
          ],
          if (_status.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              _status,
              style: TextStyle(color: _statusIsError ? NeonColors.error : null),
            ),
          ],
          const SizedBox(height: 12),
          _buildLog(),
        ],
      ),
    );
  }

  Widget _buildChapterList(ScanResult scan) {
    final chapters = scan.chapters;
    final sel = chapters.where((c) => _selectedChapters.contains(c.url)).length;
    final busy = _downloading;
    return Card(
      child: ExpansionTile(
        initiallyExpanded: _isListing(scan),
        title: Text('Danh sách chapter (${chapters.length})'),
        subtitle: Text('Đã chọn $sel'),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [
          Row(
            children: [
              TextButton(
                onPressed: busy
                    ? null
                    : () => setState(() => _selectedChapters
                      ..clear()
                      ..addAll(chapters.map((c) => c.url))),
                child: const Text('Chọn tất cả'),
              ),
              TextButton(
                onPressed: busy ? null : () => setState(_selectedChapters.clear),
                child: const Text('Bỏ chọn'),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _fromCtl,
                  enabled: !busy,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Từ chap',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _toCtl,
                  enabled: !busy,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Đến chap',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: busy ? null : _selectRange,
                child: const Text('Chọn khoảng'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: chapters.length,
              itemBuilder: (_, i) {
                final c = chapters[i];
                final on = _selectedChapters.contains(c.url);
                return CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: on,
                  onChanged: busy
                      ? null
                      : (v) => setState(() {
                            if (v == true) {
                              _selectedChapters.add(c.url);
                            } else {
                              _selectedChapters.remove(c.url);
                            }
                          }),
                  title: Text(
                    c.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          GradientButton(
            onPressed: busy || sel == 0 ? null : _downloadChapters,
            icon: Icons.library_books,
            label: 'Tải $sel chapter đã chọn',
          ),
        ],
      ),
    );
  }

  Widget _buildGrid(ScanResult scan) {
    final headers = <String, String>{
      'Referer': scan.pageUrl,
      if (scan.userAgent.isNotEmpty) 'User-Agent': scan.userAgent,
    };
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: scan.images.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
        childAspectRatio: 0.7,
      ),
      itemBuilder: (_, i) {
        final img = scan.images[i];
        return Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.network(
                img.url,
                headers: headers,
                fit: BoxFit.cover,
                cacheWidth: 200,
                errorBuilder: (_, _, _) => Container(
                  color: Colors.black26,
                  child: const Icon(Icons.broken_image, size: 18),
                ),
              ),
            ),
            Positioned(
              left: 2,
              bottom: 2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                color: Colors.black54,
                child: Text(img.baseName, style: const TextStyle(fontSize: 10)),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildLog() {
    final lines = _log.lines;
    final shown = lines.length > 300 ? lines.sublist(lines.length - 300) : lines;
    return Card(
      child: ExpansionTile(
        title: Text('Nhật ký (${lines.length} dòng)'),
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: lines.isEmpty
                  ? null
                  : () {
                      Clipboard.setData(ClipboardData(text: lines.join('\n')));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Đã chép nhật ký')),
                      );
                    },
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Chép'),
            ),
          ),
          Container(
            constraints: const BoxConstraints(maxHeight: 320),
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: SingleChildScrollView(
              child: SelectableText(
                shown.isEmpty ? '(trống)' : shown.join('\n'),
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
