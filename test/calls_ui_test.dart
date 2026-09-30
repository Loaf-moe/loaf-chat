import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:loaf_native/ui/call/call_controller.dart';
import 'package:loaf_native/ui/shell/app_shell.dart';
import 'package:loaf_native/ui/shell/channel_list.dart';
import 'package:loaf_native/ui/shell/spaces_rail.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

final _mobile = TargetPlatformVariant.only(TargetPlatform.iOS);
final _android = TargetPlatformVariant.only(TargetPlatform.android);
final _desktop = TargetPlatformVariant.only(TargetPlatform.macOS);

const _phone = Size(390, 844);
const _wide = Size(1440, 900);

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

/// Lets the mock connection finish. Not pumpAndSettle: ringing pulses
/// forever, and a live call passes the speaking ring around on a timer.
Future<void> _connect(WidgetTester tester) async {
  await tester.pump(CallController.connectDelay);
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _openDrawer(WidgetTester tester) async {
  await tester.tap(find.byIcon(LucideIcons.menu));
  await tester.pumpAndSettle();
}

Future<void> _openHome(WidgetTester tester) async {
  await tester.tap(find.byKey(SpacesRail.homeKey));
  await tester.pumpAndSettle();
}

Finder _callView() => find.byKey(const ValueKey('call-view'));
Finder _tile(String id) => find.byKey(ValueKey('tile-$id'));
Finder _panel() => find.byKey(const ValueKey('dm-call-panel'));
Finder _incoming() => find.byKey(const ValueKey('incoming-call'));

Future<void> _debug(WidgetTester tester, String item) async {
  await tester.tap(find.byTooltip('Debug'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(item).last);
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  group('voice channels', () {
    testWidgets(
      'on a computer, a click connects and the call replaces the channel',
      variant: _desktop,
      (tester) async {
        await _pumpShell(tester, _wide);

        await tester.tap(find.text('the hangout'));
        await tester.pump();
        expect(find.text('connecting…'), findsWidgets);

        await _connect(tester);
        expect(_callView(), findsOneWidget);
        expect(_tile('@mika'), findsOneWidget);
        expect(_tile('@faore'), findsOneWidget);
        expect(
          find.text('Voice connected'),
          findsNothing,
          reason: 'the bar is for looking elsewhere, not at the call itself',
        );

        await tester.tap(find.text('kitchen'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(_callView(), findsNothing);
        expect(find.text('Voice connected'), findsOneWidget);

        await tester.tap(find.text('Voice connected'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(_callView(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('on a phone, a tap opens the lobby first', variant: _mobile, (
      tester,
    ) async {
      await _pumpShell(tester, _phone);
      await _openDrawer(tester);

      await tester.tap(find.text('the hangout'));
      await tester.pumpAndSettle();

      expect(find.text('join voice'), findsOneWidget);
      expect(_callView(), findsNothing);
      expect(_tile('@mika'), findsOneWidget);

      await tester.tap(find.text('join voice'));
      await _connect(tester);

      expect(_callView(), findsOneWidget);
      expect(find.text('join voice'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'a channel you have not joined joins without connecting',
      variant: _desktop,
      (tester) async {
        await _pumpShell(tester, _wide);

        await tester.tap(find.text('late night vc'));
        await tester.pumpAndSettle();

        expect(find.text('join voice'), findsOneWidget);
        expect(_callView(), findsNothing);
      },
    );

    testWidgets('alone, you see just your own tile', variant: _desktop, (
      tester,
    ) async {
      await _pumpShell(tester, _wide);

      await tester.tap(find.text('quiet baking'));
      await _connect(tester);

      expect(_tile('@faore'), findsOneWidget);
      expect(
        find.descendant(of: _callView(), matching: find.textContaining('here')),
        findsNothing,
      );
    });

    testWidgets(
      'leave disconnects and returns to the lobby',
      variant: _desktop,
      (tester) async {
        await _pumpShell(tester, _wide);
        await tester.tap(find.text('the hangout'));
        await _connect(tester);

        await tester.tap(find.byTooltip('Leave call'));
        await tester.pumpAndSettle();

        expect(_callView(), findsNothing);
        expect(find.text('join voice'), findsOneWidget);
      },
    );

    testWidgets('the lobby lays out on a phone and a computer', (tester) async {
      await _pumpShell(tester, _phone);
      await _openDrawer(tester);
      await tester.tap(find.text('the hangout'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('the call view', () {
    testWidgets(
      'fullscreen hides the navigation, and escape brings it back',
      variant: _desktop,
      (tester) async {
        await _pumpShell(tester, _wide);
        await tester.tap(find.text('the hangout'));
        await _connect(tester);

        await tester.tap(find.byTooltip('Fullscreen'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('The Starter Pack'), findsNothing);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('The Starter Pack'), findsOneWidget);
      },
    );

    testWidgets(
      'sharing your screen spotlights it and shows a strip to stop it',
      variant: _desktop,
      (tester) async {
        await _pumpShell(tester, _wide);
        await tester.tap(find.text('the hangout'));
        await _connect(tester);

        await tester.tap(find.byTooltip('Share screen'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Entire screen'));
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.textContaining("you're sharing"), findsOneWidget);
        expect(find.byKey(const ValueKey('spotlight')), findsOneWidget);

        await tester.tap(find.text('stop'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.textContaining("you're sharing"), findsNothing);
      },
    );

    testWidgets(
      'on a phone there is no screen sharing to offer',
      variant: _mobile,
      (tester) async {
        await _pumpShell(tester, _phone);
        await _openDrawer(tester);
        await tester.tap(find.text('the hangout'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('join voice'));
        await _connect(tester);

        expect(find.byTooltip('Share screen'), findsNothing);
        expect(find.byTooltip('Audio output'), findsOneWidget);
      },
    );

    testWidgets('on a phone, tapping a tile pins it', variant: _mobile, (
      tester,
    ) async {
      await _pumpShell(tester, _phone);
      await _openDrawer(tester);
      await tester.tap(find.text('the hangout'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('join voice'));
      await _connect(tester);

      await tester.tap(_tile('@mika'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('spotlight')),
          matching: _tile('@mika'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'on a computer, the mute shortcut works during a call',
      variant: _desktop,
      (tester) async {
        await _pumpShell(tester, _wide);
        await tester.tap(find.text('the hangout'));
        await _connect(tester);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pump();

        expect(find.byTooltip('Unmute (⌘⇧M)'), findsOneWidget);
      },
    );

    testWidgets(
      'right-clicking a tile offers pin and volume, and nothing that '
      'goes nowhere',
      variant: _desktop,
      (tester) async {
        await _pumpShell(tester, _wide);
        await tester.tap(find.text('the hangout'));
        await _connect(tester);

        await tester.tap(_tile('@mika'), buttons: kSecondaryButton);
        await tester.pumpAndSettle();

        expect(find.text('Pin'), findsOneWidget);
        expect(find.text('View profile'), findsNothing);
        expect(find.byType(Slider), findsOneWidget);
      },
    );
  });

  group('DM calls', () {
    Future<void> openDm(WidgetTester tester, String name) async {
      await _openHome(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(ChannelList),
          matching: find.text(name),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('Home lists your DMs', variant: _desktop, (tester) async {
      await _pumpShell(tester, _wide);
      await _openHome(tester);

      expect(find.text('Mika Rye'), findsWidgets);
      expect(find.text('weekend crew'), findsOneWidget);
    });

    testWidgets(
      'a call rings, then goes live when they answer',
      variant: _desktop,
      (tester) async {
        await _pumpShell(tester, _wide);
        await openDm(tester, 'Mika Rye');

        await tester.tap(find.byTooltip('Start a voice call'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(_panel(), findsOneWidget);
        expect(find.text('ringing…'), findsWidgets);

        await tester.pump(const Duration(seconds: 3));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('ringing…'), findsNothing);

        await tester.tap(find.byTooltip('Leave call'));
        await tester.pumpAndSettle();
        expect(_panel(), findsNothing);
        expect(find.text('call · 1m'), findsOneWidget);
      },
    );

    testWidgets(
      'a decline says so and offers to call again',
      variant: _desktop,
      (tester) async {
        await _pumpShell(tester, _wide);
        await openDm(tester, 'Sam Poolish');

        await tester.tap(find.byTooltip('Start a voice call'));
        await tester.pump(const Duration(seconds: 2));
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.text('Sam Poolish declined'), findsOneWidget);
        expect(find.text('call again'), findsOneWidget);

        await tester.tap(find.text('close'));
        await tester.pumpAndSettle();
        expect(_panel(), findsNothing);
      },
    );

    testWidgets('nobody answering for 30 seconds', variant: _desktop, (
      tester,
    ) async {
      await _pumpShell(tester, _wide);
      await openDm(tester, 'Ada Crumb');

      await tester.tap(find.byTooltip('Start a voice call'));
      await tester.pump(CallController.ringTimeout);
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('no answer'), findsWidgets);
      expect(find.text('missed call'), findsOneWidget);
    });

    testWidgets('a group call shows where everyone got to', variant: _desktop, (
      tester,
    ) async {
      await _pumpShell(tester, _wide);
      await openDm(tester, 'weekend crew');

      await tester.tap(find.byTooltip('Start a voice call'));
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byTooltip('Expand'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.descendant(of: _tile('@sam'), matching: find.text('declined')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: _tile('@jun'), matching: find.text('ringing…')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pump(CallController.ringTimeout);
    });

    testWidgets(
      'looking elsewhere, the bar names who the call is with',
      variant: _desktop,
      (tester) async {
        await _pumpShell(tester, _wide);
        await openDm(tester, 'Mika Rye');
        await tester.tap(find.byTooltip('Start a voice call'));
        await tester.pump(const Duration(seconds: 4));

        await tester.tap(find.text('Ada Crumb').first);
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.text('call with Mika Rye'), findsOneWidget);
      },
    );

    testWidgets(
      'expanding fills the conversation, shrinking gives it back',
      variant: _mobile,
      (tester) async {
        await _pumpShell(tester, _phone);
        await _openDrawer(tester);
        await openDm(tester, 'Mika Rye');
        await tester.tap(find.byTooltip('Start a voice call'));
        await tester.pump(const Duration(seconds: 4));

        expect(find.text('she lives!! thank you'), findsOneWidget);
        await tester.tap(find.byTooltip('Expand'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('she lives!! thank you'), findsNothing);

        await tester.tap(find.byTooltip('Shrink'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('she lives!! thank you'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('an incoming call', () {
    testWidgets(
      'on a computer, a card rings over whatever you are doing',
      variant: _desktop,
      (tester) async {
        await _pumpShell(tester, _wide);

        await _debug(tester, 'call from Mika');
        expect(_incoming(), findsOneWidget);
        expect(find.text('Mika Rye is calling'), findsOneWidget);

        await tester.tap(find.text('accept'));
        await _connect(tester);

        expect(_incoming(), findsNothing);
        expect(_panel(), findsOneWidget);
      },
    );

    testWidgets('a group ring names the group', variant: _desktop, (
      tester,
    ) async {
      await _pumpShell(tester, _wide);

      await _debug(tester, 'call from weekend crew');
      expect(find.text('Jun Levain is calling · weekend crew'), findsOneWidget);

      await tester.tap(find.text('decline'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(_incoming(), findsNothing);
    });

    testWidgets('ringing out leaves a missed call', variant: _android, (
      tester,
    ) async {
      await _pumpShell(tester, _phone);
      await _openDrawer(tester);

      await _debug(tester, 'call from Mika');
      expect(_incoming(), findsOneWidget);

      await tester.pump(CallController.ringTimeout);
      await tester.pump(const Duration(milliseconds: 300));
      expect(_incoming(), findsNothing);
    });

    testWidgets(
      'on iPhone, CallKit answers, so we land in the call',
      variant: _mobile,
      (tester) async {
        await _pumpShell(tester, _phone);
        await _openDrawer(tester);

        await _debug(tester, 'call from Mika');
        await _connect(tester);

        expect(_incoming(), findsNothing);
        expect(_panel(), findsOneWidget);
        expect(
          find.text('she lives!! thank you'),
          findsNothing,
          reason: 'answering from CallKit lands with the panel expanded',
        );
      },
    );
  });

  group('polish', () {
    testWidgets(
      'the call top bar keeps its buttons at the right edge',
      variant: _mobile,
      (tester) async {
        await _pumpShell(tester, _phone);
        await _openDrawer(tester);
        await _openHome(tester);
        await tester.tap(
          find.descendant(
            of: find.byType(ChannelList),
            matching: find.text('Mika Rye'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Start a voice call'));
        await tester.pump(const Duration(seconds: 4));

        final expand = tester.getRect(find.byTooltip('Expand'));
        expect(expand.right, greaterThan(_phone.width - 24));
      },
    );

    testWidgets(
      'a DM\'s call buttons step aside while its call is running',
      variant: _desktop,
      (tester) async {
        await _pumpShell(tester, _wide);
        await _openHome(tester);
        await tester.tap(find.byTooltip('Start a voice call'));
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.byTooltip('Start a voice call'), findsNothing);
        expect(find.byTooltip('Start a video call'), findsNothing);
        await tester.pump(CallController.ringTimeout);
      },
    );

    testWidgets('the lobby shows who is muted', variant: _desktop, (
      tester,
    ) async {
      await _pumpShell(tester, _wide);
      await tester.tap(find.text('the hangout'));
      await _connect(tester);
      await tester.tap(find.byTooltip('Leave call'));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: _tile('@sam'),
          matching: find.byIcon(LucideIcons.micOff),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the DM Home opens to counts as read', variant: _desktop, (
      tester,
    ) async {
      await _pumpShell(tester, _wide);
      await _openHome(tester);

      final mika = find.byKey(const ValueKey('channel-dm-mika'));
      expect(find.descendant(of: mika, matching: find.text('1')), findsNothing);
    });
  });
}
