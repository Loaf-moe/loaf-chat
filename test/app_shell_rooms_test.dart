import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:loaf_native/ui/auth/homeserver.dart';
import 'package:loaf_native/ui/auth/loaf_session.dart';
import 'package:loaf_native/ui/auth/sign_in_state.dart';
import 'package:loaf_native/ui/channel/composer.dart';
import 'package:loaf_native/ui/channel/channel_view.dart';
import 'package:loaf_native/ui/channel/timeline_controller.dart';
import 'package:loaf_native/ui/model/message_route.dart';
import 'package:loaf_native/ui/members/member_list.dart';
import 'package:loaf_native/ui/members/presence.dart';
import 'package:loaf_native/ui/mock/mock_homeserver.dart';
import 'package:loaf_native/ui/mock/mock_devices.dart';
import 'package:loaf_native/ui/mock/mock_profile.dart';
import 'package:loaf_native/ui/mock/mock_verifier.dart';
import 'package:loaf_native/ui/model/models.dart';
import 'package:loaf_native/ui/call/call_health.dart';
import 'package:loaf_native/ui/call/calls.dart';
import 'package:loaf_native/ui/call/connected_call_bar.dart';
import 'package:loaf_native/ui/rooms/rooms.dart';
import 'package:loaf_native/ui/settings/settings_page.dart';
import 'package:loaf_native/ui/shell/app_shell.dart';
import 'package:loaf_native/ui/shell/before_quit.dart';
import 'package:loaf_native/ui/spaces/space_directory.dart';
import 'package:loaf_native/ui/shell/channel_list.dart';
import 'package:loaf_native/ui/shell/spaces_rail.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/verify/verifier.dart';
import 'package:loaf_native/ui/settings/devices.dart';
import 'package:loaf_native/ui/shell/profile.dart';
import 'package:loaf_native/ui/model/arrival.dart';
import 'package:loaf_native/ui/model/link_previews.dart';
import 'package:loaf_native/ui/model/media_source.dart';
import 'package:loaf_native/ui/widgets/avatar_images.dart';

