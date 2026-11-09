import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/widgets/loaf_progress.dart';
import 'package:loaf_native/ui/widgets/still_when_unfocused.dart';

final _key = GlobalKey();

Future<void> _pump(
  WidgetTester tester,
  Widget indicator, {
  required bool reduceMotion,
}) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  return tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: StillWhenUnfocused(child: child!),
      ),
      home: Center(
        child: RepaintBoundary(
          key: _key,
          child: SizedBox(width: 40, height: 40, child: indicator),
        ),
      ),
    ),
  );
}

/// What the indicator shows right now, as pixels.
Future<List<int>> _snap(WidgetTester tester) async {
  final boundary =
      _key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData();
    image.dispose();
    return data!.buffer.asUint8List().toList();
  });
  return bytes!;
}

const _step = Duration(milliseconds: 125);

void main() {
  for (final (name, indicator) in [
    ('spinner', const LoafSpinner()),
    ('bar', const LoafProgressBar()),
  ]) {
    group(name, () {
      testWidgets('motion on: the stock indicator runs', (tester) async {
        await _pump(tester, indicator, reduceMotion: false);
        expect(tester.binding.transientCallbackCount, greaterThan(0));
      });

      testWidgets('reduced: steps, eight to a second, with no ticker', (
        tester,
      ) async {
        await _pump(tester, indicator, reduceMotion: true);
        expect(tester.binding.transientCallbackCount, 0);
        final start = await _snap(tester);
        await tester.pump(_step);
        expect(await _snap(tester), isNot(start));
        await tester.pump(_step * 7);
        expect(await _snap(tester), start);
      });

      testWidgets('reduced and unfocused: holds where it was', (tester) async {
        await _pump(tester, indicator, reduceMotion: true);
        await tester.pump(_step * 3);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        final held = await _snap(tester);
        await tester.pump(const Duration(seconds: 1));
        expect(await _snap(tester), held);
      });

      testWidgets('focused again: steps on from where it held', (tester) async {
        await _pump(tester, indicator, reduceMotion: true);
        await tester.pump(_step * 3);
        final third = await _snap(tester);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump(const Duration(seconds: 1));
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(await _snap(tester), third);
        await tester.pump(_step);
        expect(await _snap(tester), isNot(third));
      });
    });
  }

  for (final (name, determinate) in [
    ('spinner', const LoafSpinner(value: 0.4)),
    ('bar', const LoafProgressBar(value: 0.4)),
  ]) {
    testWidgets('$name with a value, reduced: shows it and does not move', (
      tester,
    ) async {
      await _pump(tester, determinate, reduceMotion: true);
      expect(tester.binding.transientCallbackCount, 0);
      final shown = await _snap(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(await _snap(tester), shown);
    });
  }

  testWidgets('a value arriving while stepping stops the stepping', (
    tester,
  ) async {
    await _pump(tester, const LoafSpinner(), reduceMotion: true);
    await tester.pump(_step);
    await _pump(tester, const LoafSpinner(value: 0.4), reduceMotion: true);
    final shown = await _snap(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(await _snap(tester), shown);
  });

  for (final (name, indicator, type) in [
    ('spinner', const LoafSpinner(), LoafSpinner),
    ('bar', const LoafProgressBar(), LoafProgressBar),
  ]) {
    testWidgets('$name stepping says it is loading, not how far', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, indicator, reduceMotion: true);
      final data = tester.getSemantics(find.byType(type)).getSemanticsData();
      expect(data.value, isEmpty);
      expect(data.role, SemanticsRole.loadingSpinner);
      handle.dispose();
    });
  }
}
