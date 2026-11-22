# fb_video_downloader

Tải video Facebook về điện thoại

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Build APK

GitHub Actions build trực tiếp từ mã nguồn Git bằng Flutter 3.47.9. Android yêu cầu API 24 trở lên. Pull request chạy phân tích, kiểm thử với FFmpeg/FFprobe và build APK release dùng khóa kiểm thử.

Bản phát hành trên nhánh chính dùng bốn Actions Secrets cùng bộ khóa phát hành hiện có:

- ANDROID_KEYSTORE_BASE64 chứa nội dung Base64 của keystore.
- ANDROID_KEYSTORE_PASSWORD chứa mật khẩu keystore.
- ANDROID_KEY_ALIAS chứa tên khóa.
- ANDROID_KEY_PASSWORD chứa mật khẩu khóa.

Các commit cũ của repository công khai đã chứa keystore và cấu hình ký. Hãy xem khóa cũ là đã lộ và xác minh phương án nâng cấp chữ ký cho các thiết bị đã cài trước khi đổi khóa. Kiểm tra fingerprint từ một APK đã phát hành và lưu khóa trong kho bí mật có kiểm soát quyền truy cập.
