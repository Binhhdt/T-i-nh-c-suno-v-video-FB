import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_file/open_file.dart';
import 'package:permission_handler/permission_handler.dart';

import 'neon_theme.dart';
import 'pdf_maker.dart';
import 'save_folder.dart';
import 'save_folder_card.dart';
import 'suno_filename.dart';

/// Tab "PDF": chọn ảnh trong máy -> ghép thành 1 file PDF.
/// Mỗi ảnh = 1 trang, giữ nguyên chất lượng (JPEG nhét nguyên vẹn, ảnh
/// khác nén không mất dữ liệu). Dùng chung bộ tạo PDF [writeImagesPdf]
/// với nút "Tạo file PDF" của tab Album FB.
class PdfTab extends StatefulWidget {
  const PdfTab({super.key});

  @override
  State<PdfTab> createState() => _PdfTabState();
}

class _PdfTabState extends State<PdfTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true; // đang tạo PDF thì chuyển tab không bị huỷ

  final _nameController = TextEditingController();
  List<PlatformFile> _files = const [];
  bool _making = false;
  int _done = 0;
  int _total = 0;
  String _status = '';
  bool _statusIsError = false;
  String? _pdfPath;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final files = <PlatformFile>[];
    try {
      // file_picker 12+: trả thẳng List<PlatformFile>; `...?` chạy được
      // dù bản thư viện trả List hay List? (null = huỷ).
      final raw = await FilePicker.pickFiles(type: FileType.image);
      files.addAll([...?raw]);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'Không mở được trình chọn ảnh: $e';
        _statusIsError = true;
      });
      return;
    }
    if (!mounted) return;
    final picked = files
        .where((f) => f.path != null && f.path!.isNotEmpty)
        .toList()
      ..sort((a, b) => naturalCompare(a.name, b.name));
    if (picked.isEmpty) return;
    setState(() {
      _files = picked;
      _pdfPath = null;
      _status = 'Đã chọn ${picked.length} ảnh (xếp theo tên file).';
      _statusIsError = false;
    });
  }

  Future<void> _ensurePermission() async {
    if (!Platform.isAndroid) return;
    try {
      final s = await Permission.storage.request();
      if (s.isGranted || s.isLimited) return;
      await Permission.photos.request();
    } catch (_) {}
  }

  /// JPEG giữ nguyên byte; định dạng khác giải mã ra điểm ảnh rồi nén
  /// không mất dữ liệu.
  Future<PdfImageData?> _load(String path) async {
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

  Future<void> _make() async {
    if (_files.isEmpty || _making) return;
    FocusScope.of(context).unfocus();
    await _ensurePermission();
    if (!mounted) return;
    final paths = _files.map((f) => f.path!).toList();
    setState(() {
      _making = true;
      _done = 0;
      _total = paths.length;
      _pdfPath = null;
      _status = 'Đang tạo PDF...';
      _statusIsError = false;
    });
    try {
      final resolved = await resolveUserVisibleSaveDir();
      var base = sanitizeSongTitle(_nameController.text);
      if (base.isEmpty) {
        final n = DateTime.now();
        String two(int v) => v.toString().padLeft(2, '0');
        base = 'Anh sang PDF ${n.year}-${two(n.month)}-${two(n.day)} '
            '${two(n.hour)}h${two(n.minute)}';
      }
      final name = uniqueFileName(
        resolved.dir.path,
        '$base.pdf',
        exists: (p) => File(p).existsSync(),
      );
      final outPath = '${resolved.dir.path}/$name';
      final pages = await writeImagesPdf(
        outPath: outPath,
        pageCount: paths.length,
        loadPage: (i) => _load(paths[i]),
        onProgress: (d) {
          if (mounted) setState(() => _done = d);
        },
      );
      if (!mounted) return;
      setState(() {
        if (pages == 0) {
          _status = 'Không tạo được PDF: không đọc được ảnh nào.';
          _statusIsError = true;
        } else {
          _pdfPath = outPath;
          final skipped = paths.length - pages;
          _status = 'Đã tạo PDF $pages trang: $outPath'
              '${skipped > 0 ? ' (bỏ qua $skipped ảnh không đọc được)' : ''}'
              '${resolved.usedPrivateFallback ? ' — lưu vào thư mục riêng của app vì không ghi được vào thư mục đã chọn.' : ''}';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'Tạo PDF thất bại: ${e.toString().replaceFirst('Exception: ', '')}';
        _statusIsError = true;
      });
    } finally {
      if (mounted) setState(() => _making = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Card(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.picture_as_pdf),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Chuyển ảnh thành PDF: mỗi ảnh = 1 trang, giữ nguyên '
                      'chất lượng ảnh. Ảnh được xếp theo tên file '
                      '(anh_001, anh_002... — anh_2 đứng trước anh_10).',
                      style: TextStyle(fontSize: 13, color: NeonColors.muted),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          SaveFolderCard(onChanged: (_) {}),
          const SizedBox(height: 12),
          GradientButton(
            onPressed: _making ? null : _pick,
            icon: Icons.photo_library,
            label: _files.isEmpty
                ? 'Chọn ảnh trong máy'
                : 'Chọn lại ảnh (${_files.length} ảnh)',
          ),
          if (_files.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'Thứ tự trang (${_files.length} ảnh):',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _files.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
                childAspectRatio: 0.72,
              ),
              itemBuilder: (_, i) {
                final f = _files[i];
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.file(
                        File(f.path!),
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
                        child: Text('${i + 1}', style: const TextStyle(fontSize: 10)),
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameController,
              enabled: !_making,
              decoration: const InputDecoration(
                labelText: 'Tên file PDF (để trống = tự đặt theo ngày giờ)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            GradientButton(
              onPressed: _making ? null : _make,
              icon: Icons.picture_as_pdf,
              label: 'Tạo PDF (${_files.length} trang)',
            ),
          ],
          if (_making) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(value: _total > 0 ? _done / _total : null),
            const SizedBox(height: 6),
            Text('Đang tạo PDF $_done/$_total trang...', textAlign: TextAlign.center),
          ],
          if (_pdfPath != null && !_making) ...[
            const SizedBox(height: 16),
            GradientButton(
              onPressed: () => OpenFile.open(_pdfPath!),
              icon: Icons.open_in_new,
              label: 'Mở file PDF',
            ),
          ],
          if (_status.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              _status,
              style: TextStyle(color: _statusIsError ? NeonColors.error : null),
            ),
          ],
        ],
      ),
    );
  }
}
