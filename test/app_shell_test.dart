import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:loaf_native/ui/members/member_list.dart';
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

  testWidgets('on a phone the members button opens the member drawer', (
    tester,
  ) async {
    await _pumpShell(tester, const Size(390, 844));

    expect(find.byType(MemberList), findsNothing);

    await tester.tap(find.byIcon(LucideIcons.users));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(MemberList), findsOneWidget);
    expect(find.text('ADMINS — 1'), findsOneWidget);
  });

  testWidgets('on a desktop the member column is shown and the button '
      'toggles it', (tester) async {
    await _pumpShell(tester, const Size(1440, 900));

    expect(find.byType(MemberList), findsOneWidget);

    await tester.tap(find.byIcon(LucideIcons.users));
    await tester.pumpAndSettle();
    expect(find.byType(MemberList), findsNothing);

    await tester.tap(find.byIcon(LucideIcons.users));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(MemberList), findsOneWidget);
  });

  testWidgets('reply shows a chip above the composer that can be cancelled', (
    tester,
  ) async {
    await _pumpShell(tester, const Size(390, 844));

    await tester.longPress(
      find.textContaining('ok that crumb is unreasonable'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();

    expect(find.text('replying to '), findsOneWidget);
    await tester.tap(find.byTooltip('Cancel reply'));
    await tester.pumpAndSettle();
    expect(find.text('replying to '), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('edit fills the composer with the message', (tester) async {
    await _pumpShell(tester, const Size(390, 844));

    await tester.longPress(
      find.textContaining('ok that crumb is unreasonable'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    expect(find.text('editing message'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, 'ok that crumb is unreasonable');

    await tester.tap(find.byTooltip('Cancel edit'));
    await tester.pumpAndSettle();
    expect(field.controller?.text, isEmpty);
  });

  testWidgets('notices live in the rail, not as banners over the channel', (
    tester,
  ) async {
    await _pumpShell(tester, const Size(1440, 900));

    // Nothing app-level is spread across the reading surface…
    expect(find.text('verify this session'), findsNothing);
    // …it waits at the bottom of the rail instead.
    expect(find.byTooltip('verify this session'), findsOneWidget);
  });

  testWidgets(
    'a phone never shows the update notice',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      await _pumpShell(tester, const Size(390, 844));

      await tester.tap(find.byIcon(LucideIcons.menu));
      await tester.pumpAndSettle();

      expect(find.byTooltip('verify this session'), findsOneWidget);
      expect(find.byTooltip('loaf 0.3.0 is ready'), findsNothing);
    },
  );

  testWidgets(
    'a computer shows the update notice',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      await _pumpShell(tester, const Size(1440, 900));
      expect(find.byTooltip('loaf 0.3.0 is ready'), findsOneWidget);
    },
  );

  testWidgets('on a phone the menu button carries a dot while verification '
      'is pending', (tester) async {
    await _pumpShell(tester, const Size(390, 844));

    // The rail is behind the drawer, so something outside it has to say
    // there is a notice waiting.
    expect(find.byKey(const ValueKey('navigation-attention')), findsOneWidget);
  });

  group('channels you have not joined', () {
    // The Starter Pack mock has three: #announcements, late night vc, #poker.
    Finder pills() => find.text('join');

    testWidgets('appear at the bottom of their own category, tagged', (
      tester,
    ) async {
      await _pumpShell(tester, const Size(1440, 900));

      expect(pills(), findsNWidgets(3));
      // Listed early in the fixture, but sorted after the joined channels.
      final announcements = tester.getRect(find.text('announcements'));
      expect(
        announcements.top,
        greaterThan(tester.getRect(find.text('planning')).top),
      );
      // …and still inside GENERAL, above the next category.
      expect(
        announcements.top,
        lessThan(tester.getRect(find.text('VOICE')).top),
      );
    });

    testWidgets('joining a text channel joins it and opens it', (tester) async {
      await _pumpShell(tester, const Size(1440, 900));

      await tester.tap(find.text('poker'));
      await tester.pumpAndSettle();

      expect(pills(), findsNWidgets(2));
      // Open in the header as well as the list.
      expect(find.text('poker'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('joining a voice channel does not connect you', (tester) async {
      await _pumpShell(tester, const Size(1440, 900));

      await tester.tap(find.text('late night vc'));
      await tester.pumpAndSettle();

      expect(pills(), findsNWidgets(2));
      expect(find.text('Voice connected'), findsNothing);

      // Once joined, it behaves like any voice channel.
      await tester.tap(find.text('late night vc'));
      await tester.pumpAndSettle();
      expect(find.text('Voice connected'), findsOneWidget);
    });

    testWidgets('are hidden when their category is collapsed', (tester) async {
      await _pumpShell(tester, const Size(1440, 900));

      await tester.tap(find.text('GAME NIGHT'));
      await tester.pumpAndSettle();

      expect(find.text('poker'), findsNothing);
    });
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

    // It floats over both columns, inset from each edge.
    final bar = tester.getRect(find.byType(UserBar));
    expect(
      bar.width,
      LoafShell.railWidth + LoafShell.sidebarWidth - UserBar.inset * 2,
      reason: 'the panel should span both navigation columns',
    );
    expect(
      bar.left,
      UserBar.inset,
      reason: 'the panel should start in the rail column, not after it',
    );
  });

  testWidgets('deafening implies muting, and undeafening restores both', (
    tester,
  ) async {
    await _pumpShell(tester, const Size(1440, 900));

    expect(find.byTooltip('Mute'), findsOneWidget);
    expect(find.byTooltip('Deafen'), findsOneWidget);

    await tester.tap(find.byTooltip('Deafen'));
    await tester.pumpAndSettle();

    // Talking to people you cannot hear is not a state worth offering.
    expect(find.byTooltip('Undeafen'), findsOneWidget);
    expect(find.byIcon(LucideIcons.micOff), findsOneWidget);

    await tester.tap(find.byTooltip('Undeafen'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Deafen'), findsOneWidget);
    expect(
      find.byTooltip('Mute'),
      findsOneWidget,
      reason: 'coming back should not leave you silently muted',
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
