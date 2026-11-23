import 'package:flutter/material.dart';

/// Giao diện MẪU 1 — "Neon Đêm" (Bình chọn 15/10).
/// Chỉ đổi MÀU SẮC — giữ nguyên 100% chức năng và bố cục.
/// Mọi widget dùng màu từ đây, không hard-code rời rạc.
class NeonColors {
  static const bg = Color(0xFF14082E); // nền app (tím đen)
  static const card = Color(0xFF221245); // thẻ/card, dòng "Thư mục lưu"
  static const inputBg = Color(0xFF0D0524); // ô nhập link
  static const inputBorder = Color(0xFF3D2A7A); // viền ô nhập
  static const inputText = Color(0xFFCFC4F5); // chữ trong ô nhập
  static const purple = Color(0xFF7B2FF7); // tím gradient
  static const cyan = Color(0xFF00E5FF); // cyan gradient / đang chọn
  static const muted = Color(0xFFB9A8E8); // chữ ghi chú / không chọn
  static const white = Color(0xFFFFFFFF); // chữ chính
  static const error = Color(0xFFFF6B81); // chữ lỗi trên nền tối

  static const gradient = LinearGradient(
    colors: [purple, cyan],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );
}

ThemeData neonTheme() {
  const textTheme = TextTheme(
    bodyLarge: TextStyle(color: NeonColors.white),
    bodyMedium: TextStyle(color: NeonColors.white),
    bodySmall: TextStyle(color: NeonColors.muted),
    titleLarge: TextStyle(color: NeonColors.white),
    titleMedium: TextStyle(color: NeonColors.white),
    titleSmall: TextStyle(color: NeonColors.white),
    labelLarge: TextStyle(color: NeonColors.white),
  );
  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: NeonColors.bg,
    colorScheme: const ColorScheme.dark(
      primary: NeonColors.cyan,
      secondary: NeonColors.purple,
      surface: NeonColors.card,
      onPrimary: NeonColors.bg,
      onSecondary: NeonColors.white,
      onSurface: NeonColors.white,
      error: NeonColors.error,
    ),
    textTheme: textTheme,
    appBarTheme: const AppBarTheme(
      backgroundColor: NeonColors.bg,
      foregroundColor: NeonColors.white,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      color: NeonColors.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: NeonColors.inputBg,
      labelStyle: const TextStyle(color: NeonColors.muted),
      hintStyle: const TextStyle(color: NeonColors.muted),
      prefixIconColor: NeonColors.muted,
      suffixIconColor: NeonColors.muted,
      enabledBorder: OutlineInputBorder(
        borderSide: const BorderSide(color: NeonColors.inputBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      focusedBorder: OutlineInputBorder(
        borderSide: const BorderSide(color: NeonColors.cyan, width: 1.5),
        borderRadius: BorderRadius.circular(8),
      ),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: NeonColors.cyan,
      unselectedLabelColor: NeonColors.muted,
      indicatorColor: NeonColors.cyan,
      indicatorSize: TabBarIndicatorSize.tab,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return NeonColors.cyan;
          }
          return NeonColors.card;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return NeonColors.bg;
          }
          return NeonColors.muted;
        }),
        side: WidgetStateProperty.all(
          const BorderSide(color: NeonColors.inputBorder),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: NeonColors.cyan),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: NeonColors.cyan,
    ),
    dropdownMenuTheme: const DropdownMenuThemeData(
      textStyle: TextStyle(color: NeonColors.white),
    ),
  );
}

/// Nút chính gradient tím -> cyan, chữ trắng (thay FilledButton).
class GradientButton extends StatelessWidget {
  const GradientButton({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.label,
  });

  final VoidCallback? onPressed;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: NeonColors.gradient,
          borderRadius: BorderRadius.circular(28),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(28),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: NeonColors.white, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: const TextStyle(
                      color: NeonColors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Chữ tiêu đề gradient tím -> cyan (dùng cho AppBar).
class GradientText extends StatelessWidget {
  const GradientText(this.text, {super.key, this.fontSize = 20});

  final String text;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (bounds) => NeonColors.gradient.createShader(
        Rect.fromLTWH(0, 0, bounds.width, bounds.height),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: NeonColors.white,
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// Khung ảnh bìa khi chưa tải được ảnh thật: nền gradient + nốt nhạc.
class CoverPlaceholder extends StatelessWidget {
  const CoverPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 200,
      decoration: const BoxDecoration(
        gradient: NeonColors.gradient,
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
      child: const Center(
        child: Icon(Icons.music_note, size: 64, color: NeonColors.white),
      ),
    );
  }
}
