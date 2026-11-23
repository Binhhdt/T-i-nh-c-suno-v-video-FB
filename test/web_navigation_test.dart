import 'package:fb_video_downloader/web_navigation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  group('shouldAllowNavigation', () {
    test('chỉ cho phép http/https', () {
      expect(shouldAllowNavigation('https://www.facebook.com/x'), isTrue);
      expect(shouldAllowNavigation('http://facebook.com/x'), isTrue);
    });

    test('chặn fb:// — nguyên nhân lỗi ERR_UNKNOWN_URL_SCHEME', () {
      expect(
        shouldAllowNavigation(
          'fb://native_post/UzpfSTYxNTY1Njc4MjU2Nzk2OjEyM'
          '?wtsid=wt_0lu5lMgVV3LLU9CZu',
        ),
        isFalse,
      );
      expect(shouldAllowNavigation('fb://profile/123'), isFalse);
    });

    test('chặn các scheme khác (intent, tel, mailto, about, data)', () {
      expect(shouldAllowNavigation('intent://scan/#Intent;scheme=zxing;end'),
          isFalse);
      expect(shouldAllowNavigation('tel:+84123456789'), isFalse);
      expect(shouldAllowNavigation('mailto:a@b.com'), isFalse);
      expect(shouldAllowNavigation('about:blank'), isFalse);
      expect(shouldAllowNavigation('data:text/html,<h1>x</h1>'), isFalse);
    });

    test('URL rác -> chặn', () {
      expect(shouldAllowNavigation(''), isFalse);
      expect(shouldAllowNavigation('::::'), isFalse);
    });
  });

  group('navigationDecisionFor', () {
    test('fb:// -> prevent, https:// -> navigate', () {
      expect(
        navigationDecisionFor('fb://native_post/abc'),
        NavigationDecision.prevent,
      );
      expect(
        navigationDecisionFor('https://www.facebook.com/story.php?id=1'),
        NavigationDecision.navigate,
      );
    });
  });
}
