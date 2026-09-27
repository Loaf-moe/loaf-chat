import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:loaf_native/ui/auth/homeserver.dart';
import 'package:loaf_native/ui/auth/loaf_session.dart';
import 'package:loaf_native/ui/auth/sign_in_state.dart';
import 'package:loaf_native/ui/channel/composer.dart';
import 'package:loaf_native/ui/channel/timeline.dart';
import 'package:loaf_native/ui/members/member_list.dart';
import 'package:loaf_native/ui/members/presence.dart';
import 'package:loaf_native/ui/mock/mock_homeserver.dart';
import 'package:loaf_native/ui/mock/mock_verifier.dart';
import 'package:loaf_native/ui/model/models.dart';
import 'package:loaf_native/ui/rooms/rooms.dart';
import 'package:loaf_native/ui/settings/settings_page.dart';
import 'package:loaf_native/ui/shell/app_shell.dart';
import 'package:loaf_native/ui/shell/channel_list.dart';
import 'package:loaf_native/ui/shell/spaces_rail.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/verify/verifier.dart';

final _mobile = TargetPlatformVariant.only(TargetPlatform.iOS);
final _desktop = TargetPlatformVariant.only(TargetPlatform.macOS);

const _me = Member(
  '@chris:loaf.test',
  'Chris',
  Color(0xFF3B82F6),
  presence: Presence.unknown,
);
const _mod = Member(
  '@mod:loaf.test',
  'Moddy',
  Color(0xFF8B5CF6),
  presence: Presence.unknown,
  powerLevel: 50,
);

Space _bakery({List<Channel>? channels, List<Member>? members}) => Space(
  id: '!bakery',
  name: 'Bakery',
  color: const Color(0xFFD97B2A),
  members: members ?? const [_me, _mod],
  categories: [
    ChannelCategory(
      '',
      channels ??
          const [
            Channel(id: '!general', name: 'general', unread: 2),
            Channel(id: '!oven', name: 'oven', kind: ChannelKind.voice),
          ],
    ),
  ],
);

const _dm = Channel(
  id: '!dm',
  name: 'Moddy',
  kind: ChannelKind.direct,
  members: [_mod],
);

final _invite = Invite(
  id: '!proofing',
  kind: InviteKind.room,
  name: 'Proofing',
  inviter: _mod,
  color: const Color(0xFF4E9E76),
  room: const Channel(id: '!proofing', name: 'Proofing'),
);

/// Rooms as a real backend has them in phase 2: plain models, and only
/// invites can be answered.
class _FakeRooms extends ChangeNotifier implements Rooms {
  _FakeRooms({this.spaces = const [], this.homeRooms = const []});

  @override
  Set<RoomAbility> abilities = {RoomAbility.answerInvites};
  @override
  bool synced = true;
  @override
  double? syncProgress;
  @override
  Member get me => _me;
  @override
  List<Space> spaces;
  @override
  List<Channel> homeRooms;
  @override
  List<Invite> invites = const [];

  final membersAsked = <String>[];

  /// What accepting and declining answer with; completed by the test.
  Completer<void>? answer;

  void update() => notifyListeners();

  @override
  void loadMembers(String roomId) => membersAsked.add(roomId);

  @override
  Timeline? timeline(String roomId) => null;

  @override
  Future<void> accept(Invite invite) => answer!.future;
  @override
  Future<void> decline(Invite invite) => answer!.future;

  Never _unwired() => throw UnsupportedError('not wired');
  @override
  void markRead(String roomId) => _unwired();
  @override
  void setMuted(String roomId, bool muted) => _unwired();
  @override
  void setJoined(String roomId, bool joined) => _unwired();
  @override
  void setFavourite(String roomId, bool favourite) => _unwired();
  @override
  void reorderFavourites(List<String> roomIds) => _unwired();
  @override
  void setLowPriority(String roomId, bool lowPriority) => _unwired();
  @override
  void joinSpace(Space space) => _unwired();
  @override
  String createSpace(String name, {required Member me}) => _unwired();
  @override
  Channel createDirect(List<Member> members) => _unwired();
}

