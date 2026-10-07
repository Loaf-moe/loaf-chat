import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show Colors;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:loaf_native/matrix/matrix_rooms.dart';
import 'package:loaf_native/matrix/unread_tally.dart';
import 'package:loaf_native/ui/members/presence.dart' as loaf;
import 'package:loaf_native/ui/model/models.dart';
import 'package:loaf_native/ui/rooms/rooms.dart';
// The SDK has a Role of its own; the one under test is loaf's.
import 'package:matrix/matrix.dart' hide MediaKind, Role;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _me = '@test:fakeServer.notExisting';

/// The fake server, plus answers it lacks: joining and leaving a room, muting
/// (the push-rules endpoints) and tagging. [hold] keeps those answers back
/// until completed; [refuse] makes them a 403.
class _Api extends FakeMatrixApi {
  final answered = <String>[];
  Completer<void>? hold;
  var refuse = false;

  /// Joins and leaves whose room id (undecoded, matched against the
  /// request path) are refused, even while [refuse] is false.
  final refuseIds = <String>{};

  /// `createRoom` calls whose `name` is refused, even while [refuse] is
  /// false.
  final refuseNames = <String>{};

  /// User ids an `/invite` call refuses, even while [refuse] is false.
  final refuseInviteIds = <String>{};

  /// User ids an `/invite` call answers with a body that is not JSON, so
  /// the SDK throws something other than a [MatrixException].
  final brokenInviteIds = <String>{};

  /// When set, every `/hierarchy` call fails with a server error.
  var failHierarchy = false;

  /// When set, the display name every profile answers with.
  String? profileName;

  /// Each space's `/hierarchy` pages, in order, keyed by space id.
  final hierarchyPages = <String, List<Map<String, Object?>>>{};

  /// Each room's events, newest first, served by `/messages?dir=b` in
  /// pages of the request's `limit`. `from` is the index to start at.
  final roomHistory = <String, List<Map<String, Object?>>>{};

  /// How many `/messages` calls each room has had.
  final historyCalls = <String, int>{};

  /// While set, `/messages` fails with a server error.
  var failHistory = false;

  var _createdRooms = 0;

  /// Set by [_client], since [FakeMatrixApi.client] is a setter only:
  /// [mockIntercept] needs the client itself to push a fake sync.
  Client? ownerClient;

  @override
  FutureOr<http.Response> mockIntercept(http.Request request) async {
    final path = request.url.path;
    if (profileName != null &&
        request.method == 'GET' &&
        path.contains('/profile/')) {
      return http.Response(jsonEncode({'displayname': profileName}), 200);
    }
    if (request.method == 'GET' && path.contains('/hierarchy')) {
      if (failHierarchy) {
        return http.Response(
          jsonEncode({'errcode': 'M_UNKNOWN', 'error': 'boom'}),
          500,
        );
      }
      final spaceId = Uri.decodeComponent(
        path.split('/rooms/')[1].split('/hierarchy')[0],
      );
      final pages = hierarchyPages[spaceId] ?? const [];
      final from = request.url.queryParameters['from'];
      final index = from == null ? 0 : int.parse(from);
      final page = index < pages.length ? pages[index] : {'rooms': <Object?>[]};
      return http.Response(jsonEncode(page), 200);
    }
    if (request.method == 'POST' && path.endsWith('/createRoom')) {
      final body = jsonDecode(request.body) as Map<String, Object?>;
      final creationContent = body['creation_content'] as Map<String, Object?>?;
      final isSpace = creationContent?['type'] == 'm.space';
      final name = body['name'] as String?;
      answered.add(path);
      await hold?.future;
      if (refuse || (name != null && refuseNames.contains(name))) {
        return http.Response(
          jsonEncode({'errcode': 'M_FORBIDDEN', 'error': 'not allowed'}),
          403,
        );
      }
      final id = isSpace
          ? '!created:example.com'
          : '!created-${_createdRooms++}:example.com';
      final isDirect = body['is_direct'] == true;
      if (isSpace || isDirect) {
        final client = ownerClient!;
        unawaited(
          Future(
            () => client.handleSync(
              SyncUpdate.fromJson({
                'next_batch': 'created-room-${_events++}',
                'rooms': {
                  'join': {
                    id: isSpace
                        ? _room('created', type: 'm.space')
                        : _room('created'),
                  },
                },
              }),
            ),
          ),
        );
      }
      return http.Response(jsonEncode({'room_id': id}), 200);
    }
    if (request.method == 'POST' && path.endsWith('/invite')) {
      final userId =
          (jsonDecode(request.body) as Map<String, Object?>)['user_id']
              as String;
      answered.add(path);
      await hold?.future;
      if (brokenInviteIds.contains(userId)) {
        return http.Response('not json', 200);
      }
      if (refuse || refuseInviteIds.contains(userId)) {
        return http.Response(
          jsonEncode({'errcode': 'M_FORBIDDEN', 'error': 'not allowed'}),
          403,
        );
      }
      return http.Response(jsonEncode({}), 200);
    }
    final method = request.method;
    final isJoinOrLeave =
        method == 'POST' &&
        (path.endsWith('/join') ||
            path.contains('/join/') ||
            path.endsWith('/leave'));
    final isMuteOrTag =
        (method == 'PUT' || method == 'DELETE') &&
        (path.contains('/pushrules/') || path.contains('/tags/'));
    final isSpaceState =
        method == 'PUT' &&
        (path.contains('/state/m.space.child/') ||
            path.contains('/state/m.space.parent/'));
    if (isJoinOrLeave || isMuteOrTag || isSpaceState) {
      answered.add(path);
      await hold?.future;
      final blockedById = refuseIds.any(
        (id) => path.contains(Uri.encodeComponent(id)),
      );
      if (refuse || (isJoinOrLeave && blockedById)) {
        return http.Response(
          jsonEncode({'errcode': 'M_FORBIDDEN', 'error': 'not allowed'}),
          403,
        );
      }
      if (isSpaceState) {
        return http.Response(jsonEncode({'event_id': '\$ev${_events++}'}), 200);
      }
      return isJoinOrLeave
          ? http.Response(jsonEncode({'room_id': '!invited:example.com'}), 200)
          : http.Response(jsonEncode({}), 200);
    }
    if (request.method == 'POST' && path.endsWith('/read_markers')) {
      answered.add(path);
      return http.Response('{}', 200);
    }
    if (request.method == 'GET' && path.endsWith('/messages')) {
      final roomId = Uri.decodeComponent(
        path.split('/rooms/')[1].split('/messages')[0],
      );
      historyCalls[roomId] = (historyCalls[roomId] ?? 0) + 1;
      // Read before the hold: a held fetch answers with what the server
      // had when it was asked.
      final events = roomHistory[roomId] ?? const [];
      await hold?.future;
      if (failHistory) {
        return http.Response(
          jsonEncode({'errcode': 'M_UNKNOWN', 'error': 'boom'}),
          500,
        );
      }
      final from = int.tryParse(request.url.queryParameters['from'] ?? '') ?? 0;
      final limit =
          int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 10;
      final end = (from + limit).clamp(0, events.length);
      return http.Response(
        jsonEncode({
          'start': '$from',
          'chunk': events.sublist(from.clamp(0, events.length), end),
          if (end < events.length) 'end': '$end',
        }),
        200,
      );
    }
    return super.mockIntercept(request);
  }
}

/// A client signed in to the fake server. Its first sync, handled unless
/// [firstSync] is false, has two joined rooms (one a DM) and push rules.
Future<Client> _client({_Api? api, bool firstSync = true}) async {
  final client = await openClient(
    httpClient: api ?? FakeMatrixApi(),
    databasePath: inMemoryDatabasePath,
  );
  FakeMatrixApi.client = client;
  api?.ownerClient = client;
  await client.init(
    newToken: 'abcd',
    newHomeserver: Uri.parse('https://fakeServer.notExisting'),
    newUserID: _me,
    newDeviceID: 'GHTYAJCE',
    newDeviceName: 'loaf on test',
    waitForFirstSync: firstSync,
  );
  addTearDown(client.dispose);
  return client;
}

Future<MatrixRooms> _rooms(Client client) async {
  final rooms = MatrixRooms(client);
  addTearDown(rooms.dispose);
  await _settle();
  return rooms;
}

/// Lets the SDK's streams deliver.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

var _events = 0;

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
  'event_id': '\$e${_events++}',
  'origin_server_ts': 1700000000000,
};

Map<String, Object?> _child(String id) => _state('m.space.child', {
  'via': ['example.com'],
}, key: id);

