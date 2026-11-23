import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'neon_theme.dart';
import 'save_folder.dart';

/// Thẻ "Thư mục lưu" dùng chung cho CẢ 2 tab (Video FB + Nhạc Suno).
/// Hiển thị thư mục hiện tại + nút "Đổi thư mục" / "Mặc định".
/// Logic chọn thư mục giống hệt nhau ở 2 tab: kiểm tra ghi được thật
/// (file thăm dò) trước khi lưu; nếu chưa ghi được thì xin quyền
/// "All files access" (Android 11+) rồi thử lại; từ chối quyền thì
/// giữ thư mục cũ (Downloads).
class SaveFolderCard extends StatefulWidget {
  const SaveFolderCard({super.key, required this.onChanged});

  /// Gọi khi thư mục lưu thay đổi (đường dẫn mới, hoặc null = mặc định).
  final ValueChanged<String?> onChanged;

  @override
  State<SaveFolderCard> createState() => _SaveFolderCardState();
}

class _SaveFolderCardState extends State<SaveFolderCard> {
  String? _saveFolder;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final saved = await SaveFolder.load();
    if (!mounted) return;
    setState(() => _saveFolder = saved);
  }

  Future<void> _pick() async {
    final picked = await FilePicker.getDirectoryPath(
      dialogTitle: 'Chọn thư mục lưu',
    );
    if (picked == null) return;
    if (await canWriteTo(picked)) {
      await SaveFolder.save(picked);
      if (!mounted) return;
      setState(() => _saveFolder = picked);
      widget.onChanged(picked);
      return;
    }
    final status = await Permission.manageExternalStorage.request();
    if (status.isGranted && await canWriteTo(picked)) {
      await SaveFolder.save(picked);
      if (!mounted) return;
      setState(() => _saveFolder = picked);
      widget.onChanged(picked);
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Không ghi được vào thư mục đã chọn. File sẽ lưu vào Downloads.',
        ),
      ),
    );
  }

  Future<void> _reset() async {
    await SaveFolder.clear();
    if (!mounted) return;
    setState(() => _saveFolder = null);
    widget.onChanged(null);
  }

  @override
  Widget build(BuildContext context) {
    return Card(
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
                  const SizedBox(height: 2),
                  Text(
                    SaveFolder.label(_saveFolder),
                    style: const TextStyle(
                      fontSize: 13,
                      color: NeonColors.muted,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (_saveFolder != null)
              TextButton(
                onPressed: _reset,
                child: const Text('Mặc định'),
              ),
            TextButton(
              onPressed: _pick,
              child: const Text('Đổi thư mục'),
            ),
          ],
        ),
      ),
    );
  }
}
