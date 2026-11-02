import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/widgets/still_when_unfocused.dart';

/// Pumps the widget around a probe; returns what the probe last read.
Future<bool Function()> _pump(
  WidgetTester tester, {
  bool systemReduceMotion = false,
}) async {
  late bool reduced;
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(disableAnimations: systemReduceMotion),
      child: StillWhenUnfocused(
        child: Builder(
          builder: (context) {
            reduced = MediaQuery.disableAnimationsOf(context);
            return const SizedBox();
          },
        ),
      ),
    ),
  );
  return () => reduced;
}

Future<void> _become(WidgetTester tester, AppLifecycleState state) async {
  tester.binding.handleAppLifecycleStateChanged(state);
  await tester.pump();
}

void main() {
  testWidgets('focused, motion stays on', (tester) async {
    await _become(tester, AppLifecycleState.resumed);
    final reduced = await _pump(tester);
    expect(reduced(), isFalse);
  });

  // The platform steps down through each state in turn; hidden and paused
  // stop frames, so what they leave is what inactive set.
  const away = [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ];
  for (final (i, state) in away.indexed) {
    testWidgets('${state.name}, motion is reduced', (tester) async {
      final reduced = await _pump(tester);
      for (final step in away.take(i + 1)) {
        await _become(tester, step);
      }
      expect(reduced(), isTrue);
    });
  }

  testWidgets('put up while unfocused, motion is reduced from the start', (
    tester,
  ) async {
    await _become(tester, AppLifecycleState.inactive);
    final reduced = await _pump(tester);
    expect(reduced(), isTrue);
  });

  testWidgets('focused again, motion comes back', (tester) async {
    final reduced = await _pump(tester);
    await _become(tester, AppLifecycleState.inactive);
    await _become(tester, AppLifecycleState.resumed);
    expect(reduced(), isFalse);
  });

  testWidgets('focused, the system asking for less motion still holds', (
    tester,
  ) async {
    await _become(tester, AppLifecycleState.resumed);
    final reduced = await _pump(tester, systemReduceMotion: true);
    expect(reduced(), isTrue);
  });
}
