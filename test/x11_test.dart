import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/platform/x11.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('loaf/window');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  /// Answers `x11` with [answer]; returns how many times it was asked.
  int Function() runnerSays(bool answer) {
    var asked = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'x11') return null;
      asked++;
      return answer;
    });
    return () => asked;
  }

  for (final answer in [true, false]) {
    test('Linux: the runner says $answer', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      runnerSays(answer);
      expect(await drawsThroughX11(), answer);
    });
  }

  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    test('${platform.name}: never, and the runner is not asked', () async {
      debugDefaultTargetPlatformOverride = platform;
      final asked = runnerSays(true);
      expect(await drawsThroughX11(), isFalse);
      expect(asked(), 0);
    });
  }
}
