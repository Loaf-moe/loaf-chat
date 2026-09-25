import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:loaf_native/ui/shell/app_shell.dart';
import 'package:loaf_native/ui/shell/channel_list.dart';
import 'package:loaf_native/ui/shell/spaces_rail.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

final _mobile = TargetPlatformVariant.only(TargetPlatform.iOS);
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

Future<void> _openHome(WidgetTester tester) async {
  await tester.tap(find.byKey(SpacesRail.homeKey));
  await tester.pumpAndSettle();
}

Finder _list() => find.byType(ChannelList);
Finder _inList(String text) =>
    find.descendant(of: _list(), matching: find.text(text));
Finder _row(String id) => find.byKey(ValueKey('channel-$id'));

/// Top edge of a section heading or a row's label in the list.
double _top(WidgetTester tester, String text) =>
    tester.getTopLeft(_inList(text)).dy;

void main() {
  group('Home sections', () {
    testWidgets('run invites, favourites, DMs, rooms, then low priority', (
      tester,
    ) async {
      await _pumpShell(tester, _wide);
      await _openHome(tester);

      final headings = [
        'INVITES',
        'FAVOURITES',
        'DIRECT MESSAGES',
        'ROOMS',
        'LOW PRIORITY',
      ];
      for (var i = 1; i < headings.length; i++) {
        expect(
          _top(tester, headings[i - 1]),
          lessThan(_top(tester, headings[i])),
          reason: '${headings[i - 1]} before ${headings[i]}',
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('low priority starts collapsed', (tester) async {
      await _pumpShell(tester, _wide);
      await _openHome(tester);

      expect(_inList('bread talk (public)'), findsNothing);
      await tester.tap(_inList('LOW PRIORITY'));
      await tester.pumpAndSettle();
      expect(_inList('bread talk (public)'), findsOneWidget);
    });

    testWidgets('the admin room is in Rooms and opens its conversation', (
      tester,
    ) async {
      await _pumpShell(tester, _wide);
      await _openHome(tester);

      final admins = _top(tester, 'admins');
      expect(admins, greaterThan(_top(tester, 'ROOMS')));

      await tester.tap(_inList('admins'));
      await tester.pumpAndSettle();
      expect(find.text('!admin server uptime'), findsOneWidget);
      expect(find.text('Message #admins'), findsOneWidget);
      expect(
        find.byIcon(LucideIcons.messagesSquare),
        findsOneWidget,
        reason: 'a room is not a # channel',
      );
    });

    testWidgets('Home has no space menu to open', (tester) async {
      await _pumpShell(tester, _wide);
      await _openHome(tester);

      expect(
        find.descendant(
          of: _list(),
          matching: find.byIcon(LucideIcons.chevronDown),
        ),
        findsNWidgets(5),
        reason: 'only the five section headings carry a chevron',
      );
    });
  });

  group('tagging from Home', () {
    testWidgets(
      'favouriting a room moves it into Favourites',
      variant: _desktop,
      (tester) async {
        await _pumpShell(tester, _wide);
        await _openHome(tester);

        await tester.tap(_inList('admins'), buttons: kSecondaryButton);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Favourite'));
        await tester.pumpAndSettle();

        expect(
          _top(tester, 'admins'),
          lessThan(_top(tester, 'DIRECT MESSAGES')),
        );
        expect(
          _inList('ROOMS'),
          findsOneWidget,
          reason: 'fermentation remains',
        );
      },
    );

    testWidgets('low priority tucks a DM away', variant: _desktop, (
      tester,
    ) async {
      await _pumpShell(tester, _wide);
      await _openHome(tester);

      await tester.tap(_inList('Ada Crumb'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Low priority'));
      await tester.pumpAndSettle();

      expect(_inList('Ada Crumb'), findsNothing, reason: 'section collapsed');
    });

    testWidgets('actions name what the row is', variant: _desktop, (
      tester,
    ) async {
      await _pumpShell(tester, _wide);
      await _openHome(tester);

      await tester.tap(_inList('admins'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Leave room'), findsOneWidget);
      expect(find.text('Mute room'), findsOneWidget);
      await tester.tapAt(const Offset(700, 400));
      await tester.pumpAndSettle();

      await tester.tap(_inList('Sam Poolish'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Leave conversation'), findsOneWidget);
    });

    testWidgets('space channels offer no tags', variant: _desktop, (
      tester,
    ) async {
      await _pumpShell(tester, _wide);

      await tester.tap(find.text('kitchen'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(find.text('Favourite'), findsNothing);
      expect(find.text('Low priority'), findsNothing);
    });
  });

  group('reordering favourites', () {
    Future<void> favourite(WidgetTester tester, String name) async {
      await tester.tap(_inList(name), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Favourite'));
      await tester.pumpAndSettle();
    }

    testWidgets('on a computer, drag a row', variant: _desktop, (tester) async {
      await _pumpShell(tester, _wide);
      await _openHome(tester);
      await favourite(tester, 'admins');
      expect(_top(tester, 'Mika Rye'), lessThan(_top(tester, 'admins')));

      // A mouse, as on a real computer: desktop scroll views leave mouse
      // drags alone, so the row gets them.
      final gesture = await tester.startGesture(
        tester.getCenter(_inList('admins')),
        kind: PointerDeviceKind.mouse,
      );
      for (var i = 0; i < 7; i++) {
        await gesture.moveBy(const Offset(0, -10));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();

      expect(_top(tester, 'admins'), lessThan(_top(tester, 'Mika Rye')));
    });

    testWidgets(
      'on a phone, long press and drag reorders; letting go opens actions',
      variant: _mobile,
      (tester) async {
        await _pumpShell(tester, _phone);
        await tester.tap(find.byIcon(LucideIcons.menu));
        await tester.pumpAndSettle();
        await _openHome(tester);

        await tester.longPress(_inList('admins'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Favourite'));
        await tester.pumpAndSettle();

        // A long press that goes nowhere is a request for the actions.
        await tester.longPress(_inList('Mika Rye'));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsOneWidget);
        await tester.tapAt(const Offset(200, 100));
        await tester.pumpAndSettle();

        // One that moves is a drag.
        final gesture = await tester.startGesture(
          tester.getCenter(_inList('admins')),
        );
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
        await gesture.moveBy(const Offset(0, -30));
        await tester.pump();
        await gesture.moveBy(const Offset(0, -30));
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();

        expect(find.byType(BottomSheet), findsNothing);
        expect(_top(tester, 'admins'), lessThan(_top(tester, 'Mika Rye')));
      },
    );
  });

  group('invites', () {
    testWidgets('count towards the Home badge', (tester) async {
      await _pumpShell(tester, _wide);

      // Mika's one unread plus two invites.
      expect(
        find.descendant(
          of: find.byKey(SpacesRail.homeKey),
          matching: find.text('3'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('open a preview rather than the room', (tester) async {
      await _pumpShell(tester, _wide);
      await _openHome(tester);

      await tester.tap(_inList('Sourdough Society'));
      await tester.pumpAndSettle();

      expect(find.text('Theo Crust invited you'), findsWidgets);
      expect(find.text('starters, schedules, and crumb shots'), findsOneWidget);
      expect(find.text('accept'), findsOneWidget);
      expect(find.text('decline'), findsOneWidget);
    });

    testWidgets('accepting a DM moves it into its section and opens it', (
      tester,
    ) async {
      await _pumpShell(tester, _wide);
      await _openHome(tester);

      await tester.tap(_inList('Rosa Brioche'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('accept'));
      await tester.pumpAndSettle();

      expect(_row('dm-rosa'), findsOneWidget);
      expect(
        _top(tester, 'Rosa Brioche'),
        greaterThan(_top(tester, 'DIRECT MESSAGES')),
      );
      expect(find.textContaining('had to say hello'), findsOneWidget);
    });

    testWidgets('accepting a space adds it to the rail', (tester) async {
      await _pumpShell(tester, _wide);
      await _openHome(tester);

      await tester.tap(_inList('Sourdough Society'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('accept'));
      await tester.pumpAndSettle();

      expect(find.text('SS'), findsOneWidget);
      expect(_inList('INVITES'), findsOneWidget, reason: "Rosa's still waits");
    });

    testWidgets("a DM invite doesn't name the person twice", (tester) async {
      await _pumpShell(tester, _wide);
      await _openHome(tester);

      expect(_inList('Rosa Brioche invited you'), findsNothing);
      expect(_inList('wants to chat'), findsOneWidget);
    });

    testWidgets('declining removes the invite', (tester) async {
      await _pumpShell(tester, _wide);
      await _openHome(tester);

      await tester.tap(_inList('Rosa Brioche'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('decline'));
      await tester.pumpAndSettle();

      expect(_inList('Rosa Brioche'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
