import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:loaf_native/ui/auth/homeserver.dart';
import 'package:loaf_native/ui/auth/loaf_session.dart';
import 'package:loaf_native/ui/auth/sign_in_state.dart';
import 'package:loaf_native/ui/channel/timeline.dart';
import 'package:loaf_native/ui/mock/mock_homeserver.dart';
import 'package:loaf_native/ui/mock/mock_devices.dart';
import 'package:loaf_native/ui/mock/mock_profile.dart';
import 'package:loaf_native/ui/mock/mock_verifier.dart';
import 'package:loaf_native/ui/members/presence.dart';
import 'package:loaf_native/ui/model/models.dart';
import 'package:loaf_native/ui/rooms/rooms.dart';
import 'package:loaf_native/ui/shell/app_shell.dart';
import 'package:loaf_native/ui/shell/channel_list.dart';
import 'package:loaf_native/ui/spaces/add_space.dart';
import 'package:loaf_native/ui/spaces/space_directory.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/verify/verifier.dart';
import 'package:loaf_native/ui/settings/devices.dart';
import 'package:loaf_native/ui/shell/profile.dart';
import 'package:loaf_native/ui/model/arrival.dart';
import 'package:loaf_native/ui/model/media_source.dart';
import 'package:loaf_native/ui/widgets/avatar_images.dart';

// Widget-level tests for the space menu, leave-space confirmation and the
// invite entry on a channel's own menu — all wired through the full
// [AppShell], the way `app_shell_rooms_test.dart` does, since leaving a
// space has to be seen taking it off the rail.

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
);

Space _bakery() => const Space(
  id: '!bakery',
  name: 'Bakery',
  color: Color(0xFFD97B2A),
  members: [_me, _mod],
  categories: [
    ChannelCategory('', [Channel(id: '!general', name: 'general')]),
  ],
);

/// A backend that behaves like a real one for the actions this task wires:
/// only what is granted through [abilities] can be done, and leaving a
/// space really does take it off [spaces].
class _FakeRooms extends ChangeNotifier implements Rooms {
  _FakeRooms({this.spaces = const [], this.homeRooms = const []});

  @override
  Stream<Arrival> get arrivals => const Stream.empty();
  @override
  AvatarImages get avatarImages => const NoAvatarImages();
  @override
  MediaSource get media => const NoMediaSource();
  @override
  Profile get profile => MockProfile();
  @override
  Devices get devices => MockDevices();
  @override
  Set<RoomAbility> abilities = {
    RoomAbility.answerInvites,
    RoomAbility.invite,
    RoomAbility.leave,
  };
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

  final invited = <String, List<String>>{};

  @override
  void loadMembers(String roomId) {}

  @override
  Timeline? timeline(String roomId) => null;

  @override
  Future<void> accept(Invite invite) => Future.value();
  @override
  Future<void> decline(Invite invite) => Future.value();

  @override
  Future<void> leaveSpace(String spaceId) async {
    spaces = [
      for (final s in spaces)
        if (s.id != spaceId) s,
    ];
    notifyListeners();
  }

  @override
  Future<void> invite(String roomId, List<String> userIds) async {
    invited[roomId] = userIds;
  }

  Never _unwired() => throw UnsupportedError('not wired');
  @override
  void markRead(String roomId) => _unwired();
  @override
  Future<void> setMuted(String roomId, bool muted) => _unwired();
  @override
  Future<void> setJoined(String roomId, bool joined) => _unwired();
  @override
  Future<void> setFavourite(String roomId, bool favourite) => _unwired();
  @override
  Future<void> reorderFavourites(List<String> roomIds) => _unwired();
  @override
  Future<void> setLowPriority(String roomId, bool lowPriority) => _unwired();

  /// What joining answers with: refused, unless a test says otherwise.
  Future<void> Function(Space space) onJoin = (_) =>
      throw StateError('refused');

  @override
  Future<void> joinSpace(Space space) => onJoin(space);
  @override
  Future<String> createSpace(String name, {required Member me}) => _unwired();
  @override
  Future<Channel> createDirect(List<Member> members) => _unwired();

  /// What any address resolves to: a space that is not joined, unless a
  /// test says otherwise.
  SpacePreview lookedUp = const SpacePreview(
    alias: '#pies:loaf.test',
    space: Space(id: '!pies', name: 'Pies', color: Color(0xFF4E9E76)),
    memberCount: 3,
  );

  @override
  SpaceDirectory get directory => _Directory(this);
}

/// Any address resolves to whatever [_FakeRooms.lookedUp] is.
class _Directory implements SpaceDirectory {
  _Directory(this.rooms);

