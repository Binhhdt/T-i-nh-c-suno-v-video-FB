// Tên file tải xuống cho tab Nhạc Suno: dùng TIÊU ĐỀ GỐC của bài nhạc
// (vd "Tình khúc ngày cũ.wav") thay vì `suno_<timestamp>` để Bình nhìn
// tên file là biết bài nào.
//
// - [sanitizeSongTitle]: làm sạch tiêu đề thành tên file an toàn.
// - [uniqueFileName]: tránh ghi đè file cùng tên đã có trong thư mục
//   ("Tình khúc ngày cũ (1).wav", "Tình khúc ngày cũ (2).wav", ...).

/// Làm sạch tiêu đề thành phần tên file (không kèm đuôi):
/// bỏ ký tự cấm trên Android/Windows (`/ \ : * ? " < > |` + ký tự điều
/// khiển), trim khoảng trắng/dấu chấm ở 2 đầu, gộp khoảng trắng lặp,
/// giới hạn ~100 ký tự. Trả về '' nếu không còn gì (caller fallback
/// sang `suno_<timestamp>`).
String sanitizeSongTitle(String title) {
  var name = title;
  // Bỏ ký tự cấm + ký tự điều khiển.
  name = name.replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1F\x7F]'), '');
  // Gộp khoảng trắng lặp thành 1, trim cả khoảng trắng + dấu chấm ở 2 đầu
  // (tên file kết thúc bằng '.' gây lỗi trên một số hệ thống).
  name = name.replaceAll(RegExp(r'\s+'), ' ').trim().replaceAll(
    RegExp(r'^[.\s]+|[.\s]+$'),
    '',
  );
  const maxLen = 100;
  if (name.length > maxLen) {
    name = name.substring(0, maxLen).trim().replaceAll(
      RegExp(r'[.\s]+$'),
      '',
    );
  }
  return name;
}

/// Tên file chưa trùng trong [dirPath]: nếu [fileName] đã tồn tại thì
/// thêm " (1)", " (2)", ... trước đuôi. [exists] là hàm kiểm tra tồn
/// tại (để test được mà không cần chạm filesystem thật).
String uniqueFileName(
  String dirPath,
  String fileName, {
  required bool Function(String path) exists,
}) {
  if (!exists('$dirPath/$fileName')) return fileName;
  final dot = fileName.lastIndexOf('.');
  final base = dot > 0 ? fileName.substring(0, dot) : fileName;
  final ext = dot > 0 ? fileName.substring(dot) : '';
  var i = 1;
  while (true) {
    final candidate = '$base ($i)$ext';
    if (!exists('$dirPath/$candidate')) return candidate;
    i++;
  }
}
