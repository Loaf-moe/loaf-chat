import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/widgets/plays_on_hover.dart';
import 'package:loaf_native/ui/widgets/still_when_unfocused.dart';

class _Probe extends StatefulWidget {
  const _Probe();

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  Widget build(BuildContext context) => const SizedBox.square(dimension: 50);
}

final _probe = find.byType(_Probe);

Future<void> _pump(WidgetTester tester, {required bool reduceMotion}) =>
    tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: PlaysOnHover(child: _Probe())),
        ),
      ),
    );

bool _reduced(WidgetTester tester) =>
    MediaQuery.disableAnimationsOf(tester.element(_probe));

Future<TestGesture> _mouse(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  return mouse;
}

void main() {
  testWidgets('reduced motion, not hovered: stays still', (tester) async {
    await _pump(tester, reduceMotion: true);
    expect(_reduced(tester), isTrue);
  });

  testWidgets('reduced motion, hovered: moves', (tester) async {
    await _pump(tester, reduceMotion: true);
    final mouse = await _mouse(tester);
    await mouse.moveTo(tester.getCenter(_probe));
    await tester.pump();
    expect(_reduced(tester), isFalse);
  });

  testWidgets('reduced motion, pointer gone: still again', (tester) async {
    await _pump(tester, reduceMotion: true);
    final mouse = await _mouse(tester);
    await mouse.moveTo(tester.getCenter(_probe));
    await tester.pump();
    await mouse.moveTo(Offset.zero);
    await tester.pump();
    expect(_reduced(tester), isTrue);
  });

  testWidgets('motion on, not hovered: moves', (tester) async {
    await _pump(tester, reduceMotion: false);
    expect(_reduced(tester), isFalse);
  });

  testWidgets('hovering keeps the picture it holds', (tester) async {
    await _pump(tester, reduceMotion: true);
    final before = tester.state(_probe);
    final mouse = await _mouse(tester);
    await mouse.moveTo(tester.getCenter(_probe));
    await tester.pump();
    await mouse.moveTo(Offset.zero);
    await tester.pump();
    expect(tester.state(_probe), same(before));
  });

  group('under the app\'s focus', () {
    Future<void> pumpApp(WidgetTester tester, {required bool reduceMotion}) =>
        tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(disableAnimations: reduceMotion),
            child: const StillWhenUnfocused(
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: Center(child: PlaysOnHover(child: _Probe())),
              ),
            ),
          ),
        );

    testWidgets('unfocused, hovering stays still', (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await pumpApp(tester, reduceMotion: false);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      final mouse = await _mouse(tester);
      await mouse.moveTo(tester.getCenter(_probe));
      await tester.pump();
      expect(_reduced(tester), isTrue);
    });

    testWidgets('focused with motion reduced, hovering moves', (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await pumpApp(tester, reduceMotion: true);
      final mouse = await _mouse(tester);
      await mouse.moveTo(tester.getCenter(_probe));
      await tester.pump();
      expect(_reduced(tester), isFalse);
    });

    Future<TestGesture> hoverThenRefocus(WidgetTester tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await pumpApp(tester, reduceMotion: true);
      final mouse = await _mouse(tester);
      await mouse.moveTo(tester.getCenter(_probe));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      return mouse;
    }

    testWidgets('focused again, an old hover does not count', (tester) async {
      await hoverThenRefocus(tester);
      expect(_reduced(tester), isTrue);
    });

    testWidgets('focused again, moving over the picture plays it', (
      tester,
    ) async {
      final mouse = await hoverThenRefocus(tester);
      await mouse.moveBy(const Offset(1, 1));
      await tester.pump();
      expect(_reduced(tester), isFalse);
    });
  });
}