/// A session that is signed in and trusted, and counts sign-outs.
class _Session extends ChangeNotifier implements LoafSession {
  var signedOut = 0;

  @override
  AccountState get account => AccountState.signedIn;
  @override
  DeviceTrust get trust => DeviceTrust.verified;
  @override
  SoftLogout? get softLogout => null;
  @override
  IncomingRequest? get incoming => null;
  @override
  Verifier get verifier => MockVerifier();
  @override
  String get homeserverName => 'loaf.test';
  @override
  Homeserver newHomeserver() => MockHomeserver();
  @override
  void signedIn() {}
  @override
  void signOut() => signedOut++;
  @override
  void markVerified() {}
  @override
  void clearIncoming() {}
  @override
  bool consumeFailure() => false;
}

Future<_Session> _pump(
  WidgetTester tester,
  _FakeRooms rooms, {
  Size size = const Size(1440, 900),
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final session = _Session();
  addTearDown(session.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: loafLightTheme(),
      darkTheme: loafDarkTheme(),
      themeMode: ThemeMode.dark,
      home: AppShell(session: session, rooms: () => rooms),
    ),
  );
  // A spinner never settles.
  settle ? await tester.pumpAndSettle() : await tester.pump();
  return session;
}

Finder _inList(String text) =>
    find.descendant(of: find.byType(ChannelList), matching: find.text(text));

