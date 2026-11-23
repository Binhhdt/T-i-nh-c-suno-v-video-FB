/// Helper thuần Dart cho cookie phiên Facebook.
/// Cookie chỉ dùng trong bộ nhớ để gắn vào request — KHÔNG ghi ra file,
/// KHÔNG log, KHÔNG lưu trữ lâu dài. Mật khẩu người dùng không bao giờ
/// đi qua app: người dùng gõ mật khẩu trực tiếp vào trang Facebook
/// trong WebView.
class FacebookSession {
  /// Ghép map cookie thành header `Cookie: a=1; b=2`.
  /// Bỏ qua cookie tên trống / giá trị trống.
  static String buildCookieHeader(Map<String, String> cookies) {
    final parts = <String>[];
    for (final entry in cookies.entries) {
      final name = entry.key.trim();
      final value = entry.value.trim();
      if (name.isEmpty || value.isEmpty) continue;
      parts.add('$name=$value');
    }
    return parts.join('; ');
  }

  /// Đã đăng nhập khi có đủ 2 cookie phiên chính của Facebook.
  static bool hasLoginCookies(Map<String, String> cookies) {
    final cUser = cookies['c_user']?.trim() ?? '';
    final xs = cookies['xs']?.trim() ?? '';
    return cUser.isNotEmpty && xs.isNotEmpty;
  }
}
