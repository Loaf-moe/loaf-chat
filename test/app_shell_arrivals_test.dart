/// The shell's reaction to a message arriving, from the sync down: a real
/// client over the fake server, real rooms, the real shell, and fakes only
/// where the chime plays and the desktop shows a notification. Every
/// device setting and every state the decision reads: which channel is
/// open, whether the app is in front, and which platform.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:loaf_native/matrix/matrix_rooms.dart';
import 'package:loaf_native/ui/model/chime.dart';
import 'package:loaf_native/ui/model/desktop_notifications.dart';
import 'package:loaf_native/ui/model/message_route.dart';
import 'package:loaf_native/ui/settings/notification_settings.dart';
import 'package:loaf_native/ui/shell/app_shell.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _me = '@test:fakeServer.notExisting';
const _ada = '@ada:example.com';
const _bakery = '!bakery:example.com';
const _kitchen = '!kitchen:example.com';
const _pantry = '!pantry:example.com';

/// "Launch": the instant the shell opens. Messages are sent after it.
final _launch = DateTime.utc(2024, 1, 1, 12);
final _after = _launch.millisecondsSinceEpoch + 60000;

var _n = 0;

Map<String, Object?> _state(
  String type,
  Map<String, Object?> content, {
  String key = '',
  String sender = _me,
}) => {
  'type': type,
  'state_key': key,
  'sender': sender,
  'content': content,
  'event_id': '\$s${_n++}',
  'origin_server_ts': 1700000000000,
};

Map<String, Object?> _room(
  String name, {
  String? type,
  List<Map<String, Object?>> extra = const [],
}) => {
  'state': {
    'events': [
      _state('m.room.create', {'creator': _me, 'type': ?type}),
      _state('m.room.name', {'name': name}),
      _state('m.room.power_levels', {
        'users': {_me: 100},
        'users_default': 0,
      }),
      for (final (id, shown) in [(_me, 'Mochi'), (_ada, 'Ada')])
        _state(
          'm.room.member',
          {'membership': 'join', 'displayname': shown},
          key: id,
          sender: id,
        ),
      ...extra,
    ],
  },
  'summary': {'m.joined_member_count': 2, 'm.invited_member_count': 0},
};

Map<String, Object?> _child(String id) => _state('m.space.child', {
  'via': ['example.com'],
}, key: id);

Map<String, Object?> _msg(String id) => {
  'type': 'm.room.message',
  'sender': _ada,
  'content': {'msgtype': 'm.text', 'body': 'hi'},
  'event_id': id,
  'origin_server_ts': _after,
};

Future<void> _sync(Client client, Map<String, Object?> join) =>
    client.handleSync(
      SyncUpdate.fromJson({
        'next_batch': 'b${_n++}',
        'rooms': {'join': join},
      }),
    );

/// The Bakery space with #kitchen and #pantry, you and Ada in both.
Future<void> _joinBakery(Client client) => _sync(client, {
  _bakery: _room(
    'Bakery',
    type: 'm.space',
    extra: [_child(_kitchen), _child(_pantry)],
  ),
  _kitchen: _room('kitchen'),
  _pantry: _room('pantry'),
});

Future<void> _deliver(
  Client client,
  String room,
  List<Map<String, Object?>> events,
) => _sync(client, {
  room: {
    'timeline': {'events': events, 'limited': false, 'prev_batch': 'p${_n++}'},
  },
});

