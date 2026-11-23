import 'dart:async';
import 'dart:io';

import 'package:fb_video_downloader/downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Server giả: N lần đầu trả stream bị CỤT (thiếu byte cuối + thiếu
/// marker FFD9, nhưng khai Content-Length đủ), các lần sau trả đủ.
/// Mô phỏng đúng lỗi Bình gặp: trang truyện tải về chỉ còn 3/4 hàng
/// khung vì file JPEG thiếu ~1/4 cuối.
class _TruncatingClient extends http.BaseClient {
  int calls = 0;
  final List<int> fullBody;
  final int truncatedCalls;

  _TruncatingClient({required this.fullBody, required this.truncatedCalls});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls++;
    final body = calls <= truncatedCalls
        ? fullBody.sublist(0, fullBody.length ~/ 2)
        : fullBody;
    return http.StreamedResponse(
      Stream.value(body),
      200,
      contentLength: fullBody.length,
      headers: {'content-length': fullBody.length.toString()},
    );
  }
}

/// Server giả: stream treo, không bao giờ gửi byte nào (rớt mạng
/// giữa chừng) — dùng để kiểm tra timeout không-có-dữ-liệu.
class _StallingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // Stream không bao giờ gửi byte nào (rớt mạng giữa chừng) và
    // không đóng — timeout không-có-dữ-liệu phải cắt nó.
    final controller = StreamController<List<int>>();
    return http.StreamedResponse(
      controller.stream,
      200,
      contentLength: 1000,
    );
  }
}

/// JPEG đầy đủ 1000 byte: FF D8 ... FF D9 (EOI).
List<int> _completeJpeg() {
  final bytes = <int>[0xFF, 0xD8];
  bytes.addAll(List.filled(996, 0x41));
  bytes.addAll([0xFF, 0xD9]);
  return bytes;
}

/// PNG đầy đủ: signature 8 byte + filler + chunk IEND 12 byte.
List<int> _completePng() {
  final bytes = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  bytes.addAll(List.filled(100, 0x42));
  bytes.addAll([
    0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, //
    0xAE, 0x42, 0x60, 0x82,
  ]);
  return bytes;
}

/// WebP đầy đủ: "RIFF" + kích thước (LE32) + "WEBP" + payload.
/// Tổng độ dài file == 8 + kích thước RIFF.
List<int> _completeWebP() {
  final payload = List.filled(88, 0x43);
  final size = 4 + payload.length; // "WEBP" + payload = 92.
  final bytes = <int>[];
  bytes.addAll('RIFF'.codeUnits);
  bytes.addAll([
    size & 0xFF,
    (size >> 8) & 0xFF,
    (size >> 16) & 0xFF,
    (size >> 24) & 0xFF,
  ]);
  bytes.addAll('WEBP'.codeUnits);
  bytes.addAll(payload);
  return bytes; // 100 byte == 8 + 92.
}

/// Server giả: luôn trả đúng 1 body cố định (kèm Content-Length =
/// độ dài body thật).
class _FixedBodyClient extends http.BaseClient {
  final List<int> body;

  _FixedBodyClient(this.body);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream.value(body),
      200,
      contentLength: body.length,
      headers: {'content-length': body.length.toString()},
    );
  }
}

