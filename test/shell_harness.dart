/// What a shell test over a real client needs: the fake server, real
/// rooms, the real shell, and fakes only where the chime plays and the
/// desktop shows a notification. Used by the arrival and notice suites.
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
import 'package:loaf_native/util/json_store.dart';

const _me = '@test:fakeServer.notExisting';
const _ada = '@_ada:example.com';
const _bakery = '!_bakery:example.com';
const kitchen = '!kitchen:example.com';
const pantry = '!pantry:example.com';

/// "Launch": the instant the shell opens. Messages are sent after it.
final _launch = DateTime.utc(2024, 1, 1, 12);
final after = _launch.millisecondsSinceEpoch + 60000;

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

/// Ada's message [id], sent at [ts], a minute after launch unless said.
Map<String, Object?> msg(String id, {int? ts}) => {
  'type': 'm.room.message',
  'sender': _ada,
  'content': {'msgtype': 'm.text', 'body': 'hi'},
  'event_id': id,
  'origin_server_ts': ts ?? after,
};

/// Your read receipt on [eventId], placed at [ts].
Map<String, Object?> receipt(String eventId, {required int ts}) => {
  'type': 'm.receipt',
  'content': {
    eventId: {
      'm.read': {
        _me: {'ts': ts},
      },
    },
  },
};

Future<void> _sync(
  Client client, {
  Map<String, Object?> join = const {},
  Map<String, Object?> leave = const {},
}) => client.handleSync(
  SyncUpdate.fromJson({
    'next_batch': 'b${_n++}',
    'rooms': {'join': join, 'leave': leave},
  }),
);

/// The Bakery space with #kitchen and #pantry, you and Ada in both.
Future<void> _joinBakery(Client client) => _sync(
  client,
  join: {
    _bakery: _room(
      'Bakery',
      type: 'm.space',
      extra: [_child(kitchen), _child(pantry)],
    ),
    kitchen: _room('kitchen'),
    pantry: _room('pantry'),
  },
);

Future<void> deliver(
  Client client,
  String roomId,
  List<Map<String, Object?>> events, {
  List<Map<String, Object?>> ephemeral = const [],
}) => _sync(
  client,
  join: {
    roomId: {
      'timeline': {
        'events': events,
        'limited': false,
        'prev_batch': 'p${_n++}',
      },
      if (ephemeral.isNotEmpty) 'ephemeral': {'events': ephemeral},
    },
  },
);

/// Leaves [roomId], as a sync reports it: your own leave in its timeline.
Future<void> leaveRoom(Client client, String roomId) => _sync(
  client,
  leave: {
    roomId: {
      'timeline': {
        'events': [
          {
            ..._state('m.room.member', {'membership': 'leave'}, key: _me),
            'origin_server_ts': after,
          },
        ],
        'limited': false,
        'prev_batch': 'p${_n++}',
      },
    },
  },
);

/// Waits until [done], however long a busy machine takes, then a little
/// longer, so a case expecting nothing has let anything late arrive.
Future<void> _until(bool Function() done) async {
  final give = DateTime.now().add(const Duration(seconds: 5));
  while (!done() && DateTime.now().isBefore(give)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  await Future<void>.delayed(const Duration(milliseconds: 300));
}

/// A few frames: the shell over real rooms never settles (something on it
/// always animates), so this stands in for `pumpAndSettle`.
Future<void> _pumps(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Real beats and fake frames, interleaved: for whatever the shell asked
/// the server, and what it draws with the answers.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await _pumps(tester);
  }
}

/// A shell over a real client, with the fakes it chimes and notifies on.
class Shell {
  Shell(this.client, this.chime, this.desktop);

  final Client client;
  final FakeChime chime;
  final FakeDesktopNotifications desktop;
}

