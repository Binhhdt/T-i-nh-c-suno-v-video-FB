import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../web_navigation.dart';
import 'comic_models.dart';
import 'comic_scanner.dart';

/// Trang quét chapter bằng trình duyệt thật (WebView = Chromium của máy):
/// 1. Mở URL, gắn "tai nghe" JSON (fetch/XHR) ngay khi trang bắt đầu tải.
/// 2. Chờ trang tải xong + JavaScript chạy.
/// 3. Tự cuộn dần tới cuối để kích hoạt lazy-load, đến khi chiều cao
///    trang không đổi nữa.
/// 4. Quét DOM + script + JSON/API -> gửi về Dart qua kênh JS.
/// 5. Phân tích bằng [ComicScanner.analyze] và trả [ScanResult].
///
/// Không vượt CAPTCHA / đăng nhập / paywall: nếu trang cần người dùng
/// thao tác, người dùng tự làm trong khung trình duyệt rồi bấm "Quét lại".
class ComicScanPage extends StatefulWidget {
  const ComicScanPage({
    super.key,
    required this.url,
    this.desktop = false,
    this.batchLabel,
    this.giveUpAfter,
  });

  final String url;

  /// Nhãn khi tải nhiều chapter (vd "Chap 3 (2/10)").
  final String? batchLabel;

  /// Chế độ tải nhiều chapter: quá thời gian này không quét được thì tự
  /// đóng (trả null) để chuyển sang chapter sau; quét ra 0 ảnh cũng trả
  /// kết quả rỗng ngay thay vì chờ người dùng.
  final Duration? giveUpAfter;

  /// Giả giao diện máy tính (một số trang hiển thị đủ ảnh hơn).
  final bool desktop;

  static const desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  @override
  State<ComicScanPage> createState() => _ComicScanPageState();
}

