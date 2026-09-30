import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/shell/idle_watcher.dart';

Future<List<bool>> _pump(WidgetTester tester, {required bool desktop}) async {
  final calls = <bool>[];
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: IdleWatcher(
        desktop: desktop,
        onAway: calls.add,
        child: const SizedBox.expand(),
      ),
    ),
  );
  return calls;
}

void main() {
  testWidgets('computer: ten quiet minutes is away, input is back', (
    tester,
  ) async {
    final calls = await _pump(tester, desktop: true);
    await tester.pump(const Duration(minutes: 10));
    expect(calls, [true]);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(const Offset(20, 20));
    expect(calls, [true, false]);
  });

  testWidgets('computer: input resets the clock', (tester) async {
    final calls = await _pump(tester, desktop: true);
    await tester.pump(const Duration(minutes: 9));
    await tester.sendKeyEvent(LogicalKeyboardKey.shift);
    await tester.pump(const Duration(minutes: 9));
    expect(calls, isEmpty);
  });

  testWidgets('computer: more input while back says nothing more', (
    tester,
  ) async {
    final calls = await _pump(tester, desktop: true);
    await tester.tapAt(const Offset(10, 10));
    await tester.sendKeyEvent(LogicalKeyboardKey.shift);
    expect(calls, isEmpty);
  });

  testWidgets('phone: backgrounding is away', (tester) async {
    final calls = await _pump(tester, desktop: false);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(calls, [true]);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(calls, [true, false]);
  });

  testWidgets('phone: quiet minutes are not away', (tester) async {
    final calls = await _pump(tester, desktop: false);
    await tester.pump(const Duration(minutes: 30));
    expect(calls, isEmpty);
  });

  testWidgets('disposed, it stops listening', (tester) async {
    final calls = await _pump(tester, desktop: true);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 30));
    await tester.sendKeyEvent(LogicalKeyboardKey.shift);
    expect(calls, isEmpty);
  });
}