import 'voice_only_calls.dart';

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
  @override
  Future<String?> noticeAvatar(AvatarRef ref) async => null;

  _FakeRooms({this.spaces = const [], this.homeRooms = const []});

  @override
  Stream<Arrival> get arrivals => const Stream.empty();
  @override
  Stream<MessageRoute> get retractions => const Stream.empty();
  @override
  Calls? calls;
  @override
  AvatarImages get avatarImages => const NoAvatarImages();
  @override
  MediaSource get media => const NoMediaSource();
  @override
  LinkPreviews get linkPreviews => const NoLinkPreviews();
  @override
  Profile get profile => MockProfile();
  @override
  Devices get devices => MockDevices();
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

  /// The conversations it can open, by room.
  final timelines = <String, Timeline>{};

  @override
  Timeline? timeline(String roomId) => timelines[roomId];

  @override
  Future<void> accept(Invite invite) => answer!.future;
  @override
  Future<void> decline(Invite invite) => answer!.future;

  Never _unwired() => throw UnsupportedError('not wired');
  @override
  void markRead(String roomId) => _unwired();
  @override
  Future<void> setNotify(String roomId, NotifyLevel level) => _unwired();
  @override
  Future<void> setJoined(String roomId, bool joined) => _unwired();
  @override
  Future<void> setFavourite(String roomId, bool favourite) => _unwired();
  @override
  Future<void> reorderFavourites(List<String> roomIds) => _unwired();
  @override
  Future<void> setLowPriority(String roomId, bool lowPriority) => _unwired();
  @override
  Future<void> joinSpace(Space space) => _unwired();
  @override
  Future<void> leaveSpace(String spaceId) => _unwired();
  @override
  Future<void> kickFromSpace(String spaceId, String userId) => _unwired();
  @override
  Future<String> createSpace(String name, {required Member me}) => _unwired();
  @override
  Future<Channel> createDirect(List<Member> members) => _unwired();
  @override
  Future<void> invite(String roomId, List<String> userIds) => _unwired();

  /// Each kick asked for: the room and who.
  final kicked = <(String, String)>[];

  /// While set, a kick is refused.
  var refuseKicks = false;

  /// Held back until completed, when set: the answer to a kick.
  Completer<void>? kickAnswer;

  /// Each silence asked for: the room, who, and what (null lifts it).
  final silences = <(String, String, CallSilence?)>[];

  /// While set, a silence is refused.
  var refuseSilences = false;

  @override
  Future<void> silence(String roomId, String userId, CallSilence? to) async {
    if (refuseSilences) throw Exception('refused');
    silences.add((roomId, userId, to));
  }

  @override
  Future<void> kick(String roomId, String userId) async {
    if (refuseKicks) throw Exception('refused');
    kicked.add((roomId, userId));
    await kickAnswer?.future;
  }

  @override
  SpaceDirectory get directory => _unwired();
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
  Stream<MessageRoute>? routes,
  BeforeQuit? beforeQuit,
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
      home: AppShell(
        session: session,
        rooms: () => rooms,
        routes: routes,
        beforeQuit: beforeQuit,
      ),
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

    testWidgets('a room says messages are not available, with no composer', (
      tester,
    ) async {
      await _pump(tester, _FakeRooms(spaces: [_bakery()]));
      expect(find.text("messages aren't available here yet"), findsOneWidget);
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
      expect(find.text("voice chat isn't available yet"), findsOneWidget);
      expect(find.textContaining('wired'), findsNothing);
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
      expect(find.text("voice chat isn't available yet"), findsOneWidget);
      expect(
        find.text(
          "loaf can't connect to voice channels yet. "
          'text channels work as usual.',
        ),
        findsOneWidget,
      );
      expect(find.text("messages aren't available here yet"), findsNothing);
    });

    testWidgets(
      'with messages but no calls, a voice channel offers no call controls',
      variant: _desktop,
      (tester) async {
        final rooms = _FakeRooms(spaces: [_bakery()])
          ..abilities = {RoomAbility.messages};
        await _pump(tester, rooms);
        await tester.tap(_inList('oven'));
        await tester.pumpAndSettle();
        expect(find.byIcon(LucideIcons.mic), findsNothing);
        expect(find.byIcon(LucideIcons.micOff), findsNothing);
        expect(find.byIcon(LucideIcons.headphones), findsNothing);
        expect(find.byIcon(LucideIcons.phoneOff), findsNothing);
      },
    );

    testWidgets(
      'with messages but no calls, the members toggle still works in voice',
      variant: _desktop,
      (tester) async {
        final rooms = _FakeRooms(spaces: [_bakery()])
          ..abilities = {RoomAbility.messages};
        await _pump(tester, rooms);
        await tester.tap(_inList('oven'));
        await tester.pumpAndSettle();
        expect(find.byType(MemberList), findsOneWidget);
        await tester.tap(find.byIcon(LucideIcons.users));
        await tester.pumpAndSettle();
        expect(find.byType(MemberList), findsNothing);
      },
    );

    testWidgets('a voice channel joins through the rooms\' own calls', (
      tester,
    ) async {
      final calls = VoiceOnlyCalls();
      addTearDown(calls.dispose);
      final rooms = _FakeRooms(spaces: [_bakery()])
        ..abilities = {RoomAbility.messages, RoomAbility.calls}
        ..calls = calls;
      await _pump(tester, rooms);

      await tester.tap(_inList('oven'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('join voice'));
      await tester.pumpAndSettle();

      expect(calls.session?.target.name, 'oven');
      expect(find.byTooltip('Leave call'), findsOneWidget);
    });

    group('how the call\'s connection is doing', () {
      Future<VoiceOnlyCalls> joined(WidgetTester tester) async {
        final calls = VoiceOnlyCalls();
        addTearDown(calls.dispose);
        // The bar is drawn over a conversation, so #general has one.
        final general = TimelineController(const [], you: _me);
        addTearDown(general.dispose);
        final rooms = _FakeRooms(spaces: [_bakery()])
          ..abilities = {RoomAbility.messages, RoomAbility.calls}
          ..calls = calls
          ..timelines['!general'] = general;
        await _pump(tester, rooms);
        await tester.tap(_inList('oven'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('join voice'));
        await tester.pumpAndSettle();
        return calls;
      }

      testWidgets('shows muted in the call\'s own top bar', (tester) async {
        await joined(tester);

        final mark = find.byType(CallHealthMark);
        expect(mark, findsOneWidget);
        expect(
          tester
              .widget<Icon>(
                find.descendant(of: mark, matching: find.byType(Icon)),
              )
              .color,
          LoafTokens.of(tester.element(mark)).textMuted,
        );
      });

      testWidgets('leads the bar that follows you to other channels', (
        tester,
      ) async {
        await joined(tester);

        await tester.tap(_inList('general'));
        await tester.pumpAndSettle();

        final bar = find.byType(ConnectedCallBar);
        expect(
          find.descendant(of: bar, matching: find.byType(CallHealthMark)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: bar, matching: find.byIcon(LucideIcons.radio)),
          findsNothing,
        );
      });

      testWidgets('shows green on that bar', (tester) async {
        await joined(tester);
        await tester.tap(_inList('general'));
        await tester.pumpAndSettle();

        final mark = find.descendant(
          of: find.byType(ConnectedCallBar),
          matching: find.byType(CallHealthMark),
        );
        expect(
          tester
              .widget<Icon>(
                find.descendant(of: mark, matching: find.byType(Icon)),
              )
              .color,
          LoafTokens.of(tester.element(mark)).online,
        );
      });

      testWidgets('turns the bar to its warning colour when weak', (
        tester,
      ) async {
        final calls = await joined(tester);
        await tester.tap(_inList('general'));
        await tester.pumpAndSettle();

        calls
          ..quality = CallQuality.poor
          ..show(calls.session);
        await tester.pump();

        final title = tester.widget<Text>(find.text('Voice connected'));
        final tokens = LoafTokens.of(
          tester.element(find.text('Voice connected')),
        );
        expect(title.style?.color, tokens.idle);
      });
    });

    group('quitting while in a call', () {
      /// The shell with a voice channel joined on [calls].
      Future<void> inCall(
        WidgetTester tester,
        VoiceOnlyCalls calls, {
        BeforeQuit? beforeQuit,
      }) async {
        addTearDown(calls.dispose);
        final rooms = _FakeRooms(spaces: [_bakery()])
          ..abilities = {RoomAbility.messages, RoomAbility.calls}
          ..calls = calls;
        await _pump(tester, rooms, beforeQuit: beforeQuit);
        await tester.tap(_inList('oven'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('join voice'));
        await tester.pumpAndSettle();
      }

      testWidgets('a window asked to close leaves the call first', (
        tester,
      ) async {
        final calls = VoiceOnlyCalls();
        await inCall(tester, calls);

        final answer = await tester.binding.handleRequestAppExit();

        expect(calls.session, isNull);
        expect(answer, AppExitResponse.exit);
      });

      testWidgets('a signal to quit leaves the call', (tester) async {
        final calls = VoiceOnlyCalls();
        final beforeQuit = BeforeQuit();
        await inCall(tester, calls, beforeQuit: beforeQuit);

        await beforeQuit.run();

        expect(calls.session, isNull);
      });

      testWidgets('a leave that never finishes holds the window three '
          'seconds, no longer', (tester) async {
        final calls = VoiceOnlyCalls(leaving: Completer<void>().future);
        await inCall(tester, calls);
        AppExitResponse? answer;

        unawaited(
          tester.binding.handleRequestAppExit().then((a) => answer = a),
        );
        await tester.pump(BeforeQuit.limit - const Duration(milliseconds: 1));
        final before = answer;
        await tester.pump(const Duration(milliseconds: 1));

        expect(before, isNull);
        expect(answer, AppExitResponse.exit);
      });
    });

    testWidgets('calls with voice alone offer none in a DM', (tester) async {
      final calls = VoiceOnlyCalls();
      addTearDown(calls.dispose);
      final rooms = _FakeRooms(homeRooms: [_dm])
        ..abilities = {RoomAbility.messages, RoomAbility.calls}
        ..calls = calls;
      await _pump(tester, rooms);

      expect(find.byTooltip('Start a voice call'), findsNothing);
      expect(find.byTooltip('Start a video call'), findsNothing);
    });

    testWidgets('a DM offers no calls', (tester) async {
      await _pump(tester, _FakeRooms(homeRooms: [_dm]));
      expect(find.text("messages aren't available here yet"), findsOneWidget);
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

  group('being silenced by a moderator', () {
    /// The shell in the oven's call on [calls], reading a text channel.
    Future<void> inCall(WidgetTester tester, VoiceOnlyCalls calls) async {
      addTearDown(calls.dispose);
      final rooms = _FakeRooms(spaces: [_bakery()])
        ..abilities = {RoomAbility.messages, RoomAbility.calls}
        ..calls = calls;
      await _pump(tester, rooms);
      await tester.tap(_inList('oven'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('join voice'));
      await tester.pumpAndSettle();
    }

    /// Puts [silence] on you, as a sync would.
    Future<void> put(
      WidgetTester tester,
      VoiceOnlyCalls calls,
      CallSilence? silence,
    ) async {
      calls
        ..silenced = silence
        ..show(calls.session);
      // Until the toast is in; it then stays its reading time.
      await tester.pumpAndSettle();
    }

    final said = <String, (CallSilence?, CallSilence?, String)>{
      'muted': (null, CallSilence.muted, 'a moderator muted you'),
      'deafened': (null, CallSilence.deafened, 'a moderator deafened you'),
      'unmuted': (CallSilence.muted, null, 'a moderator unmuted you'),
      'undeafened': (CallSilence.deafened, null, 'a moderator undeafened you'),
    };
    for (final MapEntry(key: name, value: (before, after, words))
        in said.entries) {
      testWidgets('says so when you are $name', (tester) async {
        final calls = VoiceOnlyCalls();
        await inCall(tester, calls);
        if (before != null) {
          await put(tester, calls, before);
          await tester.pumpAndSettle(const Duration(seconds: 5));
        }

        await put(tester, calls, after);

        expect(find.text(words), findsOneWidget);
        await tester.pumpAndSettle(const Duration(seconds: 5));
      });
    }

    testWidgets('says nothing when you leave the call still silenced', (
      tester,
    ) async {
      final calls = VoiceOnlyCalls();
      await inCall(tester, calls);
      await put(tester, calls, CallSilence.muted);
      await tester.pumpAndSettle(const Duration(seconds: 5));

      calls
        ..silenced = null
        ..show(null);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('a moderator unmuted you'), findsNothing);
    });
  });

  group('muting someone for everyone', () {
    const ada = Member(
      '@ada:loaf.test',
      'Ada',
      Color(0xFF884422),
      presence: Presence.unknown,
    );

    Future<_FakeRooms> openMenu(
      WidgetTester tester, {
      Set<RoomAbility> abilities = const {RoomAbility.silence},
    }) async {
      final rooms = _FakeRooms(
        spaces: [
          _bakery(
            channels: const [
              Channel(id: '!general', name: 'general'),
              Channel(
                id: '!oven',
                name: 'oven',
                kind: ChannelKind.voice,
                occupants: [ada],
                canSilence: true,
              ),
            ],
          ),
        ],
      )..abilities = abilities;
      await _pump(tester, rooms);
      await tester.tap(
        find.byKey(const ValueKey('occupant-!oven-@ada:loaf.test')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      return rooms;
    }

    testWidgets('asks the rooms for it, of them, there', variant: _desktop, (
      tester,
    ) async {
      final rooms = await openMenu(tester);

      await tester.tap(find.text('mute for everyone'));
      await tester.pumpAndSettle();

      expect(rooms.silences, [('!oven', '@ada:loaf.test', CallSilence.muted)]);
    });

    testWidgets('says so when the server refuses', variant: _desktop, (
      tester,
    ) async {
      final rooms = await openMenu(tester);
      rooms.refuseSilences = true;

      await tester.tap(find.text('mute for everyone'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text("couldn't do that. try again?"), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 5));
    });

    testWidgets('is not offered by rooms that cannot', variant: _desktop, (
      tester,
    ) async {
      await openMenu(tester, abilities: const {});

      expect(find.text('mute for everyone'), findsNothing);
    });
  });

  group('kicking someone from a voice channel', () {
    const ada = Member(
      '@ada:loaf.test',
      'Ada',
      Color(0xFF884422),
      presence: Presence.unknown,
    );

    /// The shell on rooms where you may kick Ada, who is in the oven's
    /// call, with her menu open.
    Future<_FakeRooms> openMenu(
      WidgetTester tester, {
      Set<RoomAbility> abilities = const {RoomAbility.kick},
    }) async {
      final rooms = _FakeRooms(
        spaces: [
          _bakery(
            channels: const [
              Channel(id: '!general', name: 'general'),
              Channel(
                id: '!oven',
                name: 'oven',
                kind: ChannelKind.voice,
                occupants: [ada],
                kickBelow: 100,
              ),
            ],
          ),
        ],
      )..abilities = abilities;
      await _pump(tester, rooms);
      await tester.tap(
        find.byKey(const ValueKey('occupant-!oven-@ada:loaf.test')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      return rooms;
    }

    testWidgets('asks first, naming who and where', variant: _desktop, (
      tester,
    ) async {
      final rooms = await openMenu(tester);

      await tester.tap(find.text('kick from oven'));
      await tester.pumpAndSettle();

      expect(find.text('kick Ada from oven?'), findsOneWidget);
      expect(rooms.kicked, isEmpty);
    });

    testWidgets('kicks them from that room once confirmed', variant: _desktop, (
      tester,
    ) async {
      final rooms = await openMenu(tester);
      await tester.tap(find.text('kick from oven'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('kick'));
      await tester.pumpAndSettle();

      expect(rooms.kicked, [('!oven', '@ada:loaf.test')]);
    });

    testWidgets(
      'asks the server once, though asked again before it '
      'answers',
      variant: _desktop,
      (tester) async {
        final rooms = await openMenu(tester);
        rooms.kickAnswer = Completer();
        await tester.tap(find.text('kick from oven'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('kick'));
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const ValueKey('occupant-!oven-@ada:loaf.test')),
          buttons: kSecondaryButton,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('kick from oven'));
        await tester.pumpAndSettle();

        expect(find.text('kick Ada from oven?'), findsNothing);
        expect(rooms.kicked, hasLength(1));
        rooms.kickAnswer!.complete();
        await tester.pumpAndSettle();
      },
    );

    testWidgets('kicks nobody when cancelled', variant: _desktop, (
      tester,
    ) async {
      final rooms = await openMenu(tester);
      await tester.tap(find.text('kick from oven'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('cancel'));
      await tester.pumpAndSettle();

      expect(rooms.kicked, isEmpty);
    });

    testWidgets(
      'kicks nobody when the question is dismissed',
      variant: _desktop,
      (tester) async {
        final rooms = await openMenu(tester);
        await tester.tap(find.text('kick from oven'));
        await tester.pumpAndSettle();

        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();

        expect(find.text('kick Ada from oven?'), findsNothing);
        expect(rooms.kicked, isEmpty);
      },
    );

    testWidgets('says so when the server refuses', variant: _desktop, (
      tester,
    ) async {
      final rooms = await openMenu(tester);
      rooms.refuseKicks = true;
      await tester.tap(find.text('kick from oven'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('kick'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text("couldn't kick Ada"), findsOneWidget);
      // Let the toast go, so no timer outlives the test.
      await tester.pumpAndSettle(const Duration(seconds: 5));
    });

    testWidgets('is not offered by rooms that cannot kick', variant: _desktop, (
      tester,
    ) async {
      await openMenu(tester, abilities: const {});

      expect(find.text('kick from oven'), findsNothing);
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

  group('following a route to a message', () {
    /// Twenty messages in [roomId], ids `<roomId>-0` to `-19`.
    TimelineController conversation(String roomId) => TimelineController([
      for (var i = 0; i < 20; i++)
        Message(
          id: '$roomId-$i',
          author: i.isEven ? _me : _mod,
          sentAt: DateTime(2026, 10, 6, 9, i),
          body: '$roomId says $i',
        ),
    ], you: _me);

    _FakeRooms withConversations({List<Space>? spaces}) {
      final rooms = _FakeRooms(
        spaces: spaces ?? [_bakery()],
        homeRooms: const [_dm],
      )..abilities = {RoomAbility.answerInvites, RoomAbility.messages};
      for (final id in ['!general', '!dm']) {
        rooms.timelines[id] = conversation(id);
      }
      addTearDown(() {
        for (final t in rooms.timelines.values) {
          (t as TimelineController).dispose();
        }
      });
      return rooms;
    }

    Finder header(String name) => find.descendant(
      of: find.byType(ChannelView),
      matching: find.text(name),
    );

    testWidgets('opens the channel in its space, at the message', (
      tester,
    ) async {
      final routes = StreamController<MessageRoute>();
      addTearDown(routes.close);
      final rooms = withConversations();
      await _pump(tester, rooms, routes: routes.stream);

      routes.add(const MessageRoute('!general', '!general-3'));
      await tester.pumpAndSettle();
      expect(header('general'), findsOneWidget);
      expect(rooms.timelines['!general']!.jumpTarget, isNull); // Shown.
      expect(find.byKey(const ValueKey('jump-glow')), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a DM opens in Home', (tester) async {
      final routes = StreamController<MessageRoute>();
      addTearDown(routes.close);
      final rooms = withConversations();
      await _pump(tester, rooms, routes: routes.stream);
      await tester.tap(find.byKey(const ValueKey('space-!bakery')));
      await tester.pumpAndSettle();

      routes.add(const MessageRoute('!dm', '!dm-2'));
      await tester.pumpAndSettle();
      // "Moddy" also names the other author, so the header is no proof;
      // a message only this conversation has is.
      expect(find.text('!dm says 2'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a room you are not in says so, and stays put', (tester) async {
      final routes = StreamController<MessageRoute>();
      addTearDown(routes.close);
      final rooms = withConversations();
      await _pump(tester, rooms, routes: routes.stream);
      routes.add(const MessageRoute('!dm', '!dm-2'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));

      routes.add(const MessageRoute('!left', r'$any'));
      await tester.pumpAndSettle();
      expect(find.text(messageUnavailable), findsOneWidget);
      // "Moddy" also names the other author, so the header is no proof;
      // a message only this conversation has is.
      expect(find.text('!dm says 2'), findsOneWidget);
    });

    testWidgets('a route before the first sync waits for it', (tester) async {
      final routes = StreamController<MessageRoute>();
      addTearDown(routes.close);
      final rooms = withConversations()..synced = false;
      await _pump(tester, rooms, routes: routes.stream, settle: false);

      routes.add(const MessageRoute('!general', '!general-3'));
      await tester.pump();
      expect(find.text(messageUnavailable), findsNothing);

      rooms
        ..synced = true
        ..update();
      await tester.pumpAndSettle();
      expect(header('general'), findsOneWidget);
      expect(find.byKey(const ValueKey('jump-glow')), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a room in the space you are in stays there', (tester) async {
      final routes = StreamController<MessageRoute>();
      addTearDown(routes.close);
      final second = Space(
        id: '!second',
        name: 'Second',
        color: const Color(0xFF4E9E76),
        members: const [_me],
        categories: [
          ChannelCategory('', const [Channel(id: '!general', name: 'general')]),
        ],
      );
      final rooms = withConversations(spaces: [_bakery(), second]);
      await _pump(tester, rooms, routes: routes.stream);
      await tester.tap(find.byKey(const ValueKey('space-!second')));
      await tester.pumpAndSettle();

      routes.add(const MessageRoute('!general', '!general-3'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(ChannelList),
          matching: find.text('Second'),
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 2));
    });
  });
}
