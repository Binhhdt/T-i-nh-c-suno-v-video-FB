import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'album_extractor.dart';
import 'audio_converter.dart';
import 'comic/comic_tab.dart';
import 'downloader.dart';
import 'neon_theme.dart';
import 'pdf_maker.dart';
import 'pdf_tab.dart';
import 'save_folder.dart';
import 'save_folder_card.dart';
import 'session.dart';
import 'suno_crypto.dart';
import 'suno_extractor.dart';
import 'suno_filename.dart';
import 'facebook_video_tab.dart';
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

/// Màn hình chính: 5 tab — "Video FB" (tải video Facebook),
/// "Nhạc Suno" (tải nhạc Suno, convert MP3/WAV trên máy),
/// "Album FB" (tải ảnh bài viết nhiều ảnh / album Facebook) và
/// "Truyện" (tải ảnh trang chapter từ link người dùng nhập) và
/// "PDF" (chọn ảnh trong máy -> ghép thành PDF).
/// Cài đặt "Thư mục lưu" có ở CẢ 2 tab (widget dùng chung) và dùng
/// chung resolver thư mục lưu.
class DownloaderPage extends StatelessWidget {
  const DownloaderPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: const GradientText('Tải Video & Nhạc'),
          centerTitle: true,
          // 5 tab -> cho cuộn ngang để chữ không bị cắt.
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Video FB'),
              Tab(text: 'Nhạc Suno'),
              Tab(text: 'Album FB'),
              Tab(text: 'Truyện'),
              Tab(text: 'PDF'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            FacebookVideoTab(),
            _SunoTab(),
            _AlbumTab(),
            ComicTab(),
            PdfTab(),
          ],
        ),
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

