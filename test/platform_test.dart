import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/platform.dart';

void main() {
  testWidgets(
    'no system sign-in window means the browser',
    variant: TargetPlatformVariant(const {
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
    (tester) async {
      expect(ssoInBrowser, isTrue);
    },
  );

  testWidgets(
    'a system sign-in window means no browser',
    variant: TargetPlatformVariant(const {
      TargetPlatform.macOS,
      TargetPlatform.iOS,
    }),
    (tester) async {
      expect(ssoInBrowser, isFalse);
    },
  );
}
