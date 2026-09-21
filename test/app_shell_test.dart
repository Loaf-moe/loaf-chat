import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:loaf_native/ui/shell/app_shell.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

/// Renders the shell at [size] and returns once it has settled. A layout
/// overflow throws during paint, so simply getting here without an exception
/// is most of what these tests assert.
Future<void> _pumpShell(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: loafLightTheme(),
      darkTheme: loafDarkTheme(),
      themeMode: ThemeMode.dark,
      home: const AppShell(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lays out on a phone without overflowing', (tester) async {
    await _pumpShell(tester, const Size(390, 844)); // iPhone 15

    expect(tester.takeException(), isNull);
    // Navigation is behind the drawer, so the space name is not on screen…
    expect(find.text('The Starter Pack'), findsNothing);
    // …but the channel being read is.
    expect(find.text('general'), findsOneWidget);
  });

  testWidgets('lays out on a desktop without overflowing', (tester) async {
    await _pumpShell(tester, const Size(1440, 900));

    expect(tester.takeException(), isNull);
    // All three panes are visible at once.
    expect(find.text('The Starter Pack'), findsOneWidget);
    expect(find.text('general'), findsWidgets);
    expect(find.text('the hangout'), findsOneWidget);
  });

  testWidgets('the phone drawer opens and picking a channel closes it', (
    tester,
  ) async {
    await _pumpShell(tester, const Size(390, 844));

    await tester.tap(find.byIcon(LucideIcons.menu));
    await tester.pumpAndSettle();
    expect(find.text('The Starter Pack'), findsOneWidget);

    await tester.tap(find.text('kitchen'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.text('The Starter Pack'),
      findsNothing,
      reason:
          'the drawer '
          'should close once you have chosen where to go',
    );
    expect(find.text('kitchen'), findsOneWidget);
  });

  testWidgets('joining a voice channel shows the call bar and keeps you '
      'in the channel you were reading', (tester) async {
    await _pumpShell(tester, const Size(1440, 900));

    expect(find.text('Voice connected'), findsNothing);

    await tester.tap(find.text('the hangout'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Voice connected'), findsOneWidget);
    expect(
      find.text('the hangout · The Starter Pack'),
      findsOneWidget,
      reason: 'the bar names the channel and the space it belongs to',
    );
    // The point of ambient voice: reading position is untouched.
    expect(find.text('general'), findsWidgets);

    // Tapping it again leaves.
    await tester.tap(find.text('the hangout'));
    await tester.pumpAndSettle();
    expect(find.text('Voice connected'), findsNothing);
  });

  testWidgets('switching spaces remembers where you were', (tester) async {
    await _pumpShell(tester, const Size(1440, 900));

    await tester.tap(find.text('chess'));
    await tester.pumpAndSettle();
    expect(find.text('Rye Devs'), findsNothing);

    // Rye Devs' rail avatar, by its initials.
    await tester.tap(find.text('RD'));
    await tester.pumpAndSettle();
    expect(find.text('Rye Devs'), findsOneWidget);

    await tester.tap(find.text('TS'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.text('chess'),
      findsWidgets,
      reason:
          'coming back to a space '
          'should return you to the channel you left, not the first one',
    );
  });
}
