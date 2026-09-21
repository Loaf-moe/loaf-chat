import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:loaf_native/ui/shell/app_shell.dart';
import 'package:loaf_native/ui/shell/user_bar.dart';
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

  testWidgets('reaction pills hug their content and sit on one row', (
    tester,
  ) async {
    await _pumpShell(tester, const Size(1440, 900));

    // The most recent message carries three reactions.
    final pills = [find.text('😍 7'), find.text('🔥 3'), find.text('🥖 1')];
    for (final pill in pills) {
      expect(pill, findsOneWidget, reason: 'fixture reaction missing');
    }

    final boxes = pills.map(tester.getRect).toList();

    // A Container with an alignment and no width expands to the parent's
    // width, which puts one pill per line. Content-width pills are narrow.
    for (final box in boxes) {
      expect(
        box.width,
        lessThan(80),
        reason:
            'a reaction pill went '
            'full-bleed instead of hugging its label',
      );
    }
    // Same row, left to right.
    expect(boxes[1].top, boxes.first.top);
    expect(boxes[2].top, boxes.first.top);
    expect(boxes[1].left, greaterThan(boxes[0].left));
    expect(boxes[2].left, greaterThan(boxes[1].left));
  });

  testWidgets('composer controls share one baseline', (tester) async {
    await _pumpShell(tester, const Size(1440, 900));

    final send = tester.getRect(find.byIcon(LucideIcons.send));
    final attach = tester.getRect(find.byIcon(LucideIcons.plus).last);
    final emoji = tester.getRect(find.byIcon(LucideIcons.smile));

    // Equal-height controls bottom-aligned means their centres match too.
    expect((send.center.dy - emoji.center.dy).abs(), lessThan(1.0));
    expect((attach.center.dy - emoji.center.dy).abs(), lessThan(1.0));

    // Deliberately not asserting where the TEXT sits. flutter test renders
    // with a stub font (ascent 0.75em / descent 0.25em) rather than Outfit,
    // so any text-geometry assertion here measures the wrong typeface and
    // passes or fails for reasons unrelated to the real app.
  });

  testWidgets('the account panel appears once, spanning both columns', (
    tester,
  ) async {
    await _pumpShell(tester, const Size(1440, 900));

    // The rail and the channel list each used to carry their own avatar.
    expect(find.byType(UserBar), findsOneWidget);
    expect(find.text('@faore'), findsOneWidget);

    final bar = tester.getRect(find.byType(UserBar));
    expect(
      bar.width,
      LoafShell.railWidth + LoafShell.sidebarWidth,
      reason: 'the bar should run under both navigation columns',
    );
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
