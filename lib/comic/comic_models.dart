/// Dữ liệu dùng chung cho tab "Truyện" (downloader trang chapter tổng quát).

/// 1 trang (ảnh) của chapter, đã xếp đúng thứ tự.
class ChapterImage {
  const ChapterImage({
    required this.index,
    required this.url,
    required this.source,
    this.width = 0,
    this.height = 0,
  });

  /// Vị trí trang, bắt đầu từ 0 -> file 001, 002, ...
  final int index;
  final String url;

  /// Nguồn tìm ra ảnh: 'dom' (thẻ <img>) hoặc 'json' (dữ liệu JSON/API).
  final String source;
  final int width;
  final int height;

  /// Tên file không đuôi: 001, 002, ...
  String get baseName => (index + 1).toString().padLeft(3, '0');
}

/// 1 link chapter tìm thấy trên trang giới thiệu bộ truyện.
class ChapterLink {
  const ChapterLink({required this.url, required this.title, this.number});

  final String url;

  /// Chữ hiện trên link (vd "Chương 12").
  final String title;

  /// Số chapter đọc được từ chữ/link (12, 12.5...). null nếu không có.
  final double? number;

  /// Số chapter dạng gọn: 12 / 12.5
  String get numberLabel {
    final n = number;
    if (n == null) return '?';
    return n == n.roundToDouble() ? n.toInt().toString() : n.toString();
  }
}

/// Kết quả quét 1 trang chapter.
class ScanResult {
  const ScanResult({
    required this.pageUrl,
    required this.title,
    required this.userAgent,
    required this.images,
    required this.chosenSource,
    required this.log,
    this.warning,
    this.chapters = const [],
  });

  /// Các link chapter trên trang (trang giới thiệu bộ truyện), đã xếp
  /// theo số chapter tăng dần.
  final List<ChapterLink> chapters;

  /// Cảnh báo cho người dùng (vd trang có vẻ là trang giới thiệu/danh sách
  /// truyện chứ không phải trang chapter). null = không có gì đáng ngờ.
  final String? warning;

  final String pageUrl;
  final String title;

  /// User-Agent của trình duyệt đã mở trang (dùng lại khi tải ảnh).
  final String userAgent;
  final List<ChapterImage> images;

  /// Mô tả nguồn được chọn (để hiện + ghi log).
  final String chosenSource;

  /// Nhật ký quá trình quét.
  final List<String> log;
}

/// Trạng thái tải của 1 trang.
enum PageState { pending, downloading, done, skipped, failed }

/// Kết quả tải 1 trang.
class PageResult {
  const PageResult({
    required this.image,
    required this.state,
    this.filePath,
    this.reason,
    this.attempts = 0,
  });

  final ChapterImage image;
  final PageState state;
  final String? filePath;

  /// Lý do lỗi (khi failed) hoặc ghi chú (khi skipped).
  final String? reason;
  final int attempts;
}

/// Tổng kết 1 lần tải chapter.
class DownloadReport {
  const DownloadReport(this.results);

  final List<PageResult> results;

  int get ok => results.where((r) => r.state == PageState.done).length;
  int get skipped => results.where((r) => r.state == PageState.skipped).length;
  int get failed => results.where((r) => r.state == PageState.failed).length;

  /// File hợp lệ (tải mới + đã có sẵn) theo đúng thứ tự trang.
  List<String> get filesInOrder {
    final good = results
        .where((r) =>
            (r.state == PageState.done || r.state == PageState.skipped) &&
            r.filePath != null)
        .toList()
      ..sort((a, b) => a.image.index.compareTo(b.image.index));
    return [for (final r in good) r.filePath!];
  }
}

/// Kiểu xuất kết quả.
enum ExportMode { folder, cbz, both }
