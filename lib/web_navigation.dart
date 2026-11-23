import 'package:webview_flutter/webview_flutter.dart';

/// Cổng điều hướng dùng chung cho mọi WebView trong app.
///
/// Facebook hay chèn link `fb://`, `intent://`... để mở app Facebook
/// gốc. WebView không hiểu các scheme đó nên sẽ hiện lỗi
/// `net::ERR_UNKNOWN_URL_SCHEME` và — tệ hơn — thay cả trang đang mở
/// bằng trang lỗi, làm chết quá trình trích xuất video đang chạy.
/// Chặn các điều hướng ngoài http(s) ngay từ đầu để trang Facebook
/// đang mở được giữ nguyên.
///
/// Chỉ http/https được phép; mọi scheme khác (fb://, intent://, tel:,
/// mailto:, about:, data:, ...) đều bị chặn.
bool shouldAllowNavigation(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  return uri.scheme == 'http' || uri.scheme == 'https';
}

/// Quyết định điều hướng cho `NavigationDelegate.onNavigationRequest`.
NavigationDecision navigationDecisionFor(String url) =>
    shouldAllowNavigation(url)
        ? NavigationDecision.navigate
        : NavigationDecision.prevent;
