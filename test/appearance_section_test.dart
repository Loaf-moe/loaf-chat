import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/settings/appearance_section.dart';
import 'package:loaf_native/ui/theme/appearance.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

/// Returns the controller so each test can unmount, then dispose it: the
/// controller's midnight Timer must be gone before testWidgets checks.
Future<AppearanceController> _pump(
  WidgetTester tester, {
  required DateTime now,
  AppearanceSettings settings = const AppearanceSettings(),
}) async {
  final c = AppearanceController(
    store: MemoryAppearanceStore(),
    settings: settings,
    clock: () => now,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: loafDarkTheme(),
      home: Scaffold(body: AppearanceSection(controller: c)),
    ),
  );
  return c;
}

Future<void> _done(WidgetTester tester, AppearanceController c) async {
  await tester.pumpWidget(const SizedBox());
  c.dispose();
}

final _inSeason = DateTime(2026, 10, 20);
final _offSeason = DateTime(2026, 12, 1);

void main() {
  testWidgets('offers both themes by name', (tester) async {
    final c = await _pump(tester, now: _offSeason);
    expect(find.text('Loaf Dark'), findsOneWidget);
    expect(find.text('日本'), findsOneWidget);
    await _done(tester, c);
  });

  testWidgets('tapping a theme picks it', (tester) async {
    final c = await _pump(tester, now: _offSeason);
    await tester.tap(find.text('日本'));
    await tester.pump();
    expect(c.chosen, LoafThemeId.nihon);
    await _done(tester, c);
  });

  testWidgets('the easter eggs box drives the flag', (tester) async {
    final c = await _pump(tester, now: _offSeason);
    expect(tester.widget<Checkbox>(find.byType(Checkbox).first).value, isTrue);
    await tester.tap(find.text('easter eggs'));
    await tester.pump();
    expect(c.easterEggs, isFalse);
    expect(tester.widget<Checkbox>(find.byType(Checkbox).first).value, isFalse);
    await _done(tester, c);
  });

  testWidgets('the external content box drives its flag, on to begin with', (
    tester,
  ) async {
    final c = await _pump(tester, now: _offSeason);
    expect(tester.widget<Checkbox>(find.byType(Checkbox).last).value, isTrue);
    await tester.tap(find.text('external content'));
    await tester.pump();
    expect(c.externalMedia, isFalse);
    expect(tester.widget<Checkbox>(find.byType(Checkbox).last).value, isFalse);
    // The easter eggs stay as they were.
    expect(c.easterEggs, isTrue);
    await _done(tester, c);
  });

  testWidgets('says so while the season overrides the pick', (tester) async {
    final c = await _pump(tester, now: _inSeason);
    expect(find.textContaining('until Nov 6'), findsOneWidget);

    c.setEasterEggs(false);
    await tester.pump();
    expect(find.textContaining('until Nov 6'), findsNothing);
    await _done(tester, c);
  });

  testWidgets('no override note out of season', (tester) async {
    final c = await _pump(tester, now: _offSeason);
    expect(find.textContaining('until Nov 6'), findsNothing);
    await _done(tester, c);
  });
}