/// Waits until [done], however long a busy machine takes, then a little
/// longer, so a case expecting nothing has let anything late arrive.
Future<void> _until(bool Function() done) async {
  final give = DateTime.now().add(const Duration(seconds: 5));
  while (!done() && DateTime.now().isBefore(give)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  await Future<void>.delayed(const Duration(milliseconds: 100));
}

/// A few frames: the shell over real rooms never settles (something on it
/// always animates), so this stands in for `pumpAndSettle`.
Future<void> _pumps(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// A shell over a real client, with the fakes it chimes and notifies on.
class _Shell {
  _Shell(this.client, this.chime, this.desktop);

  final Client client;
  final FakeChime chime;
  final FakeDesktopNotifications desktop;
}

/// Mounts the shell signed in to the Bakery, at the given settings, on a
/// desktop or a phone. The client's work runs outside the test's fake
/// clock: its database lives in another isolate.
Future<_Shell> _mount(
  WidgetTester tester, {
  bool sound = true,
  bool notifications = true,
  bool showText = true,
  bool phone = false,
}) async {
  tester.view.physicalSize = phone
      ? const Size(390, 844)
      : const Size(1440, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  late final Client client;
  await tester.runAsync(() async {
    client = await openClient(
      httpClient: FakeMatrixApi(),
      databasePath: inMemoryDatabasePath,
    );
    FakeMatrixApi.client = client;
    client.backgroundSync = false;
    await client.init(
      newToken: 'abcd',
      newHomeserver: Uri.parse('https://fakeServer.notExisting'),
      newUserID: _me,
      newDeviceID: 'GHTYAJCE',
      newDeviceName: 'loaf on test',
      waitForFirstSync: true,
    );
    await _joinBakery(client);
  });

  final chime = FakeChime();
  final desktop = FakeDesktopNotifications();
  final controller = NotificationController(
    store: MemoryNotificationStore(),
    chime: chime,
    desktop: desktop,
    settings: NotificationSettings(
      sound: sound,
      notifications: notifications,
      showText: showText,
    ),
  );
  await tester.pumpWidget(
    NotificationScope(
      controller: controller,
      child: MaterialApp(
        theme: loafLightTheme(),
        // The shell disposes the rooms it is handed when it closes.
        home: AppShell(rooms: () => MatrixRooms(client, now: () => _launch)),
      ),
    ),
  );
  // The rooms read the client on its streams and ask the server after
  // you: real beats for the answers, fake frames for what they change.
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await _pumps(tester);
  }
  return _Shell(client, chime, desktop);
}

/// Opens #kitchen the way a tap does: on a phone, through the drawer.
Future<void> _openKitchen(WidgetTester tester, {required bool phone}) async {
  if (phone) {
    await tester.tap(find.byIcon(LucideIcons.menu));
    await _pumps(tester);
  }
  await tester.tap(find.byKey(const ValueKey('space-$_bakery')));
  await _pumps(tester);
  await tester.tap(find.byKey(const ValueKey('channel-$_kitchen')));
  await _pumps(tester);
}

/// Delivers [events] to [room] and lets the shell react.
Future<void> _arrive(
  WidgetTester tester,
  _Shell shell,
  String room,
  List<Map<String, Object?>> events, {
  required bool Function() done,
}) async {
  await tester.runAsync(() async {
    await _deliver(shell.client, room, events);
    await _until(done);
  });
  await tester.pump();
}

/// Mounts the shell on a desktop or a phone, in front or not, runs [body]
/// on it, then takes the shell down and the client with it: a client left
/// to a teardown keeps the test from ending.
Future<void> _run(
  WidgetTester tester, {
  bool phone = false,
  bool focused = true,
  bool sound = true,
  bool notifications = true,
  bool showText = true,
  required Future<void> Function(_Shell shell) body,
}) async {
  debugDefaultTargetPlatformOverride = phone
      ? TargetPlatform.iOS
      : TargetPlatform.macOS;
  _Shell? shell;
  try {
    if (!focused) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    }
    shell = await _mount(
      tester,
      sound: sound,
      notifications: notifications,
      showText: showText,
      phone: phone,
    );
    await body(shell);
  } finally {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    debugDefaultTargetPlatformOverride = null;
    await tester.pumpWidget(const SizedBox());
    await _pumps(tester);
    // Closing the in-memory database from a widget test never returns;
    // the client lets go of everything else.
    if (shell != null) {
      await tester.runAsync(() => shell!.client.dispose(closeDatabase: false));
    }
  }
}

void main() {
  group('an arrival', () {
    for (final focused in [true, false]) {
      for (final open in [true, false]) {
        for (final phone in [false, true]) {
          for (final sound in [true, false]) {
            for (final notifications in [true, false]) {
              for (final showText in [true, false]) {
                final room = open ? _kitchen : _pantry;
                final chimes = focused && !open && sound ? 1 : 0;
                final notices = !focused && !phone && notifications ? 1 : 0;
                testWidgets(
                  '${focused ? 'in front' : 'in the background'}, '
                  '${open ? 'the open channel' : 'another channel'}, '
                  '${phone ? 'phone' : 'desktop'}, '
                  'sound ${sound ? 'on' : 'off'}, '
                  'notifications ${notifications ? 'on' : 'off'}, '
                  'text ${showText ? 'on' : 'off'}',
                  (tester) => _run(
                    tester,
                    phone: phone,
                    focused: focused,
                    sound: sound,
                    notifications: notifications,
                    showText: showText,
                    body: (shell) async {
                      await _openKitchen(tester, phone: phone);
                      await _arrive(
                        tester,
                        shell,
                        room,
                        [_msg(r'$m')],
                        done: () =>
                            shell.chime.plays >= chimes &&
                            shell.desktop.shown.length >= notices,
                      );
                      expect(shell.chime.plays, chimes);
                      expect(shell.desktop.shown.length, notices);
                      if (notices == 1) {
                        final notice = shell.desktop.shown.single;
                        expect(notice.sound, sound);
                        expect(notice.body, showText ? 'hi' : 'new message');
                        expect(
                          notice.title,
                          'Ada in #${open ? 'kitchen' : 'pantry'} · Bakery',
                        );
                        expect(notice.route, MessageRoute(room, r'$m'));
                      }
                    },
                  ),
                );
              }
            }
          }
        }
      }
    }
  });

  group('a burst', () {
    testWidgets(
      'in front, two messages in one sync chime once',
      (tester) => _run(
        tester,
        body: (shell) async {
          await _openKitchen(tester, phone: false);
          await _arrive(tester, shell, _pantry, [
            _msg(r'$a'),
            _msg(r'$b'),
          ], done: () => shell.chime.plays >= 1);
          expect(shell.chime.plays, 1);
        },
      ),
    );

    testWidgets(
      'in the background, the second notice is silent',
      (tester) => _run(
        tester,
        focused: false,
        body: (shell) async {
          await _openKitchen(tester, phone: false);
          await _arrive(tester, shell, _pantry, [
            _msg(r'$a'),
            _msg(r'$b'),
          ], done: () => shell.desktop.shown.length >= 2);
          expect(shell.desktop.shown.map((n) => n.sound), [true, false]);
          expect(shell.chime.plays, 0);
        },
      ),
    );

    testWidgets(
      'in the background with sound off, no notice sounds',
      (tester) => _run(
        tester,
        focused: false,
        sound: false,
        body: (shell) async {
          await _openKitchen(tester, phone: false);
          await _arrive(tester, shell, _pantry, [
            _msg(r'$a'),
            _msg(r'$b'),
          ], done: () => shell.desktop.shown.length >= 2);
          expect(shell.desktop.shown.map((n) => n.sound), [false, false]);
          expect(shell.chime.plays, 0);
        },
      ),
    );
  });

  group('the shell opening', () {
    for (final notifications in [true, false]) {
      testWidgets(
        'on a desktop with notifications ${notifications ? 'on' : 'off'}, '
        'the desktop is ${notifications ? '' : 'not '}prepared',
        (tester) => _run(
          tester,
          notifications: notifications,
          body: (shell) async {
            expect(shell.desktop.prepared, notifications ? 1 : 0);
          },
        ),
      );
    }
  });
}
