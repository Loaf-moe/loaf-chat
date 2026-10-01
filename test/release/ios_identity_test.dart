import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/matrix/sso_browser.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final project = _read('ios/Runner.xcodeproj/project.pbxproj');

  test('the iOS app is moe.loaf.chat.ios in every configuration', () {
    final ids = RegExp(r'PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);')
        .allMatches(project)
        .map((m) => m.group(1))
        .toList();
    expect(ids.where((id) => id == 'moe.loaf.chat.ios'), hasLength(3));
    expect(
      ids.where((id) => id == 'moe.loaf.chat.ios.RunnerTests'),
      hasLength(3),
    );
    expect(ids, hasLength(6));
  });

  test('nothing in the iOS project still names moe.loaf.native', () {
    // Not `contains`: a failure would print the whole project file.
    expect(project.contains('moe.loaf.native'), isFalse);
  });

  test('builds declare their encryption, so none waits on compliance', () {
    expect(
      _read('ios/Runner/Info.plist'),
      matches(RegExp(r'<key>ITSAppUsesNonExemptEncryption</key>\s*<false/>')),
    );
  });

  test('the SSO callback scheme did not follow the bundle id', () {
    // Kanidm's redirect is registered against this scheme; it is a fixed
    // string on purpose, not the bundle id.
    expect(SheetSsoBrowser.scheme, 'moe.loaf.native');
  });
}
