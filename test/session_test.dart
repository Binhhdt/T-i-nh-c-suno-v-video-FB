import 'package:fb_video_downloader/session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('buildCookieHeader ghép đúng định dạng và bỏ cookie rỗng', () {
    expect(
      FacebookSession.buildCookieHeader(
        {'c_user': '123', 'xs': 'abc', 'rong': ''},
      ),
      'c_user=123; xs=abc',
    );
    expect(FacebookSession.buildCookieHeader({}), '');
  });

  test('hasLoginCookies cần đủ c_user và xs', () {
    expect(
      FacebookSession.hasLoginCookies({'c_user': '1', 'xs': '2'}),
      isTrue,
    );
    expect(FacebookSession.hasLoginCookies({'c_user': '1'}), isFalse);
    expect(FacebookSession.hasLoginCookies({'xs': '2'}), isFalse);
    expect(FacebookSession.hasLoginCookies({}), isFalse);
  });
}