  final _FakeRooms rooms;

  @override
  Future<List<SpacePreview>> publicSpaces(String server) async => const [];
  @override
  Future<SpacePreview> lookUp(String address) async => rooms.lookedUp;
}

class _Session extends ChangeNotifier implements LoafSession {
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
  void signOut() {}
  @override
  void markVerified() {}
  @override
  void clearIncoming() {}
  @override
  bool consumeFailure() => false;
}

Future<void> _pump(
  WidgetTester tester,
  _FakeRooms rooms, {
  Size size = const Size(1440, 900),
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
  await tester.pumpAndSettle();
  if (size.width < 900) {
    await tester.tap(find.byIcon(LucideIcons.menu));
    await tester.pumpAndSettle();
  }
}

const _rosa = Member(
  '@rosa:loaf.test',
  'Rosa',
  Color(0xFF4E9E76),
  presence: Presence.unknown,
);

const _dms = [
  Channel(id: '!dm', name: 'Moddy', kind: ChannelKind.direct, members: [_mod]),
  Channel(
    id: '!dm-rosa',
    name: 'Rosa',
    kind: ChannelKind.direct,
    members: [_rosa],
  ),
];

/// The conversation the shell has open.
String _selected(WidgetTester tester) =>
    tester.widget<ChannelList>(find.byType(ChannelList)).selectedChannelId;

/// Looks [address] up through the rail's "+", as far as the preview.
Future<void> _lookUp(WidgetTester tester, String address) async {
  await tester.tap(find.byTooltip('Add a space'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('join with a link'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).last, address);
  await tester.pumpAndSettle();
}

Finder _spaceIcon() => find.byKey(const ValueKey('space-!bakery'));
Finder _inList(String text) =>
    find.descendant(of: find.byType(ChannelList), matching: find.text(text));

void main() {
  group('joining a space', () {
    testWidgets(
      "a join the server refuses toasts, and stays where you were",
      variant: _desktop,
      (tester) async {
        final rooms = _FakeRooms(spaces: [_bakery()])
          ..abilities = {RoomAbility.addSpace};
        await _pump(tester, rooms);
        await tester.tap(find.byTooltip('Add a space'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('join with a link'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, '#pies:loaf.test');
        await tester.pumpAndSettle();
        await tester.tap(find.text('join'));
        await tester.pumpAndSettle();

        expect(find.text("couldn't join Pies. try again?"), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(find.byType(AddSpacePanel), findsNothing);
      },
    );

    testWidgets(
      'a room you are already in offers open, not join, and opens it',
      variant: _desktop,
      (tester) async {
        final rooms = _FakeRooms(spaces: [_bakery()], homeRooms: _dms)
          ..abilities = {RoomAbility.addSpace}
          ..onJoin = ((_) => fail('an already-joined room is not joined again'))
          ..lookedUp = const SpacePreview(
            alias: '#rosa:loaf.test',
            space: Space(
              id: '!dm-rosa',
              name: 'Rosa',
              color: Color(0xFF4E9E76),
            ),
            memberCount: 2,
          );
        await _pump(tester, rooms);
        await _lookUp(tester, '#rosa:loaf.test');
        expect(find.text('join'), findsNothing);
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        expect(find.byType(AddSpacePanel), findsNothing);
        expect(_selected(tester), '!dm-rosa');
        // And the shell still answers: the next DM tapped is the one open.
        await tester.tap(_inList('Moddy'));
        await tester.pumpAndSettle();
        expect(_selected(tester), '!dm');
      },
    );

    testWidgets(
      'a joined channel of a space opens in its space',
      variant: _desktop,
      (tester) async {
        final rooms = _FakeRooms(spaces: [_bakery()], homeRooms: _dms)
          ..abilities = {RoomAbility.addSpace}
          ..lookedUp = const SpacePreview(
            alias: '#general:loaf.test',
            space: Space(
              id: '!general',
              name: 'general',
              color: Color(0xFF4E9E76),
            ),
            memberCount: 2,
          );
        await _pump(tester, rooms);
        await tester.tap(find.byKey(const ValueKey('home')));
        await tester.pumpAndSettle();
        await _lookUp(tester, '#general:loaf.test');
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        expect(_selected(tester), '!general');
        expect(_inList('general'), findsOneWidget);
      },
    );

    testWidgets(
      'a join that has not synced yet leaves every conversation selectable',
      variant: _desktop,
      (tester) async {
        // The server said yes, but the space is not among the spaces yet:
        // the shell waits on it from Home, where tapping must still work.
        final rooms = _FakeRooms(spaces: [_bakery()], homeRooms: _dms)
          ..abilities = {RoomAbility.addSpace}
          ..onJoin = (_) async {};
        await _pump(tester, rooms);
        await _lookUp(tester, '#pies:loaf.test');
        await tester.tap(find.text('join'));
        await tester.pumpAndSettle();

        await tester.tap(_inList('Rosa'));
        await tester.pumpAndSettle();
        expect(_selected(tester), '!dm-rosa');
        await tester.tap(_inList('Moddy'));
        await tester.pumpAndSettle();
        expect(_selected(tester), '!dm');
      },
    );
  });

  group('the space menu', () {
    testWidgets(
      'right-clicking a space on a computer opens its menu at the pointer',
      variant: _desktop,
      (tester) async {
        await _pump(tester, _FakeRooms(spaces: [_bakery()]));
        // Near a corner of the icon rather than its center, and far from
        // any fixed anchor elsewhere in the rail: a menu that ignored the
        // click and opened at a hardcoded point would land well away from
        // this.
        final tap = tester.getCenter(_spaceIcon()) + const Offset(10, 10);
        await tester.tapAt(tap, buttons: kSecondaryButton);
        await tester.pumpAndSettle();
        expect(find.text('Invite people'), findsOneWidget);
        expect(find.text('Leave space'), findsOneWidget);
        final menu = tester.getTopLeft(find.text('Invite people'));
        expect((menu - tap).distance, lessThan(80));
      },
    );

    testWidgets(
      'long-pressing a space on a phone opens its menu',
      variant: _mobile,
      (tester) async {
        await _pump(
          tester,
          _FakeRooms(spaces: [_bakery()]),
          size: const Size(390, 844),
        );
        await tester.longPress(_spaceIcon());
        await tester.pumpAndSettle();
        expect(find.text('Invite people'), findsOneWidget);
        expect(find.text('Leave space'), findsOneWidget);
      },
    );

    testWidgets(
      'a fake rooms without invite or leave draws no space menu',
      variant: _desktop,
      (tester) async {
        final rooms = _FakeRooms(spaces: [_bakery()])
          ..abilities = {RoomAbility.answerInvites};
        await _pump(tester, rooms);
        await tester.tap(_spaceIcon(), buttons: kSecondaryButton);
        await tester.pumpAndSettle();
        expect(find.text('Invite people'), findsNothing);
        expect(find.text('Leave space'), findsNothing);
      },
    );
  });

  group('leaving a space', () {
    testWidgets(
      'leaving a space asks first, then takes it off the rail',
      variant: _desktop,
      (tester) async {
        await _pump(tester, _FakeRooms(spaces: [_bakery()]));
        await tester.tap(_spaceIcon(), buttons: kSecondaryButton);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Leave space'));
        await tester.pumpAndSettle();
        expect(find.text('leave Bakery?'), findsOneWidget);
        await tester.tap(find.text('leave'));
        await tester.pumpAndSettle();
        expect(_spaceIcon(), findsNothing);
      },
    );

    testWidgets('cancelling the leave keeps the space', variant: _desktop, (
      tester,
    ) async {
      await _pump(tester, _FakeRooms(spaces: [_bakery()]));
      await tester.tap(_spaceIcon(), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leave space'));
      await tester.pumpAndSettle();
      expect(find.text('leave Bakery?'), findsOneWidget);
      await tester.tap(find.text('cancel'));
      await tester.pumpAndSettle();
      expect(_spaceIcon(), findsOneWidget);
    });

    testWidgets(
      'leaving another space keeps you where you are',
      variant: _desktop,
      (tester) async {
        const pies = Space(
          id: '!pies',
          name: 'Pies',
          color: Color(0xFF4E9E76),
          members: [_me],
          categories: [
            ChannelCategory('', [Channel(id: '!crusts', name: 'crusts')]),
          ],
        );
        await _pump(tester, _FakeRooms(spaces: [_bakery(), pies]));
        await tester.tap(find.byKey(const ValueKey('space-!pies')));
        await tester.pumpAndSettle();
        expect(_inList('crusts'), findsOneWidget);

        await tester.tap(_spaceIcon(), buttons: kSecondaryButton);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Leave space'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('leave'));
        await tester.pumpAndSettle();

        expect(_spaceIcon(), findsNothing);
        expect(_inList('crusts'), findsOneWidget);
      },
    );
  });

  testWidgets('a channel offers invite people', variant: _desktop, (
    tester,
  ) async {
    await _pump(tester, _FakeRooms(spaces: [_bakery()]));
    await tester.tap(_inList('general'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('Invite people'), findsOneWidget);
  });
}