void main() {
  group('VideoDownloader — kiểm tra file tải đủ (v12)', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('dl_test_');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('JPEG cụt lần đầu -> tải lại, file cuối đủ + có FFD9', () async {
      final client = _TruncatingClient(
        fullBody: _completeJpeg(),
        truncatedCalls: 1,
      );
      final dl = VideoDownloader(client: client);
      final result = await dl.download(
        'https://example.com/pic.jpg',
        onProgress: (_) {},
        preferredDir: tmp,
        fileName: 'trang_truyen.jpg',
      );
      expect(client.calls, 2);
      final bytes = await result.file.readAsBytes();
      expect(bytes.length, 1000);
      expect(bytes[0], 0xFF);
      expect(bytes[1], 0xD8);
      expect(bytes[bytes.length - 2], 0xFF);
      expect(bytes[bytes.length - 1], 0xD9);
    });

    test('PNG cụt lần đầu -> tải lại, file cuối đủ + có IEND', () async {
      final client = _TruncatingClient(
        fullBody: _completePng(),
        truncatedCalls: 1,
      );
      final dl = VideoDownloader(client: client);
      final result = await dl.download(
        'https://example.com/pic.png',
        onProgress: (_) {},
        preferredDir: tmp,
        fileName: 'anh.png',
      );
      final bytes = await result.file.readAsBytes();
      expect(bytes.length, _completePng().length);
      // 12 byte cuối = chunk IEND.
      expect(bytes.sublist(bytes.length - 12), [
        0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, //
        0xAE, 0x42, 0x60, 0x82,
      ]);
    });

    test('luôn cụt -> ném lỗi, KHÔNG để file cụt trong thư mục', () async {
      final client = _TruncatingClient(
        fullBody: _completeJpeg(),
        truncatedCalls: 99,
      );
      final dl = VideoDownloader(client: client);
      await expectLater(
        dl.download(
          'https://example.com/pic.jpg',
          onProgress: (_) {},
          preferredDir: tmp,
          fileName: 'trang_truyen.jpg',
        ),
        throwsA(isA<Exception>()),
      );
      expect(client.calls, VideoDownloader.maxAttempts);
      expect(await File('${tmp.path}/trang_truyen.jpg').exists(), isFalse);
      expect(tmp.listSync().isEmpty, isTrue);
    });

    test('stream treo -> timeout không-có-dữ-liệu, không để file lại',
        () async {
      final dl = VideoDownloader(
        client: _StallingClient(),
        idleTimeout: const Duration(milliseconds: 100),
      );
      await expectLater(
        dl.download(
          'https://example.com/pic.jpg',
          onProgress: (_) {},
          preferredDir: tmp,
          fileName: 'trang_truyen.jpg',
        ),
        throwsA(isA<Exception>()),
      );
      expect(await File('${tmp.path}/trang_truyen.jpg').exists(), isFalse);
    });
  });

  group('VideoDownloader — định dạng thật từ magic bytes (v13)', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('dl_test_');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('WebP cho URL .jpg -> lưu file .webp, KHÔNG tính là lỗi', () async {
      // Mô phỏng đúng lỗi Bình gặp: CDN Facebook trả WebP cho URL
      // ".jpg" — v12 kiểm tra JPEG cứng nên loại nhầm thành "file cụt".
      final dl = VideoDownloader(client: _FixedBodyClient(_completeWebP()));
      final result = await dl.download(
        'https://scontent.fna.fbcdn.net/v/t39.30808-6/pic_n.jpg',
        onProgress: (_) {},
        preferredDir: tmp,
        fileName: 'anh.jpg',
      );
      expect(result.file.path.endsWith('.webp'), isTrue);
      expect(await File('${tmp.path}/anh.jpg').exists(), isFalse);
      final bytes = await result.file.readAsBytes();
      expect(bytes.length, 100);
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WEBP');
    });

    test('JPEG cho tên .png -> đổi đuôi thành .jpg', () async {
      final dl = VideoDownloader(client: _FixedBodyClient(_completeJpeg()));
      final result = await dl.download(
        'https://example.com/pic.png',
        onProgress: (_) {},
        preferredDir: tmp,
        fileName: 'anh.png',
      );
      expect(result.file.path.endsWith('.jpg'), isTrue);
      expect(await File('${tmp.path}/anh.png').exists(), isFalse);
    });

    test('WebP cụt (kích thước RIFF không khớp) -> lỗi, không để file',
        () async {
      // RIFF khai 92 nhưng chỉ có 50 byte thật.
      final truncated = _completeWebP().sublist(0, 50);
      final dl = VideoDownloader(client: _FixedBodyClient(truncated));
      await expectLater(
        dl.download(
          'https://example.com/pic.jpg',
          onProgress: (_) {},
          preferredDir: tmp,
          fileName: 'anh.jpg',
        ),
        throwsA(isA<Exception>()),
      );
      expect(tmp.listSync().isEmpty, isTrue);
    });
  });
}