class _ComicScanPageState extends State<ComicScanPage> {
  late final WebViewController _controller;
  String _status = 'Đang mở trang...';
  bool _autoRunning = false;
  bool _scanning = false;
  bool _popped = false;
  int _autoGeneration = 0;
  Timer? _giveUpTimer;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        ComicScanScripts.channel,
        onMessageReceived: (m) => _onScanMessage(m.message),
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (r) => navigationDecisionFor(r.url),
          onPageStarted: (_) => _injectHook(),
          onPageFinished: (_) {
            _injectHook();
            _startAuto();
          },
          onWebResourceError: (_) {},
        ),
      );
    if (widget.desktop) {
      _controller.setUserAgent(ComicScanPage.desktopUserAgent);
    }
    _controller.loadRequest(Uri.parse(widget.url));
    final limit = widget.giveUpAfter;
    if (limit != null) {
      _giveUpTimer = Timer(limit, () {
        if (_popped || !mounted) return;
        _popped = true;
        _autoGeneration++;
        Navigator.of(context).pop<ScanResult>();
      });
    }
  }

  @override
  void dispose() {
    _autoGeneration++; // dừng vòng tự cuộn đang chạy
    _giveUpTimer?.cancel();
    super.dispose();
  }

  Future<void> _injectHook() async {
    try {
      await _controller.runJavaScript(ComicScanScripts.hook);
    } catch (_) {}
  }

  void _setStatus(String s) {
    if (mounted && !_popped) setState(() => _status = s);
  }

  /// Chờ JS chạy, tự cuộn tới cuối (lazy-load), rồi quét.
  Future<void> _startAuto() async {
    if (_autoRunning || _popped) return;
    _autoRunning = true;
    final gen = ++_autoGeneration;
    try {
      _setStatus('Đang chờ trang chạy JavaScript...');
      await Future.delayed(const Duration(milliseconds: 1500));
      var lastHeight = -1;
      var stable = 0;
      for (var step = 0; step < 120; step++) {
        if (gen != _autoGeneration || _popped) return;
        String raw;
        try {
          raw = (await _controller
                  .runJavaScriptReturningResult(ComicScanScripts.scrollStep))
              .toString()
              .replaceAll('"', '');
        } catch (_) {
          break;
        }
        final parts = raw.split('|');
        final h = int.tryParse(parts.isNotEmpty ? parts[0] : '') ?? 0;
        final pos = int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0;
        _setStatus('Đang cuộn để tải ảnh lazy... ${h > 0 ? (pos * 100 ~/ h).clamp(0, 100) : 0}%');
        if (pos >= h - 5 && h == lastHeight) {
          stable++;
          if (stable >= 3) break; // tới cuối + trang không dài thêm
        } else {
          stable = 0;
        }
        lastHeight = h;
        await Future.delayed(const Duration(milliseconds: 700));
      }
      if (gen != _autoGeneration || _popped) return;
      // Bấm "Xem thêm / Xem tất cả" (nếu có) cho đến khi hết nút mới.
      for (var round = 0; round < 8; round++) {
        if (gen != _autoGeneration || _popped) return;
        int clicked;
        try {
          clicked = int.tryParse((await _controller
                      .runJavaScriptReturningResult(ComicScanScripts.expandMore))
                  .toString()
                  .replaceAll('"', '')) ??
              0;
        } catch (_) {
          clicked = 0;
        }
        if (clicked == 0) break;
        _setStatus('Đã bấm "Xem thêm" để hiện đủ danh sách...');
        await Future.delayed(const Duration(milliseconds: 1500));
      }
      if (gen != _autoGeneration || _popped) return;
      await Future.delayed(const Duration(milliseconds: 1000));
      await _scan();
    } finally {
      if (gen == _autoGeneration) _autoRunning = false;
    }
  }

  Future<void> _scan() async {
    if (_scanning || _popped) return;
    _scanning = true;
    _setStatus('Đang phân tích trang...');
    try {
      await _injectHook();
      await _controller.runJavaScript(ComicScanScripts.scan);
      // Kết quả về qua kênh JS -> _onScanMessage.
      // Hết 25s không thấy -> cho phép quét lại.
      Timer(const Duration(seconds: 25), () {
        if (_scanning && !_popped) {
          _scanning = false;
          _setStatus('Trang không trả kết quả quét. Bấm "Quét lại".');
        }
      });
    } catch (e) {
      _scanning = false;
      _setStatus('Lỗi khi quét: $e');
    }
  }

  void _onScanMessage(String message) {
    if (_popped) return;
    _scanning = false;
    Map<String, dynamic> raw;
    try {
      final d = jsonDecode(message);
      if (d is! Map) throw const FormatException('không phải object');
      raw = d.cast<String, dynamic>();
    } catch (e) {
      _setStatus('Dữ liệu quét không đọc được: $e. Bấm "Quét lại".');
      return;
    }
    if (raw['error'] != null) {
      _setStatus('Lỗi JavaScript khi quét: ${raw['error']}. Bấm "Quét lại".');
      return;
    }
    final result = ComicScanner.analyze(raw);
    if (result.images.isEmpty && widget.giveUpAfter != null) {
      _popped = true;
      Navigator.of(context).pop<ScanResult>(result);
      return;
    }
    // Trang giới thiệu có danh sách chapter (dù không có ảnh) cũng trả về.
    if (result.images.isEmpty && result.chapters.isEmpty) {
      _setStatus('Không tìm thấy ảnh trang truyện. Nếu trang cần bạn thao '
          'tác (bấm xác nhận, đăng nhập...), hãy làm trong khung bên dưới '
          'rồi bấm "Quét lại".');
      return;
    }
    _popped = true;
    Navigator.of(context).pop<ScanResult>(result);
  }

  void _rescan() {
    _autoGeneration++; // huỷ vòng tự cuộn
    _autoRunning = false;
    _scanning = false;
    _scan();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.batchLabel ?? 'Quét chapter'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Đóng',
          onPressed: () {
            _popped = true;
            _autoGeneration++;
            Navigator.of(context).pop();
          },
        ),
        actions: [
          TextButton.icon(
            onPressed: _rescan,
            icon: const Icon(Icons.refresh),
            label: const Text('Quét lại'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(_status)),
              ],
            ),
          ),
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
    );
  }
}
