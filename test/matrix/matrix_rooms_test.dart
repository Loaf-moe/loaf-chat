import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:loaf_native/matrix/matrix_rooms.dart';
import 'package:loaf_native/ui/members/presence.dart' as loaf;
import 'package:loaf_native/ui/model/models.dart';
import 'package:loaf_native/ui/rooms/rooms.dart';
// The SDK has a Role of its own; the one under test is loaf's.
import 'package:matrix/matrix.dart' hide Role;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _me = '@test:fakeServer.notExisting';

/// The fake server, plus answers it lacks: joining and leaving a room.
/// [hold] keeps those answers back until completed; [refuse] makes them
/// a 403.
class _Api extends FakeMatrixApi {
  final answered = <String>[];
  Completer<void>? hold;
  var refuse = false;

  @override
  FutureOr<http.Response> mockIntercept(http.Request request) async {
    final path = request.url.path;
    if (request.method == 'POST' &&
        (path.endsWith('/join') || path.endsWith('/leave'))) {
      answered.add(path);
      await hold?.future;
      return refuse
          ? http.Response(
              jsonEncode({'errcode': 'M_FORBIDDEN', 'error': 'not allowed'}),
              403,
            )
          : http.Response(jsonEncode({'room_id': '!invited:example.com'}), 200);
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
  test('rooms in no space land in Home, a DM as a DM', () async {
    final rooms = await _rooms(await _client());
    expect(rooms.synced, isTrue);
    expect(rooms.spaces, isEmpty);
    final byId = {for (final c in rooms.homeRooms) c.id: c};
    // The fake's m.direct lists this one.
    final dm = byId['!726s6s6q:example.com']!;
    expect(dm.kind, ChannelKind.direct);
    expect(dm.unread, 2);
    expect(dm.mentions, 2);
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

  test('a channel carries its counts, topic and lock', () async {
    final client = await _client();
    final rooms = await _rooms(client);
    await _bakery(client);
    await _settle();

    final sourdough = rooms.spaces.last.categories.last.channels.first;
    expect(sourdough.private, isTrue);
    expect(sourdough.topic, 'wild yeast');
    expect(sourdough.unread, 4);
    expect(sourdough.mentions, 1);
    expect(sourdough.muted, isFalse);
    expect(rooms.spaces.last.mentions, 1);
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

  test('you are you, and only answering invites is wired', () async {
    final rooms = await _rooms(await _client());
    expect(rooms.me.id, _me);
    expect(rooms.me.name, isNotEmpty);
    expect(rooms.abilities, {RoomAbility.answerInvites});
    expect(() => rooms.markRead('!calls:example.com'), throwsUnsupportedError);
  });
}
