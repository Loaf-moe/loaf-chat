import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/members/member_list.dart';
import 'package:loaf_native/ui/members/person_card.dart';
import 'package:loaf_native/ui/mock/mock_rooms.dart';
import 'package:loaf_native/ui/rooms/rooms.dart';
import 'package:loaf_native/ui/settings/settings_page.dart';
import 'package:loaf_native/ui/shell/app_shell.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

final _desktop = TargetPlatformVariant.only(TargetPlatform.macOS);

class _Rooms extends MockRooms {
  final kicked = <(String, String)>[];

  /// While set, a kick waits on it.
  Completer<void>? hold;

  /// What a kick throws, if anything.
  Object? refuse;

  @override
  Future<void> kickFromSpace(String spaceId, String userId) async {
    kicked.add((spaceId, userId));
    await hold?.future;
    if (refuse case final error?) throw error;
  }
}

/// The shell on a computer, with the member list showing.
Future<_Rooms> _pumpShell(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final rooms = _Rooms();
  await tester.pumpWidget(
    MaterialApp(
      theme: loafDarkTheme(),
      home: AppShell(rooms: () => rooms),
    ),
  );
  await tester.pumpAndSettle();
  return rooms;
}

Future<void> _openMenu(WidgetTester tester, String id) async {
  await tester.tap(
    find.descendant(
      of: find.byType(MemberList),
      matching: find.byKey(ValueKey('member-$id')),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('message opens a DM with them', variant: _desktop, (
    tester,
  ) async {
    await _pumpShell(tester);
    await _openMenu(tester, '@jun');
    await tester.tap(find.text('message'));
    await tester.pumpAndSettle();

    expect(find.byType(PersonCard), findsNothing);
    expect(find.text('Message @Jun Levain'), findsOneWidget);
  });

  testWidgets('kick asks first, then kicks from the space', variant: _desktop, (
    tester,
  ) async {
    final rooms = await _pumpShell(tester);
    await _openMenu(tester, '@jun');
    await tester.tap(find.text('kick from The Starter Pack'));
    await tester.pumpAndSettle();

    expect(find.text('kick Jun Levain from The Starter Pack?'), findsOneWidget);
    expect(rooms.kicked, isEmpty);
    await tester.tap(find.text('kick'));
    await tester.pumpAndSettle();
    expect(rooms.kicked, [('starter', '@jun')]);
  });

  testWidgets(
    'a kick in flight shows a spinner and cannot be cancelled',
    variant: _desktop,
    (tester) async {
      final rooms = await _pumpShell(tester);
      rooms.hold = Completer();
      await _openMenu(tester, '@jun');
      await tester.tap(find.text('kick from The Starter Pack'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('kick'));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('kick'), findsNothing);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'cancel'))
            .enabled,
        isFalse,
      );

      rooms.hold!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets('a kick that only half went through says so', variant: _desktop, (
    tester,
  ) async {
    final rooms = await _pumpShell(tester);
    rooms.refuse = const PartlyDone(missing: ['kitchen']);
    await _openMenu(tester, '@jun');
    await tester.tap(find.text('kick from The Starter Pack'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('kick'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(
      find.text("couldn't kick Jun Levain from everything in The Starter Pack"),
      findsOneWidget,
    );
  });

  testWidgets('cancelling the kick kicks nobody', variant: _desktop, (
    tester,
  ) async {
    final rooms = await _pumpShell(tester);
    await _openMenu(tester, '@jun');
    await tester.tap(find.text('kick from The Starter Pack'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('cancel'));
    await tester.pumpAndSettle();
    expect(rooms.kicked, isEmpty);
  });

  testWidgets(
    'your own menu edits your profile and kicks nobody',
    variant: _desktop,
    (tester) async {
      await _pumpShell(tester);
      await _openMenu(tester, '@faore');

      expect(find.text('message'), findsNothing);
      expect(find.textContaining('kick'), findsNothing);
      await tester.tap(find.text('edit profile'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsModal), findsOneWidget);
    },
  );

  testWidgets('a puppet gets no message and no verify', variant: _desktop, (
    tester,
  ) async {
    await _pumpShell(tester);
    await _openMenu(tester, '@_ooye_lou');

    expect(find.byType(PersonCard), findsOneWidget);
    expect(find.text('message'), findsNothing);
    expect(find.text('verify'), findsNothing);
    expect(find.text('copy user id'), findsOneWidget);
  });
}
