import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the Mac app is moe.loaf.chat.ios, the same App ID as iOS', () {
    expect(File('macos/Runner/Configs/AppInfo.xcconfig').readAsStringSync(),
        contains('PRODUCT_BUNDLE_IDENTIFIER = moe.loaf.chat.ios\n'));
    final project = File('macos/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    expect(project.contains('moe.loaf.native'), isFalse);
  });
}
