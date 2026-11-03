import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/call/call_tile.dart';

Widget _pulse({required bool reduceMotion}) => MediaQuery(
  data: MediaQueryData(disableAnimations: reduceMotion),
  child: const Pulse(child: SizedBox(width: 10, height: 10)),
);

void main() {
  testWidgets('pulses', (tester) async {
    await tester.pumpWidget(_pulse(reduceMotion: false));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
  });

  testWidgets('reduced motion: holds still, nothing ticking', (tester) async {
    await tester.pumpWidget(_pulse(reduceMotion: true));
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('motion back: pulses again', (tester) async {
    await tester.pumpWidget(_pulse(reduceMotion: true));
    await tester.pumpWidget(_pulse(reduceMotion: false));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
  });
}
