import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Thư mục lưu video do người dùng chọn.
/// Chỉ lưu ĐƯỜNG DẪN thư mục — không lưu nội dung file, không liên quan
/// đến đăng nhập Facebook hay cookie phiên.
class SaveFolder {
  static const prefsKey = 'save_folder_path';
  static const defaultLabel = 'Downloads (mặc định)';

  /// Đọc đường dẫn thư mục đã chọn, null nếu chưa chọn (dùng Downloads).
  static Future<String?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(prefsKey);
    if (path == null || path.isEmpty) return null;
    return path;
  }

  static Future<void> save(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, path);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(prefsKey);
  }

  /// Nhãn hiển thị: đường dẫn đã chọn, hoặc "Downloads (mặc định)".
  static String label(String? customPath) =>
      (customPath == null || customPath.isEmpty) ? defaultLabel : customPath;
}

/// Kết quả giải quyết thư mục lưu: thư mục sẽ dùng + có phải fallback
/// về Downloads (thư mục đã chọn không còn dùng được) hay không.
class ResolvedSaveDir {
  const ResolvedSaveDir({
    required this.dir,
    required this.usedFallback,
    this.usedPrivateFallback = false,
  });

  final Directory dir;
  final bool usedFallback;

  /// true khi phải dùng thư mục riêng của app (không ghi được vào
  /// thư mục đã chọn lẫn Downloads công khai). File vẫn tải được nhưng
  /// người dùng khó thấy trong app Files — UI PHẢI báo rõ, không im lặng.
  final bool usedPrivateFallback;
}

/// Chọn thư mục lưu thực tế:
/// - Thư mục đã chọn còn tồn tại -> dùng nó.
/// - Thư mục đã chọn không còn (bị xoá, mất quyền) -> Downloads.
/// - Chưa chọn gì -> Downloads (không tính là fallback).
/// [exists] để test (mặc định kiểm tra Directory.existsSync).
ResolvedSaveDir resolveSaveDir({
  String? customPath,
  required Directory downloadsDir,
  bool Function(String path)? exists,
}) {
  final existsFn = exists ?? ((p) => Directory(p).existsSync());
  final hasCustom = customPath != null && customPath.isNotEmpty;
  if (hasCustom && existsFn(customPath)) {
    return ResolvedSaveDir(dir: Directory(customPath), usedFallback: false);
  }
  return ResolvedSaveDir(dir: downloadsDir, usedFallback: hasCustom);
}

/// Chuỗi fallback dùng chung cho CẢ 2 tab (Video FB + Nhạc Suno):
/// 1. Thư mục đã chọn — phải ghi được thật (probe).
/// 2. Downloads CÔNG KHAI (/storage/emulated/0/Download) — phải ghi được.
/// 3. Thư mục riêng của app — phương án cuối, gắn cờ usedPrivateFallback
///    để UI báo rõ (không im lặng rơi về đây).
///
/// [writable] để test (mặc định probe ghi thật).
ResolvedSaveDir resolveSaveDirChain({
  String? customPath,
  required Directory publicDownloadsDir,
  required Directory appPrivateDir,
  bool Function(String path)? writable,
}) {
  final writableFn = writable ?? canWriteToSync;
  final hasCustom = customPath != null && customPath.isNotEmpty;
  if (hasCustom && writableFn(customPath)) {
    return ResolvedSaveDir(dir: Directory(customPath), usedFallback: false);
  }
  if (writableFn(publicDownloadsDir.path)) {
    return ResolvedSaveDir(
      dir: publicDownloadsDir,
      usedFallback: hasCustom,
    );
  }
  return ResolvedSaveDir(
    dir: appPrivateDir,
    usedFallback: hasCustom,
    usedPrivateFallback: true,
  );
}

/// Thử ghi + xoá 1 file thăm dò để biết thư mục có ghi được không.
/// KHÔNG tự tạo thư mục — thư mục chưa tồn tại coi như không ghi được.
/// (Các thư mục hệ thống như Downloads công khai được tạo trước ở
/// [resolveUserVisibleSaveDir].)
bool canWriteToSync(String dirPath) {
  try {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return false;
    final probe = File('$dirPath/.fb_write_test');
    probe.writeAsStringSync('test');
    probe.deleteSync();
    return true;
  } catch (_) {
    return false;
  }
}

/// Phiên async của [canWriteToSync] (dùng trong UI).
Future<bool> canWriteTo(String dirPath) async {
  try {
    return canWriteToSync(dirPath);
  } catch (_) {
    return false;
  }
}

/// Downloads CÔNG KHAI trên Android (/storage/emulated/0/Download).
/// QUAN TRỌNG (bug 15/10): path_provider `getDownloadsDirectory()` trên
/// Android trả về thư mục RIÊNG của app
/// (`/storage/emulated/0/Android/data/<package>/files/Download`) — file lưu
/// vào đó không hiện trong app Files của máy. Vì vậy tự suy ra Downloads
/// công khai từ gốc bộ nhớ ngoài: getExternalStorageDirectory() trả về
/// `.../Android/data/<package>/files` -> cắt phần "/Android/data/..." đi
/// rồi cộng "/Download". Ngoài Android thì dùng getDownloadsDirectory().
Future<Directory> publicDownloadsDir() async {
  if (Platform.isAndroid) {
    try {
      final external = await getExternalStorageDirectory();
      if (external != null) {
        final marker = '/Android/data/';
        final idx = external.path.indexOf(marker);
        if (idx > 0) {
          return Directory('${external.path.substring(0, idx)}/Download');
        }
      }
    } catch (_) {}
  }
  final downloads = await getDownloadsDirectory();
  if (downloads != null) return downloads;
  return getApplicationDocumentsDirectory();
}

/// Thư mục riêng của app (phương án cuối khi không ghi được đâu khác).
Future<Directory> appPrivateDownloadDir() async {
  try {
    final external = await getExternalStorageDirectory();
    if (external != null) return Directory('${external.path}/Download');
  } catch (_) {}
  return getApplicationDocumentsDirectory();
}

/// Giải quyết thư mục lưu cho file người dùng thấy được — dùng chung
/// cho cả tab Video FB và tab Nhạc Suno. Đọc lựa chọn mới từ prefs.
/// Tạo trước 2 thư mục hệ thống (Downloads công khai + thư mục riêng)
/// rồi mới probe — tránh lỗi "thư mục chưa tồn tại" khi probe.
Future<ResolvedSaveDir> resolveUserVisibleSaveDir() async {
  final customPath = await SaveFolder.load();
  final publicDir = await publicDownloadsDir();
  final privateDir = await appPrivateDownloadDir();
  try {
    if (!await publicDir.exists()) {
      await publicDir.create(recursive: true);
    }
  } catch (_) {}
  try {
    if (!await privateDir.exists()) {
      await privateDir.create(recursive: true);
    }
  } catch (_) {}
  return resolveSaveDirChain(
    customPath: customPath,
    publicDownloadsDir: publicDir,
    appPrivateDir: privateDir,
  );
}
