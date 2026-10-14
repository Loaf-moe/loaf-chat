import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/window/window_runner.dart';

void main() {
  test('Windows goes through the DLL, every other desktop the channel', () {
    expect(
      pickWindowRunner(platform: TargetPlatform.windows),
      isA<NativeWindowRunner>(),
    );
    for (final platform in [TargetPlatform.macOS, TargetPlatform.linux]) {
      expect(pickWindowRunner(platform: platform), isA<ChannelWindowRunner>());
    }
  });

  test('with no window to take over, Windows keeps its own frame', () async {
    // No runner window here (and off Windows, no DLL): attach says so
    // rather than throwing, and the buttons' calls do nothing.
    final runner = NativeWindowRunner();
    addTearDown(runner.detach);
    expect(await runner.attach((_) {}), isNull);
    await expectLater(runner.send('close'), completes);
    await expectLater(
      runner.send('setMaxButtonRect', {'x': 1, 'y': 2, 'w': 3, 'h': 4}),
      completes,
    );
  });
}
