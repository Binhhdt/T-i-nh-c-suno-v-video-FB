import 'dart:io';

/// Nhật ký của tab "Truyện": mỗi dòng có giờ:phút:giây + mức độ.
/// Hiện trong app và ghi ra file `_log.txt` cạnh ảnh để biết vì sao
/// một URL không tải được.
class ComicLog {
  final List<String> lines = [];

  /// Gọi mỗi khi có dòng mới (để UI cập nhật).
  void Function()? onChanged;

  String _now() {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  void _add(String level, String msg) {
    lines.add('${_now()} [$level] $msg');
    // Giới hạn để không ăn hết bộ nhớ.
    if (lines.length > 3000) lines.removeRange(0, lines.length - 3000);
    onChanged?.call();
  }

  void info(String msg) => _add('INFO', msg);
  void warn(String msg) => _add('WARN', msg);
  void error(String msg) => _add('LỖI', msg);

  void addAll(Iterable<String> msgs) {
    for (final m in msgs) {
      info(m);
    }
  }

  void clear() {
    lines.clear();
    onChanged?.call();
  }

  /// Ghi toàn bộ nhật ký ra file (ghi đè). Lỗi ghi file không làm hỏng
  /// việc tải.
  Future<void> saveTo(String path) async {
    try {
      await File(path).writeAsString('${lines.join('\n')}\n');
    } catch (_) {}
  }
}