void main() {
  group('only what is wired is drawn', () {
    testWidgets('no add-space button, and no new-message button', (
      tester,
    ) async {
      await _pump(tester, _FakeRooms(spaces: [_bakery()], homeRooms: [_dm]));
      expect(find.byTooltip('Add a space'), findsNothing);
      await tester.tap(find.byKey(SpacesRail.homeKey));
      await tester.pumpAndSettle();
      expect(find.text('DIRECT MESSAGES'), findsOneWidget);
      expect(find.byTooltip('New message'), findsNothing);
    });

    testWidgets(
      'a right-click opens no menu with nothing in it',
      variant: _desktop,
      (tester) async {
        await _pump(tester, _FakeRooms(spaces: [_bakery()]));
        await tester.tap(_inList('general'), buttons: kSecondaryButton);
        await tester.pumpAndSettle();
        expect(find.text('Mark as read'), findsNothing);
        expect(find.text('Mute channel'), findsNothing);
        expect(find.text('Leave channel'), findsNothing);
      },
    );

    testWidgets(
      'a long press opens no menu with nothing in it',
      variant: _mobile,
      (tester) async {
        await _pump(
          tester,
          _FakeRooms(spaces: [_bakery()]),
          size: const Size(390, 844),
        );
        await tester.tap(find.byIcon(LucideIcons.menu));
        await tester.pumpAndSettle();
        await tester.longPress(_inList('general'));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsNothing);
      },
    );

    testWidgets('a room says messages are not wired, with no composer', (
      tester,
    ) async {
      await _pump(tester, _FakeRooms(spaces: [_bakery()]));
      expect(find.text("messages aren't wired up yet"), findsOneWidget);
      expect(find.byType(Composer), findsNothing);
    });

    testWidgets('a voice channel never connects', variant: _desktop, (
      tester,
    ) async {
      await _pump(tester, _FakeRooms(spaces: [_bakery()]));
      await tester.tap(_inList('oven'));
      await tester.pumpAndSettle();
      expect(find.text('Voice connected'), findsNothing);
      expect(find.text('join voice'), findsNothing);
      expect(find.text("messages aren't wired up yet"), findsOneWidget);
    });

    testWidgets('with messages but no calls, a voice channel still waits', (
      tester,
    ) async {
      final rooms = _FakeRooms(spaces: [_bakery()])
        ..abilities = {RoomAbility.messages};
      await _pump(tester, rooms);
      await tester.tap(_inList('oven'));
      await tester.pumpAndSettle();
      expect(find.text('join voice'), findsNothing);
      expect(find.text("messages aren't wired up yet"), findsOneWidget);
    });

    testWidgets('a DM offers no calls', (tester) async {
      await _pump(tester, _FakeRooms(homeRooms: [_dm]));
      expect(find.text("messages aren't wired up yet"), findsOneWidget);
      expect(find.byTooltip('Start a voice call'), findsNothing);
      expect(find.byTooltip('Start a video call'), findsNothing);
    });

    testWidgets('settings show who you are, with nothing to edit', (
      tester,
    ) async {
      final session = await _pump(tester, _FakeRooms(spaces: [_bakery()]));
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('@chris:loaf.test'), findsWidgets);
      expect(find.text('save changes'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('sign out'));
      await tester.pump();
      expect(session.signedOut, 1);
    });

    testWidgets('signing out from settings closes settings first', (
      tester,
    ) async {
      final session = await _pump(tester, _FakeRooms(spaces: [_bakery()]));
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('sign out'));
      await tester.pumpAndSettle();
      // The sign-in screen replaces the shell, not the card over it.
      expect(find.byType(SettingsModal), findsNothing);
      expect(session.signedOut, 1);
    });

    testWidgets('no mic or deafen: there are no calls to mute', (tester) async {
      await _pump(tester, _FakeRooms(spaces: [_bakery()]));
      expect(find.byTooltip('Mute'), findsNothing);
      expect(find.byTooltip('Deafen'), findsNothing);
      expect(find.byTooltip('Settings'), findsOneWidget);
    });

    Future<Iterable<String?>> selectable(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      return tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .map((t) => t.data);
    }

    testWidgets(
      'on a computer your matrix id can be selected',
      variant: _desktop,
      (tester) async {
        await _pump(tester, _FakeRooms(spaces: [_bakery()]));
        expect(await selectable(tester), contains('@chris:loaf.test'));
      },
    );

    testWidgets('on a phone your matrix id is plain text', variant: _mobile, (
      tester,
    ) async {
      await _pump(tester, _FakeRooms(spaces: [_bakery()]));
      expect(await selectable(tester), isNot(contains('@chris:loaf.test')));
      expect(find.text('@chris:loaf.test'), findsWidgets);
    });

    testWidgets('your avatar opens no status picker', variant: _desktop, (
      tester,
    ) async {
      await _pump(tester, _FakeRooms(spaces: [_bakery()]));
      expect(find.text('Chris'), findsWidgets);
      await tester.tap(find.text('Chris').last);
      await tester.pumpAndSettle();
      expect(find.text('what are you up to?'), findsNothing);
    });

    testWidgets(
      'no update notice: nothing stands behind it yet',
      variant: _desktop,
      (tester) async {
        await _pump(tester, _FakeRooms(spaces: [_bakery()]));
        expect(find.textContaining('0.3.0'), findsNothing);
      },
    );
  });

  group('faces and fallbacks', () {
    testWidgets('the first sync spins, then fills a bar', (tester) async {
      final rooms = (_FakeRooms()..synced = false);
      await _pump(tester, rooms, settle: false);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      rooms
        ..syncProgress = 0.4
        ..update();
      await tester.pump();
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, 0.4);
      rooms
        ..synced = true
        ..syncProgress = null
        ..spaces = [_bakery()]
        ..update();
      await tester.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      // The app opened on Home; the space arrives on the rail.
      expect(find.byKey(const ValueKey('space-!bakery')), findsOneWidget);
    });

    testWidgets(
      'on a phone the first sync still has a way to the drawer',
      variant: _mobile,
      (tester) async {
        await _pump(
          tester,
          (_FakeRooms()..synced = false),
          size: const Size(390, 844),
          settle: false,
        );
        expect(find.byTooltip('Channels'), findsOneWidget);
      },
    );

    testWidgets('an account in no rooms says so', (tester) async {
      await _pump(tester, _FakeRooms());
      expect(find.text('nothing here yet'), findsOneWidget);
    });

    testWidgets('a room that vanishes falls back to the next', (tester) async {
      final rooms = _FakeRooms(spaces: [_bakery()]);
      await _pump(tester, rooms);
      expect(find.text('general'), findsWidgets);
      rooms
        ..spaces = [
          _bakery(
            channels: const [
              Channel(id: '!crumb', name: 'crumb'),
              Channel(id: '!oven', name: 'oven', kind: ChannelKind.voice),
            ],
          ),
        ]
        ..update();
      await tester.pumpAndSettle();
      expect(find.text('general'), findsNothing);
      expect(find.text('crumb'), findsWidgets);
    });

    testWidgets('a space that vanishes falls back to Home', (tester) async {
      final rooms = _FakeRooms(spaces: [_bakery()], homeRooms: [_dm]);
      await _pump(tester, rooms);
      rooms
        ..spaces = []
        ..update();
      await tester.pumpAndSettle();
      expect(_inList('Moddy'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a space channel asks for the space\'s whole member list', (
      tester,
    ) async {
      final rooms = _FakeRooms(spaces: [_bakery()]);
      await _pump(tester, rooms);
      expect(rooms.membersAsked, contains('!bakery'));
      expect(find.text('Moddy'), findsOneWidget);
    });
  });

  testWidgets('an unjoined row on a backend that cannot join opens nothing', (
    tester,
  ) async {
    await _pump(
      tester,
      _FakeRooms(
        spaces: [
          _bakery(
            channels: const [
              Channel(id: '!general', name: 'general'),
              Channel(id: '!attic', name: 'attic', joined: false),
            ],
          ),
        ],
      ),
    );
    await tester.tap(_inList('attic'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('attic'), findsOneWidget);
  });

  group('the member list', () {
    testWidgets('you keep your power level in it', (tester) async {
      const admin = Member(
        '@chris:loaf.test',
        'Chris',
        Color(0xFF3B82F6),
        presence: Presence.unknown,
        powerLevel: 100,
      );
      await _pump(
        tester,
        _FakeRooms(
          spaces: [
            _bakery(members: const [admin, _mod]),
          ],
        ),
      );
      expect(find.text('ADMINS — 1'), findsOneWidget);
      expect(find.text('MEMBERS — 1'), findsOneWidget);
    });
  });

  group('a voice channel on the desktop', () {
    testWidgets(
      'shows the space\'s members, and the toggle hides them',
      variant: _desktop,
      (tester) async {
        await _pump(tester, _FakeRooms(spaces: [_bakery()]));
        await tester.tap(_inList('oven'));
        await tester.pumpAndSettle();
        expect(find.byType(MemberList), findsOneWidget);
        expect(find.text('Moddy'), findsOneWidget);
        await tester.tap(find.byIcon(LucideIcons.users));
        await tester.pumpAndSettle();
        expect(find.byType(MemberList), findsNothing);
      },
    );
  });

  group('answering an invite', () {
    Future<_FakeRooms> openInvite(WidgetTester tester) async {
      final rooms = _FakeRooms(homeRooms: [_dm])
        ..invites = [_invite]
        ..answer = Completer();
      await _pump(tester, rooms);
      await tester.tap(_inList('Proofing'));
      await tester.pumpAndSettle();
      return rooms;
    }

    testWidgets('while an answer is on its way, neither button answers', (
      tester,
    ) async {
      final rooms = await openInvite(tester);
      await tester.tap(find.text('accept'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.text('decline'));
      await tester.pump();
      rooms.answer!.complete();
      await tester.pumpAndSettle();
      expect(find.text('accept'), findsNothing);
    });

    testWidgets('a refused answer says so, and the buttons come back', (
      tester,
    ) async {
      final rooms = await openInvite(tester);
      await tester.tap(find.text('accept'));
      await tester.pump();
      rooms.answer!.completeError(Exception('403'));
      await tester.pumpAndSettle();
      expect(find.text("couldn't join. try again?"), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('accept'), findsOneWidget);
    });
  });
}
