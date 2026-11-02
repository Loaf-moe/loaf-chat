import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/theme/sakura.dart';
import 'package:loaf_native/ui/widgets/still_when_unfocused.dart';

Future<void> _pump(
  WidgetTester tester,
  ThemeData theme, {
  bool reduceMotion = false,
}) => tester.pumpWidget(
  MaterialApp(
    theme: theme,
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: const Scaffold(
          body: Column(
            children: [
              Expanded(
                child: Stack(fit: StackFit.expand, children: [SakuraPetals()]),
              ),
              ShinkansenRail(),
            ],
          ),
        ),
      ),
    ),
  ),
);

Finder _paintIn(Type type) =>
    find.descendant(of: find.byType(type), matching: find.byType(CustomPaint));

void main() {
  testWidgets('Loaf Dark draws nothing and takes no room', (tester) async {
    await _pump(tester, loafDarkTheme());
    expect(_paintIn(SakuraPetals), findsNothing);
    expect(_paintIn(ShinkansenRail), findsNothing);
    expect(tester.getSize(find.byType(ShinkansenRail)).height, 0);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('日本 draws petals and a moving train', (tester) async {
    await _pump(tester, loafNihonTheme());
    expect(_paintIn(SakuraPetals), findsOneWidget);
    expect(_paintIn(ShinkansenRail), findsOneWidget);
    expect(
      tester.getSize(find.byType(ShinkansenRail)).height,
      ShinkansenRail.height,
    );
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion: no petals, a still train, nothing ticking', (
    tester,
  ) async {
    await _pump(tester, loafNihonTheme(), reduceMotion: true);
    expect(_paintIn(SakuraPetals), findsNothing);
    expect(_paintIn(ShinkansenRail), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('decor never takes a tap', (tester) async {
    await _pump(tester, loafNihonTheme());
    expect(
      find.descendant(
        of: find.byType(ShinkansenRail),
        matching: find.byType(IgnorePointer),
      ),
      findsWidgets,
    );
    expect(
      find.descendant(
        of: find.byType(SakuraPetals),
        matching: find.byType(IgnorePointer),
      ),
      findsWidgets,
    );
  });

  testWidgets('each animation is isolated in its own repaint boundary', (
    tester,
  ) async {
    await _pump(tester, loafNihonTheme());
    for (final type in [SakuraPetals, ShinkansenRail]) {
      expect(
        find.descendant(
          of: find.descendant(
            of: find.byType(type),
            matching: find.byType(RepaintBoundary),
          ),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
        reason: '$type',
      );
    }
  });

  testWidgets('the rail steps aside while the keyboard is up', (tester) async {
    // On the view itself: the Scaffold in _pump strips MediaQuery's copy, as
    // it does in the app.
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await _pump(tester, loafNihonTheme());
    expect(tester.getSize(find.byType(ShinkansenRail)).height, 0);
    expect(_paintIn(ShinkansenRail), findsNothing);
  });

  testWidgets('every mount draws the same petals', (tester) async {
    List<double> petalXs() {
      final paint = tester.widget<CustomPaint>(_paintIn(SakuraPetals));
      return [
        for (final p in (paint.painter! as dynamic).petals) p.x as double,
      ];
    }

    await _pump(tester, loafNihonTheme());
    final first = petalXs();
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, loafNihonTheme());
    expect(petalXs(), first);
  });

  testWidgets('the rail follows the keyboard coming and going', (tester) async {
    addTearDown(tester.view.resetViewInsets);
    await _pump(tester, loafNihonTheme());
    expect(
      tester.getSize(find.byType(ShinkansenRail)).height,
      ShinkansenRail.height,
    );

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    expect(tester.getSize(find.byType(ShinkansenRail)).height, 0);

    tester.view.resetViewInsets();
    await tester.pump();
    expect(
      tester.getSize(find.byType(ShinkansenRail)).height,
      ShinkansenRail.height,
    );
  });

  testWidgets('each animation is clipped to its own bounds', (tester) async {
    await _pump(tester, loafNihonTheme());
    for (final type in [SakuraPetals, ShinkansenRail]) {
      expect(
        find.descendant(
          of: find.descendant(
            of: find.byType(type),
            matching: find.byType(ClipRect),
          ),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
        reason: '$type',
      );
    }
  });

  group('under the app\'s focus', () {
    Future<void> pumpApp(WidgetTester tester, {bool reduceMotion = false}) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      return tester.pumpWidget(
        MaterialApp(
          theme: loafNihonTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(disableAnimations: reduceMotion),
            child: StillWhenUnfocused(child: child!),
          ),
          home: const Scaffold(
            body: Column(
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [SakuraPetals()],
                  ),
                ),
                ShinkansenRail(),
              ],
            ),
          ),
        ),
      );
    }

    Future<void> become(WidgetTester tester, AppLifecycleState state) async {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }

    /// What each decor shows right now, as pixels.
    Future<List<List<int>>> picture(WidgetTester tester) async {
      final out = <List<int>>[];
      for (final type in [SakuraPetals, ShinkansenRail]) {
        final boundary = tester.renderObject(
          find
              .descendant(
                of: find.byType(type),
                matching: find.byType(RepaintBoundary),
              )
              .first,
        ) as RenderRepaintBoundary;
        final bytes = await tester.runAsync(() async {
          final image = await boundary.toImage();
          final data = await image.toByteData();
          image.dispose();
          return data!.buffer.asUint8List().toList();
        });
        out.add(bytes!);
      }
      return out;
    }

    testWidgets('unfocused: petals and train stay, nothing ticks', (
      tester,
    ) async {
      await pumpApp(tester);
      await become(tester, AppLifecycleState.inactive);
      expect(_paintIn(SakuraPetals), findsOneWidget);
      expect(_paintIn(ShinkansenRail), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('unfocused mid-crossing: the scene holds where it was', (
      tester,
    ) async {
      await pumpApp(tester);
      await tester.pump(const Duration(seconds: 3));
      final before = await picture(tester);
      await become(tester, AppLifecycleState.inactive);
      await tester.pump(const Duration(seconds: 5));
      expect(await picture(tester), before);
    });

    testWidgets('focused again: it goes on from where it held', (tester) async {
      await pumpApp(tester);
      await tester.pump(const Duration(seconds: 3));
      await become(tester, AppLifecycleState.inactive);
      final held = await picture(tester);
      await become(tester, AppLifecycleState.resumed);
      await tester.pump();
      expect(await picture(tester), held);
      await tester.pump(const Duration(seconds: 1));
      expect(await picture(tester), isNot(held));
    });

    for (final state in [
      AppLifecycleState.resumed,
      AppLifecycleState.inactive,
    ]) {
      testWidgets(
        'motion turned off, ${state.name}: no petals, a still train',
        (tester) async {
          await pumpApp(tester, reduceMotion: true);
          await become(tester, state);
          expect(_paintIn(SakuraPetals), findsNothing);
          expect(_paintIn(ShinkansenRail), findsOneWidget);
          expect(tester.binding.transientCallbackCount, 0);
        },
      );
    }
  });
}