Map<String, Object?> _room(
  String name, {
  String? type,
  List<Map<String, Object?>> extra = const [],
  List<Map<String, Object?>> accountData = const [],
  int notifications = 0,
  int highlights = 0,
}) => {
  'state': {
    'events': [
      _state('m.room.create', {'creator': _me, 'type': ?type}),
      _state('m.room.name', {'name': name}),
      _state('m.room.member', {'membership': 'join'}, key: _me),
      ...extra,
    ],
  },
  'account_data': {'events': accountData},
  'unread_notifications': {
    'notification_count': notifications,
    'highlight_count': highlights,
  },
};

Future<void> _sync(Client client, Map<String, Object?> rooms) =>
    client.handleSync(
      SyncUpdate.fromJson({'next_batch': 'b${_events++}', 'rooms': rooms}),
    );

/// A text message from [sender], [id] or a fresh one, sent at [ts] or a
/// fresh, later time.
Map<String, Object?> _msg(
  String body, {
  String sender = '@ada:example.com',
  String? id,
  int? ts,
  Map<String, Object?>? mentions,
}) => {
  'type': 'm.room.message',
  'sender': sender,
  'content': {'msgtype': 'm.text', 'body': body, 'm.mentions': ?mentions},
  'event_id': id ?? '\$m${_events++}',
  'origin_server_ts': ts ?? 1700000000000 + _events++ * 1000,
};

/// Your own `m.room.member` event: a join, or a profile change when
/// [profileChange] says you were already in.
Map<String, Object?> _join({bool profileChange = false, int? ts}) => {
  'type': 'm.room.member',
  'state_key': _me,
  'sender': _me,
  'content': {'membership': 'join', 'displayname': 'Test'},
  'unsigned': {
    if (profileChange)
      'prev_content': {'membership': 'join', 'displayname': 'Old'},
  },
  'event_id': '\$j${_events++}',
  'origin_server_ts': ts ?? 1700000000000 + _events++ * 1000,
};

/// Your receipt on [eventId], placed at [ts].
Map<String, Object?> _receipt(
  String eventId, {
  required int ts,
  String? thread,
}) => {
  'type': 'm.receipt',
  'content': {
    eventId: {
      'm.read': {
        _me: {'ts': ts, 'thread_id': ?thread},
      },
    },
  },
};

/// A sync of one joined room's new [timeline] events and [ephemeral]
/// events. [limited] says the server skipped some.
Future<void> _timeline(
  Client client,
  String roomId,
  List<Map<String, Object?>> timeline, {
  List<Map<String, Object?>> ephemeral = const [],
  bool limited = false,
}) => _sync(client, {
  'join': {
    roomId: {
      'timeline': {
        'events': timeline,
        'limited': limited,
        'prev_batch': 'p${_events++}',
      },
      'ephemeral': {'events': ephemeral},
    },
  },
});

/// A space "Bakery" with a channel and a voice channel directly under it, a
/// category subspace holding a private channel and a nested subspace, and a
/// child you have not joined. "Annex" is a second space.
Future<void> _bakery(Client client) => _sync(client, {
  'join': {
    '!bakery:example.com': _room(
      'Bakery',
      type: 'm.space',
      extra: [
        _child('!general:example.com'),
        _child('!oven:example.com'),
        _child('!recipes:example.com'),
        _child('!unjoined:example.com'),
        _state('m.room.power_levels', {
          'users': {_me: 100, '@mod:example.com': 50},
        }),
        _state(
          'm.room.member',
          {'membership': 'join', 'displayname': 'Moddy'},
          key: '@mod:example.com',
          sender: '@mod:example.com',
        ),
      ],
    ),
    '!annex:example.com': _room('annex', type: 'm.space'),
    '!general:example.com': _room('general', notifications: 3),
    '!oven:example.com': _room('oven', type: 'm.call'),
    '!recipes:example.com': _room(
      'recipes',
      type: 'm.space',
      extra: [_child('!sourdough:example.com'), _child('!deeper:example.com')],
    ),
    '!sourdough:example.com': _room(
      'sourdough',
      highlights: 1,
      notifications: 4,
      extra: [
        _state('m.room.join_rules', {'join_rule': 'invite'}),
        _state('m.room.topic', {'topic': 'wild yeast'}),
      ],
    ),
    '!deeper:example.com': _room(
      'deeper',
      type: 'm.space',
      extra: [_child('!crumb:example.com')],
    ),
    '!crumb:example.com': _room('crumb'),
  },
});

/// Someone inviting you to a room, the way a server sends it: stripped
/// state with your membership and the inviter's profile.
Future<void> _invited(Client client, {bool direct = false}) => _sync(client, {
  'invite': {
    '!invited:example.com': {
      'invite_state': {
        'events': [
          _state('m.room.name', {'name': 'Proofing'}, sender: '@al:x.y'),
          _state('m.room.topic', {'topic': 'rise'}, sender: '@al:x.y'),
          _state(
            'm.room.member',
            {'membership': 'join', 'displayname': 'Al'},
            key: '@al:x.y',
            sender: '@al:x.y',
          ),
          _state(
            'm.room.member',
            {'membership': 'invite', 'is_direct': direct},
            key: _me,
            sender: '@al:x.y',
          ),
        ],
      },
    },
  },
});

