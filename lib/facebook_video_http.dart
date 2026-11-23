import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

bool _within(String host, String domain) =>
    host == domain || host.endsWith('.$domain');

bool _safe(Uri uri) =>
    uri.scheme == 'https' &&
    uri.userInfo.isEmpty &&
    uri.port == 443 &&
    !uri.host.endsWith('.');

bool isFacebookPage(Uri uri) =>
    _safe(uri) &&
    (_within(uri.host, 'facebook.com') ||
        uri.host == 'fb.watch' ||
        uri.host == 'fb.me');

bool canSendFacebookCookie(Uri uri) =>
    _safe(uri) && _within(uri.host, 'facebook.com');

bool isFacebookMedia(Uri uri) =>
    _safe(uri) &&
    (_within(uri.host, 'fbcdn.net') ||
        _within(uri.host, 'fbsbx.com') ||
        _within(uri.host, 'facebook.com'));

class FacebookVideoException implements Exception {
  const FacebookVideoException(
    this.message, {
    this.retryable = false,
    this.expired = false,
  });
  final String message;
  final bool retryable;
  final bool expired;

  @override
  String toString() => message;
}

class FacebookVideoHttp {
  FacebookVideoHttp([http.Client? client])
    : _client = client ?? _secureClient();

  static const userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
  final http.Client _client;

  static bool _publicAddress(InternetAddress ip) {
    final b = ip.rawAddress;
    if (b.length == 16) {
      // Only global unicast. Exclude transition and benchmarking ranges.
      return b[0] & 0xe0 == 0x20 &&
          !(b[0] == 0x20 && (b[1] == 0x02 || b[1] == 0x01 && b[2] < 0x20)) &&
          !(b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8) &&
          !(b[0] == 0x3f && b[1] == 0xff);
    }
    return b[0] > 0 &&
        b[0] < 224 &&
        !{10, 127}.contains(b[0]) &&
        !(b[0] == 100 && b[1] >= 64 && b[1] <= 127) &&
        !(b[0] == 169 && b[1] == 254) &&
        !(b[0] == 172 && b[1] >= 16 && b[1] <= 31) &&
        !(b[0] == 192 && {0, 168}.contains(b[1])) &&
        !(b[0] == 198 && {18, 19}.contains(b[1]));
  }

  static http.Client _secureClient() {
    final client = HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 15)
      ..findProxy = (_) => 'DIRECT';
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      final addresses = await InternetAddress.lookup(uri.host)
          .timeout(const Duration(seconds: 10));
      final allowed = addresses.where(_publicAddress);
      if (allowed.isEmpty) throw const SocketException('Địa chỉ mạng bị chặn.');
      return Socket.startConnect(allowed.first, uri.port);
    };
    return IOClient(client);
  }

  Future<({http.StreamedResponse response, Uri uri})> send(
    Uri uri, {
    bool page = false,
    String? cookie,
    String method = 'GET',
    Map<String, String> headers = const {},
    Future<void>? abort,
  }) async {
    for (var hop = 0; hop <= 5; hop++) {
      if (!(page ? isFacebookPage(uri) : isFacebookMedia(uri))) {
        throw const FacebookVideoException(
          'Nguồn hoặc chuyển hướng ngoài Facebook bị chặn.',
        );
      }
      final request = http.AbortableRequest(method, uri, abortTrigger: abort)
        ..followRedirects = false
        ..headers.addAll({
          'User-Agent': userAgent,
          'Accept-Encoding': 'identity',
          if (page) 'Accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
          if (page && cookie != null && canSendFacebookCookie(uri))
            'Cookie': cookie,
          ...headers,
        });
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 25));
      if (!{301, 302, 303, 307, 308}.contains(response.statusCode)) {
        return (response: response, uri: uri);
      }
      await discard(response);
      final location = response.headers['location'];
      if (location == null) break;
      uri = uri.resolve(location);
    }
    throw const FacebookVideoException('Facebook chuyển hướng quá nhiều lần.');
  }

  static Future<void> discard(http.StreamedResponse response) =>
      response.stream.listen(null).cancel();

  static void checkStatus(int code) {
    if (code == 200) return;
    throw FacebookVideoException(
      'Máy chủ Facebook trả mã HTTP $code.',
      expired: {401, 403, 404, 410}.contains(code),
      retryable: code == 408 || code == 429 || code >= 500,
    );
  }

  Future<({Uint8List bytes, Uri uri})> read(
    Uri uri, {
    bool page = false,
    String? cookie,
    int limit = 2 * 1024 * 1024,
    Future<void>? abort,
  }) async {
    final result = await send(uri, page: page, cookie: cookie, abort: abort);
    final response = result.response;
    if (response.statusCode != 200 || (response.contentLength ?? 0) > limit) {
      await discard(response);
      checkStatus(response.statusCode);
      throw const FacebookVideoException('Phản hồi vượt giới hạn dung lượng.');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 20),
    )) {
      if (bytes.length + chunk.length > limit) {
        throw const FacebookVideoException(
          'Phản hồi vượt giới hạn dung lượng.',
        );
      }
      bytes.add(chunk);
    }
    return (bytes: bytes.takeBytes(), uri: result.uri);
  }

  static String text(Uint8List bytes) =>
      utf8.decode(bytes, allowMalformed: true);
  void close() => _client.close();
}
