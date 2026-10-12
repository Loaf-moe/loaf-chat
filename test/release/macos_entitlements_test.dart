import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // The sandbox and the hardened runtime both refuse the microphone without
  // it, whatever Info.plist says and whatever the person answers.
  for (final name in ['DebugProfile', 'Release']) {
    test('the $name build of the Mac app may open a microphone', () {
      expect(
        File('macos/Runner/$name.entitlements').readAsStringSync(),
        matches(
          RegExp(
            r'<key>com\.apple\.security\.device\.audio-input</key>\s*<true/>',
          ),
        ),
      );
    });
  }
}