/// Mounts the shell signed in to the Bakery, at the given settings, on a
/// desktop or a phone. The client's work runs outside the test's fake
/// clock: its database lives in another isolate. [routes] is what the
/// shell follows, as the app hands it the desktop's clicks.
Future<Shell> _mount(
  WidgetTester tester, {
  bool sound = true,
  bool notifications = true,
  bool showText = true,
  bool phone = false,
  FakeMatrixApi? api,
  Stream<MessageRoute> Function(FakeDesktopNotifications desktop)? routes,
}) async {
  tester.view.physicalSize = phone
      ? const Size(390, 844)
      : const Size(1440, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  late final Client client;
  await tester.runAsync(() async {
    client = await openClient(
      httpClient: api ?? FakeMatrixApi(),
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
    store: MemoryStore<NotificationSettings>(),
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
        home: AppShell(
          // The shell disposes the rooms it is handed when it closes.
          rooms: () => MatrixRooms(client, now: () => _launch),
          routes: routes?.call(desktop),
        ),
      ),
    ),
  );
  // The rooms read the client on its streams and ask the server after
  // you; the answers need real beats, what they change needs frames.
  await settle(tester);
  return Shell(client, chime, desktop);
}

/// Opens [roomId] in the Bakery the way a tap does: on a phone, through
/// the drawer.
Future<void> openChannel(
  WidgetTester tester,
  String roomId, {
  bool phone = false,
}) async {
  if (phone) {
    await tester.tap(find.byIcon(LucideIcons.menu));
    await _pumps(tester);
  }
  await tester.tap(find.byKey(const ValueKey('space-$_bakery')));
  await _pumps(tester);
  await tester.tap(find.byKey(ValueKey('channel-$roomId')));
  await _pumps(tester);
}

/// Runs the client's [work], waits for [done], and lets the shell react.
Future<void> react(
  WidgetTester tester,
  Future<void> Function() work, {
  required bool Function() done,
}) async {
  await tester.runAsync(() async {
    await work();
    await _until(done);
  });
  await tester.pump();
}

/// Delivers [events] to [roomId] and lets the shell react.
Future<void> arrive(
  WidgetTester tester,
  Shell shell,
  String roomId,
  List<Map<String, Object?>> events, {
  required bool Function() done,
}) => react(tester, () => deliver(shell.client, roomId, events), done: done);

/// Brings the app to the front, or sends it to the background.
void focus(WidgetTester tester, {required bool focused}) =>
    tester.binding.handleAppLifecycleStateChanged(
      focused ? AppLifecycleState.resumed : AppLifecycleState.inactive,
    );

/// Mounts the shell on a desktop or a phone, in front or not, runs [body]
/// on it, then takes the shell down and the client with it: a client left
/// to a teardown keeps the test from ending.
Future<void> run(
  WidgetTester tester, {
  bool phone = false,
  bool focused = true,
  bool sound = true,
  bool notifications = true,
  bool showText = true,
  FakeMatrixApi? api,
  Stream<MessageRoute> Function(FakeDesktopNotifications desktop)? routes,
  required Future<void> Function(Shell shell) body,
}) async {
  debugDefaultTargetPlatformOverride = phone
      ? TargetPlatform.iOS
      : TargetPlatform.macOS;
  Shell? shell;
  try {
    focus(tester, focused: focused);
    shell = await _mount(
      tester,
      sound: sound,
      notifications: notifications,
      showText: showText,
      phone: phone,
      api: api,
      routes: routes,
    );
    await body(shell);
  } finally {
    focus(tester, focused: true);
    debugDefaultTargetPlatformOverride = null;
    // Coming to the front marks the open channel read: let that request
    // finish, or its timeout outlives the tree.
    await settle(tester);
    await tester.pumpWidget(const SizedBox());
    await _pumps(tester);
    // Closing the in-memory database from a widget test never returns;
    // the client lets go of everything else.
    if (shell != null) {
      await tester.runAsync(() => shell!.client.dispose(closeDatabase: false));
    }
  }
}