void main() {
  group('unread', () {
    const general = '!general:example.com';

    // _Api, not the plain fake: muting needs its push-rules answers.
    Future<(Client, MatrixRooms)> bakery() async {
      final client = await _client(api: _Api());
      final rooms = await _rooms(client);
      await _bakery(client);
      await _settle();
      return (client, rooms);
    }

    Channel channel(MatrixRooms rooms, String id) =>
        rooms.spaces.expand((s) => s.allChannels).firstWhere((c) => c.id == id);

    test('messages from others count; the server\'s numbers do not', () async {
      final (client, rooms) = await bakery();
      // _bakery gives #general a notification_count of 3 and no messages.
      expect(channel(rooms, general).unread, 0);

      await _timeline(client, general, [_msg('one'), _msg('two')]);
      await _settle();
      expect(channel(rooms, general).unread, 2);
    });

    test('a mention counts toward mentions', () async {
      final (client, rooms) = await bakery();
      await _timeline(client, general, [
        _msg(
          'hey',
          mentions: {
            'user_ids': [_me],
          },
        ),
        _msg('chatter', mentions: <String, Object?>{}),
      ]);
      await _settle();
      expect(channel(rooms, general).unread, 2);
      expect(channel(rooms, general).mentions, 1);
    });

    test('an encrypted message is checked again once it can be read', () async {
      final (client, rooms) = await bakery();
      await _timeline(client, general, [
        {
          'type': 'm.room.encrypted',
          'sender': '@ada:example.com',
          'content': {
            'algorithm': 'm.megolm.v1.aes-sha2',
            'ciphertext': 'locked',
            'session_id': 'nokey',
            'sender_key': 'k',
            'device_id': 'D',
          },
          'event_id': r'$locked',
          'origin_server_ts': 1700000000000 + _events++ * 1000,
        },
      ]);
      await _settle();
      expect(channel(rooms, general).unread, 1);
      expect(channel(rooms, general).mentions, 0);

      // The key arrived and the SDK stored the message decrypted.
      final room = client.getRoomById(general)!;
      await client.database.storeEventUpdate(
        general,
        Event(
          type: EventTypes.Message,
          content: {
            'msgtype': 'm.text',
            'body': 'hey',
            'm.mentions': {
              'user_ids': [_me],
            },
          },
          senderId: '@ada:example.com',
          eventId: r'$locked',
          originServerTs: DateTime.fromMillisecondsSinceEpoch(1700000000000),
          room: room,
        ),
        EventUpdateType.timeline,
        client,
      );
      await _timeline(client, general, const []);
      await _settle();
      expect(channel(rooms, general).mentions, 1);
    });

    test(
      'a fill finishing during the re-check does not lose the sync',
      () async {
        final api = _Api();
        final client = await _client(api: api);
        final rooms = await _rooms(client);
        await _bakery(client);
        await _settle();
        await _timeline(client, general, [
          {
            'type': 'm.room.encrypted',
            'sender': '@ada:example.com',
            'content': {
              'algorithm': 'm.megolm.v1.aes-sha2',
              'ciphertext': 'locked',
              'session_id': 'nokey',
              'sender_key': 'k',
              'device_id': 'D',
            },
            'event_id': r'$locked',
            'origin_server_ts': 1700000000000 + _events++ * 1000,
          },
        ]);
        await _settle();

        // A room never counted starts a fill that waits on the server.
        const oven = '!oven:example.com';
        api.hold = Completer<void>();
        api.roomHistory[oven] = [_msg('baked')];
        await _timeline(client, oven, [
          api.roomHistory[oven]!.first,
        ], limited: true);
        await _settle();

        // The fill lands, adding a tally, while this sync re-checks general.
        final sync = _timeline(client, general, [_msg('after')]);
        api.hold!.complete();
        await sync;
        await _settle();
        expect(channel(rooms, general).unread, 2);
        expect(channel(rooms, oven).unread, 1);
      },
    );

    test('a muted room still counts', () async {
      final (client, rooms) = await bakery();
      await rooms.setMuted(general, true);
      await _timeline(client, general, [_msg('one')]);
      await _settle();
      expect(channel(rooms, general).unread, 1);
    });

    test('your receipt reads what came before it', () async {
      final (client, rooms) = await bakery();
      await _timeline(client, general, [
        _msg('one', id: r'$one'),
        _msg('two', id: r'$two'),
        _msg('three', id: r'$three'),
      ]);
      await _timeline(
        client,
        general,
        const [],
        ephemeral: [_receipt(r'$two', ts: 0)],
      );
      await _settle();
      expect(channel(rooms, general).unread, 1);
    });

    test('a receipt on the main timeline reads too', () async {
      // Element Web sends m.read with thread_id "main"; the SDK keeps it
      // apart from the unthreaded ones.
      final (client, rooms) = await bakery();
      await _timeline(client, general, [
        _msg('one', id: r'$one'),
        _msg('two', id: r'$two'),
      ]);
      await _timeline(
        client,
        general,
        const [],
        ephemeral: [_receipt(r'$two', ts: 0, thread: 'main')],
      );
      await _settle();
      expect(channel(rooms, general).unread, 0);
    });

    test(
      'a receipt recorded before its message arrives still reads it',
      () async {
        final (client, rooms) = await bakery();
        await _timeline(
          client,
          general,
          const [],
          ephemeral: [_receipt(r'$m', ts: 0)],
        );
        await _settle();
        await _timeline(client, general, [_msg('covered', id: r'$m')]);
        await _settle();
        expect(channel(rooms, general).unread, 0);
      },
    );

    test(
      'read on another device, by time, on an event never counted',
      () async {
        final (client, rooms) = await bakery();
        await _timeline(client, general, [
          _msg('one', ts: 1000),
          _msg('two', ts: 2000),
        ]);
        await _timeline(
          client,
          general,
          const [],
          ephemeral: [_receipt(r'$reaction-elsewhere', ts: 2000)],
        );
        await _settle();
        expect(channel(rooms, general).unread, 0);
      },
    );

    test(
      'an old receipt is not applied again to a later, older message',
      () async {
        final (client, rooms) = await bakery();
        await _timeline(client, general, [_msg('one', ts: 1000)]);
        await _timeline(
          client,
          general,
          const [],
          ephemeral: [_receipt(r'$reaction-elsewhere', ts: 5000)],
        );
        await _settle();
        expect(channel(rooms, general).unread, 0);

        // Federation lag: it arrives late, stamped before the receipt.
        await _timeline(client, general, [_msg('late', ts: 3000)]);
        await _settle();
        expect(channel(rooms, general).unread, 1);
      },
    );

    group('across a relaunch', () {
      Future<(Client, Directory, Directory)> launch() async {
        final client = await _client(api: _Api());
        final dir = await Directory.systemTemp.createTemp('loaf-unread');
        // Rooms disposed in teardown write the file once more; let it land.
        addTearDown(() async {
          await _settle();
          await dir.delete(recursive: true);
        });
        final files = Directory('${dir.path}${Platform.pathSeparator}files');
        return (client, dir, files);
      }

      test('a relaunch shows the counts before the server answers', () async {
        final api = _Api();
        final client = await _client(api: api);
        final dir = await Directory.systemTemp.createTemp('loaf-unread');
        // Rooms disposed in teardown write the file once more; let it land.
        addTearDown(() async {
          await _settle();
          await dir.delete(recursive: true);
        });
        final files = Directory('${dir.path}${Platform.pathSeparator}files');

        final first = MatrixRooms(client, mediaRoot: files);
        await _bakery(client);
        await _timeline(client, general, [_msg('one'), _msg('two')]);
        await _settle();
        first.dispose();
        // Disposing writes the file; let it land.
        await _settle();

        // The server is unreachable: only the saved counts can say 2.
        api.failHistory = true;
        final second = MatrixRooms(client, mediaRoot: files);
        addTearDown(second.dispose);
        await _settle();
        expect(channel(second, general).unread, 2);
        expect(
          File('${dir.path}${Platform.pathSeparator}unread.json').existsSync(),
          isTrue,
        );
      });

      test('a restored receipt is not applied again', () async {
        final (client, dir, files) = await launch();

        final first = MatrixRooms(client, mediaRoot: files);
        await _bakery(client);
        await _timeline(client, general, [_msg('one', ts: 1000)]);
        await _timeline(
          client,
          general,
          const [],
          ephemeral: [_receipt(r'$reaction-elsewhere', ts: 5000)],
        );
        await _settle();
        expect(channel(first, general).unread, 0);
        first.dispose();
        await _settle();

        final second = MatrixRooms(client, mediaRoot: files);
        addTearDown(second.dispose);
        await _settle();
        // Federation lag: it arrives late, stamped before the old receipt.
        await _timeline(client, general, [_msg('late', ts: 3000)]);
        await _settle();
        expect(channel(second, general).unread, 1);
      });

      test('saving at dispose does not bring back a cleared folder', () async {
        // Signing out clears the folder the file lives in.
        final client = await _client(api: _Api());
        final dir = await Directory.systemTemp.createTemp('loaf-unread');
        final files = Directory('${dir.path}${Platform.pathSeparator}files');
        final rooms = MatrixRooms(client, mediaRoot: files);
        await _bakery(client);
        await _timeline(client, general, [_msg('one')]);
        await _settle();
        await dir.delete(recursive: true);
        rooms.dispose();
        await _settle();
        expect(dir.existsSync(), isFalse);
      });

      test('an unreadable file counts afresh', () async {
        final (client, dir, files) = await launch();
        await File('${dir.path}${Platform.pathSeparator}unread.json')
            .writeAsString('{ torn');
        await _bakery(client);
        final rooms = MatrixRooms(client, mediaRoot: files);
        addTearDown(rooms.dispose);
        await _settle();
        expect(channel(rooms, general).unread, 0);
      });
    });

    test('your own message reads everything before it', () async {
      final (client, rooms) = await bakery();
      await _timeline(client, general, [_msg('one'), _msg('two')]);
      await _timeline(client, general, [_msg('mine', sender: _me)]);
      await _settle();
      expect(channel(rooms, general).unread, 0);
    });

    test('a message deleted while unread stops counting', () async {
      final (client, rooms) = await bakery();
      await _timeline(client, general, [_msg('oops', id: r'$oops')]);
      await _timeline(client, general, [
        {
          'type': 'm.room.redaction',
          'sender': '@ada:example.com',
          'redacts': r'$oops',
          'content': {'redacts': r'$oops'},
          'event_id': '\$r${_events++}',
          'origin_server_ts': 1700000000000 + _events++ * 1000,
        },
      ]);
      await _settle();
      expect(channel(rooms, general).unread, 0);
    });

    test('edits and reactions do not count', () async {
      final (client, rooms) = await bakery();
      await _timeline(client, general, [
        {
          'type': 'm.reaction',
          'sender': '@ada:example.com',
          'content': {
            'm.relates_to': {
              'rel_type': 'm.annotation',
              'event_id': r'$x',
              'key': '👍',
            },
          },
          'event_id': '\$x${_events++}',
          'origin_server_ts': 1700000000000 + _events++ * 1000,
        },
      ]);
      await _settle();
      expect(channel(rooms, general).unread, 0);
    });

    test('leaving a room forgets its count', () async {
      final (client, rooms) = await bakery();
      await _timeline(client, general, [_msg('one')]);
      await _sync(client, {
        'leave': {general: <String, Object?>{}},
      });
      await _settle();
      expect(rooms.unreadTally(general).isEmpty, isTrue);
    });

    test('mark as read is sent while something is unread', () async {
      final api = _Api();
      final client = await _client(api: api);
      final rooms = await _rooms(client);
      await _bakery(client);
      await _timeline(client, general, [_msg('one')]);
      await _settle();
      rooms.markRead(general);
      await _settle();
      expect(api.answered.where((p) => p.contains('read_markers')), isNotEmpty);
    });

    test('a limited sync refetches the room from the server', () async {
      final api = _Api();
      final client = await _client(api: api);
      final rooms = await _rooms(client);
      await _bakery(client);
      api.roomHistory[general] = [
        _msg('newest'),
        _msg('newer'),
        _msg('read one', id: r'$read'),
        _msg('older'),
      ];
      await _timeline(
        client,
        general,
        const [],
        ephemeral: [_receipt(r'$read', ts: 0)],
      );
      await _timeline(client, general, [
        api.roomHistory[general]!.first,
      ], limited: true);
      await _settle();
      expect(channel(rooms, general).unread, 2);
    });

    test('history past 99 unread reads as more than 99', () async {
      final api = _Api();
      final client = await _client(api: api);
      final rooms = await _rooms(client);
      await _bakery(client);
      api.roomHistory[general] = [for (var i = 0; i < 150; i++) _msg('m$i')];
      await _timeline(client, general, [
        api.roomHistory[general]!.first,
      ], limited: true);
      await _settle();
      expect(channel(rooms, general).unread, RoomTally.cap + 1);
    });

    test('a failed fill keeps the count and tries again next sync', () async {
      final api = _Api()..failHistory = true;
      final client = await _client(api: api);
      final rooms = await _rooms(client);
      await _bakery(client);
      await _timeline(client, general, [_msg('before')]);
      api.roomHistory[general] = [_msg('a'), _msg('b'), _msg('c')];
      await _timeline(client, general, [
        api.roomHistory[general]!.first,
      ], limited: true);
      await _settle();
      expect(channel(rooms, general).unread, 1, reason: 'the old count stays');

      api.failHistory = false;
      await _timeline(client, general, const []);
      await _settle();
      expect(channel(rooms, general).unread, 3);
    });

    test('messages that arrive during a fill are kept', () async {
      final api = _Api()..hold = Completer<void>();
      final client = await _client(api: api);
      final rooms = await _rooms(client);
      await _bakery(client);
      api.roomHistory[general] = [_msg('a', ts: 1000), _msg('b', ts: 900)];
      await _timeline(client, general, [
        api.roomHistory[general]!.first,
      ], limited: true);
      await _settle();
      await _timeline(client, general, [_msg('during', ts: 2000)]);
      await _settle();
      api.hold!.complete();
      await _settle();
      expect(channel(rooms, general).unread, 3);
    });

    test('a gap that arrives during a fill is filled again', () async {
      final api = _Api()..hold = Completer<void>();
      final client = await _client(api: api);
      final rooms = await _rooms(client);
      await _bakery(client);
      api.roomHistory[general] = [_msg('a', ts: 1000)];
      await _timeline(client, general, [
        api.roomHistory[general]!.first,
      ], limited: true);
      await _settle();
      final fresh = _msg('fresh', ts: 3000);
      await _timeline(client, general, [fresh], limited: true);
      await _settle();
      api.roomHistory[general] = [fresh, ...api.roomHistory[general]!];
      api.hold!.complete();
      await _settle();
      expect(channel(rooms, general).unread, 2);
    });

    test('a plain sync during a fill does not start another', () async {
      final api = _Api()..hold = Completer<void>();
      final client = await _client(api: api);
      final rooms = await _rooms(client);
      await _bakery(client);
      api.roomHistory[general] = [_msg('a', ts: 1000)];
      await _timeline(client, general, [
        api.roomHistory[general]!.first,
      ], limited: true);
      await _settle();
      await _timeline(client, general, [_msg('during', ts: 2000)]);
      await _timeline(client, general, const []);
      await _settle();
      api.hold!.complete();
      await _settle();
      expect(api.historyCalls[general], 1);
      expect(channel(rooms, general).unread, 2);
    });

    test('history from before you joined does not count', () async {
      final (client, rooms) = await bakery();
      await _timeline(client, general, [_msg('before you came'), _join()]);
      await _settle();
      expect(channel(rooms, general).unread, 0);
    });

    test('a profile change is not a join', () async {
      final (client, rooms) = await bakery();
      await _timeline(client, general, [
        _msg('one'),
        _join(profileChange: true),
      ]);
      await _settle();
      expect(channel(rooms, general).unread, 1);
    });

    test('a fill stops at your join', () async {
      final api = _Api();
      final client = await _client(api: api);
      final rooms = await _rooms(client);
      await _bakery(client);
      api.roomHistory[general] = [
        _msg('new', ts: 3000),
        _join(ts: 2000),
        _msg('old', ts: 1000),
        _msg('older', ts: 900),
      ];
      await _timeline(client, general, [
        api.roomHistory[general]!.first,
      ], limited: true);
      await _settle();
      expect(channel(rooms, general).unread, 1);
    });

    test('leaving during a fill leaves no tally behind', () async {
      final api = _Api()..hold = Completer<void>();
      final client = await _client(api: api);
      final rooms = await _rooms(client);
      await _bakery(client);
      api.roomHistory[general] = [_msg('a'), _msg('b')];
      await _timeline(client, general, [
        api.roomHistory[general]!.first,
      ], limited: true);
      await _settle();
      await _sync(client, {
        'leave': {general: <String, Object?>{}},
      });
      await _settle();
      api.hold!.complete();
      await _settle();
      expect(rooms.unreadTally(general).isEmpty, isTrue);
    });

    test('your own message during a fill still reads the room', () async {
      final api = _Api()..hold = Completer<void>();
      final client = await _client(api: api);
      final rooms = await _rooms(client);
      await _bakery(client);
      api.roomHistory[general] = [_msg('a', ts: 1000), _msg('b', ts: 900)];
      await _timeline(client, general, [
        api.roomHistory[general]!.first,
      ], limited: true);
      await _settle();
      final mine = _msg('mine', sender: _me, ts: 3000);
      await _timeline(client, general, [mine]);
      await _settle();
      api.roomHistory[general] = [mine, ...api.roomHistory[general]!];
      api.hold!.complete();
      await _settle();
      expect(channel(rooms, general).unread, 0);
    });

    test('a main-timeline receipt on the last message seeds no fill', () async {
      final api = _Api();
      final client = await _client(api: api);
      await _bakery(client);
      await _timeline(
        client,
        general,
        [_msg('waiting', id: r'$waiting')],
        ephemeral: [_receipt(r'$waiting', ts: 0, thread: 'main')],
      );
      final rooms = await _rooms(client);
      await _settle();
      expect(channel(rooms, general).unread, 0);
      expect(api.historyCalls[general], isNull);
    });

    test('until a room is counted, the server\'s numbers stand in', () async {
      final api = _Api()..hold = Completer<void>();
      final client = await _client(api: api);
      await _bakery(client);
      await _timeline(client, general, [_msg('waiting')]);
      api.roomHistory[general] = [_msg('waiting'), _msg('earlier')];
      final rooms = await _rooms(client);
      // _bakery gives #general a notification_count of 3; the fill is out.
      expect(channel(rooms, general).unread, 3);
      api.hold!.complete();
      await _settle();
      expect(channel(rooms, general).unread, 2);
    });

    test(
      'rooms that synced before the counts existed are filled once',
      () async {
        final api = _Api();
        final client = await _client(api: api);
        await _bakery(client);
        // A message from someone else is the newest event: hasNewMessages.
        await _timeline(client, general, [_msg('waiting')]);
        api.roomHistory[general] = [_msg('waiting'), _msg('earlier')];
        final rooms = await _rooms(client);
        await _settle();
        expect(channel(rooms, general).unread, 2);
        expect(api.historyCalls[general], 1);
        expect(
          api.historyCalls['!sourdough:example.com'],
          isNull,
          reason: 'a room with nothing new is not fetched',
        );
      },
    );
  });

  test('rooms in no space land in Home, a DM as a DM', () async {
    final rooms = await _rooms(await _client());
    expect(rooms.synced, isTrue);
    expect(rooms.spaces, isEmpty);
    final byId = {for (final c in rooms.homeRooms) c.id: c};
    // The fake's m.direct lists this one.
    final dm = byId['!726s6s6q:example.com']!;
    expect(dm.kind, ChannelKind.direct);
    expect(dm.members, isNotEmpty);
    expect(dm.members.map((m) => m.id), isNot(contains(_me)));
    expect(byId['!calls:example.com']!.kind, ChannelKind.room);
  });

  test('joined spaces make the rail, in name order', () async {
    final client = await _client();
    final rooms = await _rooms(client);
    await _bakery(client);
    await _settle();
    // Subspaces are categories, never rail items.
    expect(rooms.spaces.map((s) => s.name), ['annex', 'Bakery']);
  });

  test('a space\'s children become its categories and channels', () async {
    final client = await _client();
    final rooms = await _rooms(client);
    await _bakery(client);
    await _settle();

    final bakery = rooms.spaces.last;
    // Direct children first, uncategorised; then one category per subspace,
    // its nested subspace flattened in. The unjoined child is not listed.
    expect(bakery.categories.map((c) => c.name), ['', 'recipes']);
    expect(bakery.categories.first.channels.map((c) => c.name), [
      'general',
      'oven',
    ]);
    expect(bakery.categories.last.channels.map((c) => c.name), [
      'sourdough',
      'crumb',
    ]);
    expect(bakery.categories.first.channels.last.kind, ChannelKind.voice);
    expect(bakery.categories.first.channels.first.kind, ChannelKind.text);
  });

  test(
    'a room listed twice in one category\'s tree appears there once',
    () async {
      final client = await _client();
      final rooms = await _rooms(client);
      await _sync(client, {
        'join': {
          '!mill:example.com': _room(
            'Mill',
            type: 'm.space',
            extra: [_child('!grain:example.com')],
          ),
          '!grain:example.com': _room(
            'grain',
            type: 'm.space',
            extra: [_child('!flour:example.com'), _child('!rye:example.com')],
          ),
          '!rye:example.com': _room(
            'rye',
            type: 'm.space',
            extra: [_child('!flour:example.com')],
          ),
          '!flour:example.com': _room('flour'),
        },
      });
      await _settle();
      final mill = rooms.spaces.single;
      expect(mill.categories.single.channels.map((c) => c.id), [
        '!flour:example.com',
      ]);
    },
  );

  test('a channel carries its topic and lock', () async {
    final client = await _client();
    final rooms = await _rooms(client);
    await _bakery(client);
    await _settle();

    final sourdough = rooms.spaces.last.categories.last.channels.first;
    expect(sourdough.private, isTrue);
    expect(sourdough.topic, 'wild yeast');
    expect(sourdough.muted, isFalse);
  });

  test('a space\'s rooms never also appear in Home', () async {
    final client = await _client();
    final rooms = await _rooms(client);
    await _bakery(client);
    await _settle();
    final home = rooms.homeRooms.map((c) => c.id).toSet();
    for (final id in [
      '!general:example.com',
      '!crumb:example.com',
      '!recipes:example.com',
      '!bakery:example.com',
    ]) {
      expect(home, isNot(contains(id)), reason: id);
    }
  });

  test('members carry their power level, and no presence yet', () async {
    final client = await _client();
    final rooms = await _rooms(client);
    await _bakery(client);
    await _settle();
    // Only a room list's state is in memory until a member list is wanted.
    rooms.loadMembers('!bakery:example.com');
    await _settle();
    final members = {for (final m in rooms.spaces.last.members) m.id: m};
    expect(members[_me]!.role, Role.admin);
    expect(members['@mod:example.com']!.role, Role.moderator);
    expect(members['@mod:example.com']!.name, 'Moddy');
    expect(members['@mod:example.com']!.presence, loaf.Presence.unknown);
  });

  test('a member list is asked for once, however often it is wanted', () async {
    final client = await _client();
    final rooms = await _rooms(client);
    await _bakery(client);
    await _settle();
    for (var i = 0; i < 3; i++) {
      rooms.loadMembers('!bakery:example.com');
      await _settle();
    }
    expect(
      FakeMatrixApi.calledEndpoints.keys.where((k) => k.contains('/members')),
      hasLength(1),
    );
    expect(
      FakeMatrixApi.calledEndpoints.entries
          .where((e) => e.key.contains('/members'))
          .single
          .value,
      hasLength(1),
    );
  });

  test('tags and a mentions-only push rule reach Home rooms', () async {
    final client = await _client();
    final rooms = await _rooms(client);
    await _sync(client, {
      'join': {
        '!fav:example.com': _room(
          'fav',
          accountData: [
            {
              'type': 'm.tag',
              'content': {
                'tags': {
                  'm.favourite': {'order': 0.25},
                },
              },
            },
          ],
        ),
        '!low:example.com': _room(
          'low',
          accountData: [
            {
              'type': 'm.tag',
              'content': {
                'tags': {'m.lowpriority': <String, Object?>{}},
              },
            },
          ],
        ),
      },
    });
    await client.handleSync(
      SyncUpdate.fromJson({
        'next_batch': 'rules',
        'account_data': {
          'events': [
            {
              'type': 'm.push_rules',
              'content': {
                'global': {
                  'room': [
                    {
                      'rule_id': '!low:example.com',
                      'actions': <Object>[],
                      'default': false,
                      'enabled': true,
                    },
                  ],
                },
              },
            },
          ],
        },
      }),
    );
    await _settle();
    final byId = {for (final c in rooms.homeRooms) c.id: c};
    expect(byId['!fav:example.com']!.favourite, isTrue);
    expect(byId['!fav:example.com']!.favouriteOrder, 0.25);
    expect(byId['!low:example.com']!.lowPriority, isTrue);
    expect(byId['!low:example.com']!.muted, isTrue);
    expect(byId['!fav:example.com']!.muted, isFalse);
  });

  test('two DMs with one person name the same person, so they fold', () async {
    final client = await _client();
    final rooms = await _rooms(client);
    Map<String, Object?> dm(String name, List<String> heroes) => {
      ..._room(name),
      'summary': {'m.heroes': heroes, 'm.joined_member_count': 2},
    };
    await client.handleSync(
      SyncUpdate.fromJson({
        'next_batch': 'dms',
        'account_data': {
          'events': [
            {
              'type': 'm.direct',
              'content': {
                '@sam:x.y': ['!sam1:x.y', '!sam2:x.y'],
                '@jun:x.y': ['!group:x.y'],
              },
            },
          ],
        },
        'rooms': {
          'join': {
            '!sam1:x.y': dm('Sam', ['@sam:x.y']),
            // No heroes: m.direct still says who it is with.
            '!sam2:x.y': dm('Sam', []),
            '!group:x.y': dm('crew', ['@jun:x.y', '@ada:x.y']),
          },
        },
      }),
    );
    await _settle();
    final byId = {for (final c in rooms.homeRooms) c.id: c};
    expect(byId['!sam1:x.y']!.members.single.id, '@sam:x.y');
    expect(byId['!sam2:x.y']!.members.single.id, '@sam:x.y');
    expect(byId['!group:x.y']!.members.map((m) => m.id), [
      '@jun:x.y',
      '@ada:x.y',
    ]);
    expect(byId['!group:x.y']!.kind, ChannelKind.direct);
  });

  test('an invite says who sent it and what it is', () async {
    final client = await _client();
    final rooms = await _rooms(client);
    await _invited(client);
    await _settle();
    final invite = rooms.invites.firstWhere(
      (i) => i.id == '!invited:example.com',
    );
    expect(invite.kind, InviteKind.room);
    expect(invite.name, 'Proofing');
    expect(invite.topic, 'rise');
    expect(invite.inviter.id, '@al:x.y');
    expect(invite.inviter.name, 'Al');
    expect(invite.room!.id, '!invited:example.com');
  });

  test('a DM invite is a DM invite', () async {
    final client = await _client();
    final rooms = await _rooms(client);
    await _invited(client, direct: true);
    await _settle();
    final invite = rooms.invites.firstWhere(
      (i) => i.id == '!invited:example.com',
    );
    expect(invite.kind, InviteKind.direct);
    expect(invite.room!.kind, ChannelKind.direct);
  });

  test('after a relaunch, an invite still knows who sent it and that it is '
      'a DM', () async {
    final dir = await Directory.systemTemp.createTemp('loaf_relaunch');
    // Rooms disposed in teardown write the file once more; let it land.
    addTearDown(() async {
      await _settle();
      await dir.delete(recursive: true);
    });
    final path = '${dir.path}/loaf.sqlite';

    final first = await openClient(
      httpClient: FakeMatrixApi(),
      databasePath: path,
    );
    FakeMatrixApi.client = first;
    await first.init(
      newToken: 'abcd',
      newHomeserver: Uri.parse('https://fakeServer.notExisting'),
      newUserID: _me,
      newDeviceID: 'GHTYAJCE',
      newDeviceName: 'loaf on test',
    );
    await _invited(first, direct: true);
    await first.dispose(closeDatabase: true);

    // The app opens again: everything comes back from the database.
    final client = await openClient(
      httpClient: FakeMatrixApi(),
      databasePath: path,
    );
    FakeMatrixApi.client = client;
    await client.init(waitForFirstSync: false);
    addTearDown(() => client.dispose(closeDatabase: true));
    final rooms = await _rooms(client);

    final invite = rooms.invites.firstWhere(
      (i) => i.id == '!invited:example.com',
    );
    expect(invite.kind, InviteKind.direct);
    expect(invite.inviter.id, '@al:x.y');
    expect(invite.inviter.name, 'Al');
    // So accepting files it under m.direct.
    expect(
      client.getRoomById('!invited:example.com')!.directChatMatrixID,
      '@al:x.y',
    );
  });

  test('before the first sync: waiting, then progress, then synced', () async {
    final client = await _client(firstSync: false);
    final rooms = MatrixRooms(client);
    addTearDown(rooms.dispose);
    expect(rooms.synced, isFalse);
    expect(rooms.syncProgress, isNull);
    final seen = <(bool, double?)>[];
    rooms.addListener(() => seen.add((rooms.synced, rooms.syncProgress)));
    await client.onSync.stream.first;
    await _settle();
    expect(rooms.synced, isTrue);
    expect(rooms.syncProgress, isNull);
    expect(
      seen.where((s) => s.$2 != null).map((s) => s.$1),
      everyElement(false),
    );
    expect(seen.map((s) => s.$2), contains(1.0));
  });

  test(
    'a sync already under way when the rooms open shows its progress',
    () async {
      final client = await _client(firstSync: false);
      client.onSyncStatus.add(
        const SyncStatusUpdate(SyncStatus.processing, progress: 0.3),
      );
      final rooms = MatrixRooms(client);
      addTearDown(rooms.dispose);
      expect(rooms.synced, isFalse);
      expect(rooms.syncProgress, 0.3);
    },
  );

  test('accepting an invite asks the server once, however many taps', () async {
    final api = _Api()..hold = Completer();
    final client = await _client(api: api);
    final rooms = await _rooms(client);
    await _invited(client);
    await _settle();
    final invite = rooms.invites.firstWhere(
      (i) => i.id == '!invited:example.com',
    );
    final first = rooms.accept(invite);
    final second = rooms.accept(invite);
    api.hold!.complete();
    await Future.wait([first, second]);
    expect(api.answered.where((p) => p.endsWith('/join')), hasLength(1));
  });

  test('declining an invite leaves it', () async {
    final api = _Api();
    final client = await _client(api: api);
    final rooms = await _rooms(client);
    await _invited(client);
    await _settle();
    await rooms.decline(
      rooms.invites.firstWhere((i) => i.id == '!invited:example.com'),
    );
    expect(api.answered.single, endsWith('/leave'));
  });

  test('a refused accept throws, and the invite stays', () async {
    final api = _Api()..refuse = true;
    final client = await _client(api: api);
    final rooms = await _rooms(client);
    await _invited(client);
    await _settle();
    final invite = rooms.invites.firstWhere(
      (i) => i.id == '!invited:example.com',
    );
    await expectLater(rooms.accept(invite), throwsA(isA<MatrixException>()));
    await _settle();
    expect(rooms.invites.map((i) => i.id), contains('!invited:example.com'));
    // And it can be tried again.
    api.refuse = false;
    await rooms.accept(invite);
    expect(api.answered.where((p) => p.endsWith('/join')), hasLength(2));
  });

  test('an answered invite is gone before the sync that confirms it, and '
      'answers nothing more', () async {
    final api = _Api();
    final client = await _client(api: api);
    final rooms = await _rooms(client);
    await _invited(client);
    await _settle();
    final invite = rooms.invites.firstWhere(
      (i) => i.id == '!invited:example.com',
    );
    await rooms.accept(invite);
    // The server said yes; the sync saying so has not arrived.
    expect(
      client.getRoomById('!invited:example.com')!.membership,
      Membership.invite,
    );
    expect(rooms.invites.map((i) => i.id), isNot(contains(invite.id)));
    // A stale preview's buttons: no second join, and no leave of the room
    // just joined.
    await rooms.accept(invite);
    await rooms.decline(invite);
    expect(api.answered, hasLength(1));
    expect(api.answered.single, endsWith('/join'));
  });

  test('a blank display name is no name: the localpart stands in', () async {
    final rooms = await _rooms(await _client(api: _Api()..profileName = '  '));
    expect(rooms.me.name, 'test');
  });

  test('you are you, and the wired abilities show', () async {
    final rooms = await _rooms(await _client());
    expect(rooms.me.id, _me);
    expect(rooms.me.name, isNotEmpty);
    expect(rooms.abilities, {
      RoomAbility.editProfile,
      RoomAbility.answerInvites,
      RoomAbility.messages,
      RoomAbility.markRead,
      RoomAbility.mute,
      RoomAbility.tag,
      RoomAbility.join,
      RoomAbility.leave,
      RoomAbility.addSpace,
      RoomAbility.startDirect,
      RoomAbility.invite,
      RoomAbility.devices,
    });
  });

  group('toggles', () {
    Channel byId(MatrixRooms rooms, String id) =>
        {for (final c in rooms.homeRooms) c.id: c}[id]!;

    Map<String, Object?> tag(String name, {required double order}) => {
      'type': 'm.tag',
      'content': {
        'tags': {
          name: {'order': order},
        },
      },
    };

    test('muting shows at once and sends the push rule', () async {
      final api = _Api();
      final client = await _client(api: api);
      final rooms = await _rooms(client);
      await _sync(client, {
        'join': {'!m:example.com': _room('mute me')},
      });
      await _settle();

      final result = rooms.setMuted('!m:example.com', true);
      expect(byId(rooms, '!m:example.com').muted, isTrue);
      await result;
      await _settle();

      expect(byId(rooms, '!m:example.com').muted, isTrue);
      expect(api.answered.where((p) => p.contains('/pushrules/')), isNotEmpty);
    });

    test('a refused mute snaps back and throws', () async {
      final api = _Api()..refuse = true;
      final client = await _client(api: api);
      final rooms = await _rooms(client);
      await _sync(client, {
        'join': {'!m:example.com': _room('mute me')},
      });
      await _settle();

      await expectLater(
        rooms.setMuted('!m:example.com', true),
        throwsA(isA<MatrixException>()),
      );
      await _settle();
      expect(byId(rooms, '!m:example.com').muted, isFalse);
    });

    test('a refused call only rolls back its own wish', () async {
      final api = _Api()..hold = Completer();
      final client = await _client(api: api);
      final rooms = await _rooms(client);
      await _sync(client, {
        'join': {'!m:example.com': _room('mute me')},
      });
      await _settle();

      final first = rooms.setMuted('!m:example.com', true);
      await _settle();
      // The room's real state is still unmuted, so muting off again settles
      // at once: no push rule needs to change.
      final second = rooms.setMuted('!m:example.com', false);
      await _settle();
      expect(byId(rooms, '!m:example.com').muted, isFalse);

      api.refuse = true;
      api.hold!.complete();
      await expectLater(first, throwsA(isA<MatrixException>()));
      await second;
      await _settle();

      // The older refusal does not undo the newer wish.
      expect(byId(rooms, '!m:example.com').muted, isFalse);
    });

    test('favouriting a low-priority room clears low priority', () async {
      final api = _Api();
      final client = await _client(api: api);
      final rooms = await _rooms(client);
      await _sync(client, {
        'join': {
          '!low:example.com': _room(
            'low',
            accountData: [
              {
                'type': 'm.tag',
                'content': {
                  'tags': {'m.lowpriority': <String, Object?>{}},
                },
              },
            ],
          ),
        },
      });
      await _settle();
      expect(byId(rooms, '!low:example.com').lowPriority, isTrue);

      final result = rooms.setFavourite('!low:example.com', true);
      expect(byId(rooms, '!low:example.com').favourite, isTrue);
      expect(byId(rooms, '!low:example.com').lowPriority, isFalse);
      await result;
      await _settle();

      final channel = byId(rooms, '!low:example.com');
      expect(channel.favourite, isTrue);
      expect(channel.lowPriority, isFalse);
      expect(
        api.answered.where((p) => p.contains('/tags/m.favourite')),
        isNotEmpty,
      );
      expect(
        api.answered.where((p) => p.contains('/tags/m.lowpriority')),
        isNotEmpty,
      );
    });

    test('reordering sends only the rooms that moved', () async {
      final api = _Api();
      final client = await _client(api: api);
      final rooms = await _rooms(client);
      await _sync(client, {
        'join': {
          '!a:example.com': _room(
            'a',
            accountData: [tag('m.favourite', order: 0.25)],
          ),
          '!b:example.com': _room(
            'b',
            accountData: [tag('m.favourite', order: 0.5)],
          ),
          '!c:example.com': _room(
            'c',
            accountData: [tag('m.favourite', order: 0.75)],
          ),
        },
      });
      await _settle();

      // a stays first; b and c swap.
      await rooms.reorderFavourites([
        '!a:example.com',
        '!c:example.com',
        '!b:example.com',
      ]);
      await _settle();

      final favTags = api.answered
          .where((p) => p.contains('/tags/m.favourite'))
          .toList();
      expect(favTags, hasLength(2));
      expect(favTags.any((p) => p.contains('!a%3A')), isFalse);
      expect(byId(rooms, '!b:example.com').favouriteOrder, 0.75);
      expect(byId(rooms, '!c:example.com').favouriteOrder, 0.5);
    });

    test(
      'leaving hides the row at once, and a refusal brings it back',
      () async {
        final api = _Api()..refuse = true;
        final client = await _client(api: api);
        final rooms = await _rooms(client);
        await _sync(client, {
          'join': {'!l:example.com': _room('leave me')},
        });
        await _settle();
        expect(rooms.homeRooms.map((c) => c.id), contains('!l:example.com'));

        final result = rooms.setJoined('!l:example.com', false);
        expect(
          rooms.homeRooms.map((c) => c.id),
          isNot(contains('!l:example.com')),
        );
        await expectLater(result, throwsA(isA<MatrixException>()));
        await _settle();

        expect(rooms.homeRooms.map((c) => c.id), contains('!l:example.com'));
      },
    );

    test('a wish clears when sync agrees', () async {
      final api = _Api();
      final client = await _client(api: api);
      final rooms = await _rooms(client);
      await _sync(client, {
        'join': {'!m:example.com': _room('mute me')},
      });
      await _settle();

      await rooms.setMuted('!m:example.com', true);
      await _settle();
      expect(byId(rooms, '!m:example.com').muted, isTrue);

      // The server agrees: the wish is gone, so a later change from another
      // device is drawn straight through.
      await client.handleSync(
        SyncUpdate.fromJson({
          'next_batch': 'agree',
          'account_data': {
            'events': [
              {
                'type': 'm.push_rules',
                'content': {
                  'global': {
                    'override': [
                      {
                        'rule_id': '!m:example.com',
                        'actions': <Object>[],
                        'default': false,
                        'enabled': true,
                      },
                    ],
                  },
                },
              },
            ],
          },
        }),
      );
      await _settle();
      expect(byId(rooms, '!m:example.com').muted, isTrue);

      await client.handleSync(
        SyncUpdate.fromJson({
          'next_batch': 'other-device',
          'account_data': {
            'events': [
              {
                'type': 'm.push_rules',
                'content': {
                  'global': {'override': <Object>[]},
                },
              },
            ],
          },
        }),
      );
      await _settle();
      expect(byId(rooms, '!m:example.com').muted, isFalse);
    });

    test(
      'joining an unjoined hierarchy child shows it joined at once',
      () async {
        final api = _Api()..hold = Completer();
        final client = await _client(api: api);
        final rooms = await _rooms(client);
        api.hierarchyPages['!bakery:example.com'] = [
          {
            'rooms': [
              {
                'room_id': '!unjoined:example.com',
                'guest_can_join': false,
                'world_readable': true,
                'num_joined_members': 1,
                'name': 'proofing',
                'join_rule': 'public',
                'children_state': <Object?>[],
              },
            ],
          },
        ];
        await _sync(client, {
          'join': {
            '!bakery:example.com': _room(
              'Bakery',
              type: 'm.space',
              extra: [_child('!unjoined:example.com')],
            ),
          },
        });
        await _settle();
        Channel unjoined() => rooms.spaces
            .firstWhere((s) => s.id == '!bakery:example.com')
            .categories
            .first
            .channels
            .singleWhere((c) => c.id == '!unjoined:example.com');
        expect(unjoined().joined, isFalse);

        final result = rooms.setJoined('!unjoined:example.com', true);
        expect(unjoined().joined, isTrue);
        api.hold!.complete();
        await result;
        await _settle();
      },
    );
  });

  group('people', () {
    const bob = Member('@bob:example.com', 'Bob', Colors.blue);
    const carol = Member('@carol:example.com', 'Carol', Colors.blue);
    const dave = Member('@dave:example.com', 'Dave', Colors.blue);
    const erin = Member('@erin:example.com', 'Erin', Colors.blue);

    /// A joined DM room with Carol (joined) and Dave (invited) in it.
    Future<void> group(Client client) => _sync(client, {
      'join': {
        '!group:example.com': {
          ..._room(
            'carol, dave',
            extra: [
              _state(
                'm.room.member',
                {'membership': 'join', 'displayname': 'Carol'},
                key: '@carol:example.com',
                sender: '@carol:example.com',
              ),
              _state('m.room.member', {
                'membership': 'invite',
                'displayname': 'Dave',
              }, key: '@dave:example.com'),
            ],
          ),
          // The server's own summary of who a small room is with, joined
          // or invited: what a group DM is matched by, without needing the
          // full member list loaded.
          'summary': {
            'm.heroes': ['@carol:example.com', '@dave:example.com'],
          },
        },
      },
    });

    /// Marks a room a direct chat the way `m.direct` account data does.
    Future<void> direct(Client client, String roomId, {String? owner}) =>
        client.handleSync(
          SyncUpdate.fromJson({
            'next_batch': 'direct-${_events++}',
            'account_data': {
              'events': [
                {
                  'type': 'm.direct',
                  'content': {
                    (owner ?? '@carol:example.com'): [roomId],
                  },
                },
              ],
            },
          }),
        );

    test('a DM with someone you already talk to opens that DM', () async {
      final api = _Api();
      final client = await _client(api: api);
      final rooms = await _rooms(client);

      final channel = await rooms.createDirect([bob]);

      expect(channel.id, '!726s6s6q:example.com');
      expect(api.answered.where((p) => p.endsWith('/createRoom')), isEmpty);
      expect(rooms.homeRooms.map((c) => c.id), contains(channel.id));
    });

    test('a group DM with exactly those people is reused', () async {
      final api = _Api();
      final client = await _client(api: api);
      final rooms = await _rooms(client);
      await group(client);
      await direct(client, '!group:example.com');
      await _settle();

      final channel = await rooms.createDirect([carol, dave]);

      expect(channel.id, '!group:example.com');
      expect(api.answered.where((p) => p.endsWith('/createRoom')), isEmpty);
    });

    test('a group DM with different people is new', () async {
      final api = _Api();
      final client = await _client(api: api);
      final rooms = await _rooms(client);
      await group(client);
      await direct(client, '!group:example.com');
      await _settle();

      final channel = await rooms.createDirect([carol, erin]);

      expect(
        api.answered.where((p) => p.endsWith('/createRoom')),
        hasLength(1),
      );
      expect(channel.id, isNot('!group:example.com'));
      expect(rooms.homeRooms.map((c) => c.id), contains(channel.id));
      expect(
        rooms.homeRooms.firstWhere((c) => c.id == channel.id).kind,
        ChannelKind.direct,
      );
    });

    test('an invite names who did not go through', () async {
      final api = _Api()..refuseInviteIds.add('@erin:example.com');
      final client = await _client(api: api);
      final rooms = await _rooms(client);
      await _bakery(client);
      await _settle();

      await expectLater(
        rooms.invite('!general:example.com', [
          '@carol:example.com',
          '@erin:example.com',
        ]),
        throwsA(
          isA<InviteRefused>().having((e) => e.failed.keys, 'failed', [
            '@erin:example.com',
          ]),
        ),
      );
    });
  });

  group('a failing invite or hierarchy', () {
    test('an error that is not the server\'s fails only that id', () async {
      final api = _Api()..brokenInviteIds.add('@erin:example.com');
      final client = await _client(api: api);
      final rooms = await _rooms(client);
      await _bakery(client);
      await _settle();

      await expectLater(
        rooms.invite('!general:example.com', [
          '@erin:example.com',
          '@carol:example.com',
        ]),
        throwsA(
          isA<InviteRefused>().having((e) => e.failed.keys, 'failed', [
            '@erin:example.com',
          ]),
        ),
      );
      expect(
        api.answered.where((p) => p.endsWith('/invite')),
        hasLength(2),
        reason: 'carol was still invited after erin failed',
      );
    });

    test('joining a space survives its hierarchy failing', () async {
      final api = _Api()..failHierarchy = true;
      final client = await _client(api: api);
      final rooms = await _rooms(client);

      await rooms.joinSpace(
        Space(id: '!newspace:example.com', name: 'New', color: Colors.blue),
      );
      await _settle();

      expect(
        api.answered.where((p) => p.contains('/join/')),
        hasLength(1),
        reason: 'the space joined; no children did',
      );
    });
  });

  group('spaces', () {
    /// An `m.space.child` state event, for a `/hierarchy` chunk's
    /// `children_state`.
    Map<String, Object?> childState(
      String id, {
      List<String> via = const ['example.com'],
      bool? suggested,
    }) => {
      'type': 'm.space.child',
      'state_key': id,
      'sender': _me,
      'content': {'via': via, 'suggested': ?suggested},
      'origin_server_ts': 1700000000000,
    };

    /// A `/hierarchy` chunk, as returned for a space or one of its children.
    Map<String, Object?> hierarchyChunk(
      String id, {
      String? name,
      String? roomType,
      String joinRule = 'public',
      List<Map<String, Object?>> children = const [],
    }) => {
      'room_id': id,
      'guest_can_join': false,
      'world_readable': true,
      'num_joined_members': 1,
      'name': ?name,
      'join_rule': joinRule,
      'room_type': ?roomType,
      'children_state': children,
    };

    /// Room ids left, in call order, decoded from `/leave` paths.
    List<String> leftIds(_Api api) => [
      for (final p in api.answered.where((p) => p.endsWith('/leave')))
        Uri.decodeComponent(p.split('/rooms/')[1].split('/leave')[0]),
    ];

    /// Room ids joined, in call order, decoded from `/join/` paths.
    List<String> joinedIds(_Api api) => [
      for (final p in api.answered.where((p) => p.contains('/join/')))
        Uri.decodeComponent(p.split('/join/')[1]),
    ];

    test(
      'joining a space joins its subspaces and suggested channels',
      () async {
        final api = _Api();
        final client = await _client(api: api);
        final rooms = await _rooms(client);
        api.hierarchyPages['!newspace:example.com'] = [
          {
            'rooms': [
              hierarchyChunk(
                '!newspace:example.com',
                name: 'New',
                children: [
                  childState('!sub:example.com'),
                  childState('!suggested:example.com', suggested: true),
                  childState('!plain:example.com'),
                ],
              ),
              hierarchyChunk(
                '!sub:example.com',
                name: 'Sub',
                roomType: 'm.space',
              ),
              hierarchyChunk('!suggested:example.com', name: 'Suggested'),
              hierarchyChunk('!plain:example.com', name: 'Plain'),
            ],
          },
        ];

        await rooms.joinSpace(
          Space(id: '!newspace:example.com', name: 'New', color: Colors.blue),
        );
        await _settle();

        final joined = joinedIds(api);
        expect(joined, contains('!newspace:example.com'));
        expect(joined, contains('!sub:example.com'));
        expect(joined, contains('!suggested:example.com'));
        expect(joined, isNot(contains('!plain:example.com')));
      },
    );

    test('a refused suggested channel is skipped, not thrown', () async {
      final api = _Api()..refuseIds.add('!suggested:example.com');
      final client = await _client(api: api);
      final rooms = await _rooms(client);
      api.hierarchyPages['!newspace:example.com'] = [
        {
          'rooms': [
            hierarchyChunk(
              '!newspace:example.com',
              name: 'New',
              children: [childState('!suggested:example.com', suggested: true)],
            ),
            hierarchyChunk('!suggested:example.com', name: 'Suggested'),
          ],
        },
      ];

      await rooms.joinSpace(
        Space(id: '!newspace:example.com', name: 'New', color: Colors.blue),
      );
      await _settle();

      expect(joinedIds(api), contains('!suggested:example.com'));
      expect(joinedIds(api), contains('!newspace:example.com'));
    });

    test(
      'leaving a space leaves its rooms deepest first, then the space',
      () async {
        final api = _Api();
        final client = await _client(api: api);
        final rooms = await _rooms(client);
        await _bakery(client);
        await _settle();

        await rooms.leaveSpace('!bakery:example.com');
        await _settle();

        final left = leftIds(api);
        expect(
          left.indexOf('!crumb:example.com'),
          lessThan(left.indexOf('!deeper:example.com')),
        );
        expect(
          left.indexOf('!deeper:example.com'),
          lessThan(left.indexOf('!recipes:example.com')),
        );
        expect(
          left.indexOf('!sourdough:example.com'),
          lessThan(left.indexOf('!recipes:example.com')),
        );
        expect(
          left.indexOf('!recipes:example.com'),
          lessThan(left.indexOf('!bakery:example.com')),
        );
        expect(
          left.indexOf('!general:example.com'),
          lessThan(left.indexOf('!bakery:example.com')),
        );
        expect(left.last, '!bakery:example.com');
      },
    );

    test('leaving a space keeps rooms another joined space lists', () async {
      final api = _Api();
      final client = await _client(api: api);
      final rooms = await _rooms(client);
      await _bakery(client);
      await _sync(client, {
        'join': {
          '!twin:example.com': _room(
            'twin',
            type: 'm.space',
            extra: [_child('!crumb:example.com')],
          ),
        },
      });
      await _settle();

      await rooms.leaveSpace('!bakery:example.com');
      await _settle();

      final left = leftIds(api);
      expect(left, isNot(contains('!crumb:example.com')));
      expect(left, contains('!deeper:example.com'));
      expect(left, contains('!bakery:example.com'));
    });

    test(
      'a partly refused leave throws PartlyDone naming what stayed',
      () async {
        final api = _Api()..refuseIds.add('!oven:example.com');
        final client = await _client(api: api);
        final rooms = await _rooms(client);
        await _bakery(client);
        await _settle();

        await expectLater(
          rooms.leaveSpace('!bakery:example.com'),
          throwsA(
            isA<PartlyDone>().having((e) => e.missing, 'missing', ['oven']),
          ),
        );
        await _settle();
        // The space's own wish still hides it, so with the space gone from
        // the rail, oven's real (still joined) state shows through in Home.
        expect(rooms.homeRooms.map((c) => c.id), contains('!oven:example.com'));
      },
    );

    test('disposing mid-leave notifies nothing', () async {
      final api = _Api()..hold = Completer();
      final client = await _client(api: api);
      // Disposed explicitly below, so not through `_rooms`'s teardown too.
      final rooms = MatrixRooms(client);
      await _settle();
      await _bakery(client);
      await _settle();

      var notifications = 0;
      rooms.addListener(() => notifications++);
      final result = rooms.leaveSpace('!bakery:example.com');
      await _settle();
      final before = notifications;

      rooms.dispose();
      api.hold!.complete();
      await result;
      await _settle();

      expect(notifications, before);
    });

    test('creating a space makes #general and hangout under it', () async {
      final api = _Api();
      final client = await _client(api: api);
      final rooms = await _rooms(client);

      final id = await rooms.createSpace('Bakers', me: rooms.me);
      await _settle();

      expect(id, '!created:example.com');
      expect(
        api.answered.where((p) => p.endsWith('/createRoom')),
        hasLength(3),
      );
      expect(
        api.answered.where((p) => p.contains('/state/m.space.child/')),
        hasLength(2),
      );
    });

    test('a refused channel still returns the space, as PartlyDone', () async {
      final api = _Api()..refuseNames.add('hangout');
      final client = await _client(api: api);
      final rooms = await _rooms(client);

      await expectLater(
        rooms.createSpace('Bakers', me: rooms.me),
        throwsA(
          isA<PartlyDone>()
              .having((e) => e.spaceId, 'spaceId', '!created:example.com')
              .having((e) => e.missing, 'missing', ['hangout']),
        ),
      );
    });
  });

  test("a member's avatar maps from their member event", () async {
    final client = await _client();
    final rooms = await _rooms(client);
    await _sync(client, {
      'join': {
        '!avatars:example.com': _room(
          'avatars',
          type: 'm.space',
          extra: [
            _state(
              'm.room.member',
              {
                'membership': 'join',
                'displayname': 'Alice',
                'avatar_url': 'mxc://x/a',
              },
              key: '@alice:x',
              sender: '@alice:x',
            ),
          ],
        ),
      },
    });
    await _settle();
    // Only a room list's state is in memory until a member list is wanted.
    rooms.loadMembers('!avatars:example.com');
    await _settle();
    final members = {for (final m in rooms.spaces.last.members) m.id: m};
    expect(members['@alice:x']!.avatar, const AvatarRef('mxc://x/a'));
    expect(members[_me]!.avatar, isNull);
  });

  test('media after dispose is a closed source, not a fresh store', () async {
    final client = await _client();
    final dir = Directory.systemTemp.createTempSync('rooms_media_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final live = MatrixRooms(client, mediaRoot: dir);
    expect(live.media.store, isNotNull);
    live.dispose();

    final late = MatrixRooms(client, mediaRoot: dir)..dispose();
    // A rebuild after sign-out asks again: nothing is opened for it.
    expect(late.media.store, isNull);
    const media = Media(kind: MediaKind.image, name: 'a.png', ref: 'x');
    expect(late.media.preview(media, 300), isNull);
  });
}
