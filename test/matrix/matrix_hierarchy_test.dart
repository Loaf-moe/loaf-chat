import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:loaf_native/matrix/matrix_hierarchy.dart';
import 'package:loaf_native/matrix/matrix_rooms.dart';
import 'package:loaf_native/ui/model/models.dart';
// The SDK has a Role of its own; not used here, but kept consistent with
// the other matrix test files that import the same hidden members.
import 'package:matrix/matrix.dart' hide Role;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _me = '@test:fakeServer.notExisting';

/// The fake server, plus `/hierarchy` answers the test fills page by page,
/// and joins so `setJoined` can be watched.
class _Api extends FakeMatrixApi {
  final answered = <http.Request>[];

  /// Each space's pages, in order. A page with no `next_batch` given is
  /// the last one.
  final hierarchyPages = <String, List<Map<String, Object?>>>{};

  /// Spaces whose next `/hierarchy` fetch answers with a server error.
  final hierarchyFailures = <String>{};

  /// Every space id a `/hierarchy` request named, in call order.
  final hierarchyCalls = <String>[];

  @override
  FutureOr<http.Response> mockIntercept(http.Request request) async {
    final path = request.url.path;
    if (request.method == 'GET' && path.contains('/hierarchy')) {
      final spaceId = Uri.decodeComponent(
        path.split('/rooms/')[1].split('/hierarchy')[0],
      );
      hierarchyCalls.add(spaceId);
      if (hierarchyFailures.remove(spaceId)) {
        return http.Response(
          jsonEncode({'errcode': 'M_UNKNOWN', 'error': 'boom'}),
          500,
        );
      }
      final pages = hierarchyPages[spaceId] ?? const [];
      final from = request.url.queryParameters['from'];
      final index = from == null ? 0 : int.parse(from);
      final page = index < pages.length ? pages[index] : {'rooms': <Object?>[]};
      return http.Response(jsonEncode(page), 200);
    }
    final method = request.method;
    final isJoinOrLeave =
        method == 'POST' && (path.endsWith('/join') || path.contains('/join/'));
    if (isJoinOrLeave) {
      answered.add(request);
      return http.Response(jsonEncode({'room_id': '!joined:example.com'}), 200);
    }
    return super.mockIntercept(request);
  }
}

Future<Client> _client(_Api api) async {
  final client = await openClient(
    httpClient: api,
    databasePath: inMemoryDatabasePath,
  );
  FakeMatrixApi.client = client;
  await client.init(
    newToken: 'abcd',
    newHomeserver: Uri.parse('https://fakeServer.notExisting'),
    newUserID: _me,
    newDeviceID: 'GHTYAJCE',
    newDeviceName: 'loaf on test',
    waitForFirstSync: true,
  );
  addTearDown(client.dispose);
  return client;
}

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

Map<String, Object?> _child(
  String id, {
  List<String> via = const ['example.com'],
}) => _state('m.space.child', {'via': via}, key: id);

Map<String, Object?> _room(
  String name, {
  String? type,
  List<Map<String, Object?>> extra = const [],
}) => {
  'state': {
    'events': [
      _state('m.room.create', {'creator': _me, 'type': ?type}),
      _state('m.room.name', {'name': name}),
      _state('m.room.member', {'membership': 'join'}, key: _me),
      ...extra,
    ],
  },
};

Future<void> _sync(Client client, Map<String, Object?> rooms) =>
    client.handleSync(
      SyncUpdate.fromJson({'next_batch': 'b${_events++}', 'rooms': rooms}),
    );

/// A `/hierarchy` chunk for one room.
Map<String, Object?> _chunk(
  String id, {
  String? name,
  String? roomType,
  String? joinRule = 'public',
  List<String>? allowedRoomIds,
  String? topic,
  List<Map<String, Object?>> children = const [],
}) => {
  'room_id': id,
  'guest_can_join': false,
  'world_readable': true,
  'num_joined_members': 1,
  'name': ?name,
  'room_type': ?roomType,
  'join_rule': ?joinRule,
  'allowed_room_ids': ?allowedRoomIds,
  'topic': ?topic,
  'children_state': children,
};

void main() {
  group('MatrixHierarchy', () {
    test('a hierarchy on two pages is read whole', () async {
      final api = _Api();
      final client = await _client(api);
      api.hierarchyPages['!bakery:example.com'] = [
        {
          'rooms': [_chunk('!a:example.com', name: 'a')],
          'next_batch': '1',
        },
        {
          'rooms': [_chunk('!b:example.com', name: 'b')],
        },
      ];
      var changes = 0;
      final hierarchy = MatrixHierarchy(client, onChange: () => changes++);
      addTearDown(hierarchy.dispose);

      expect(hierarchy.children('!bakery:example.com'), isNull);
      await _settle();

      final tree = hierarchy.children('!bakery:example.com');
      expect(tree, isNotNull);
      expect(tree!.map((c) => c.roomId), ['!a:example.com', '!b:example.com']);
      expect(changes, 1);
      expect(
        api.hierarchyCalls.where((id) => id == '!bakery:example.com'),
        hasLength(2),
      );
    });

    test('a failed fetch keeps the last tree', () async {
      final api = _Api();
      final client = await _client(api);
      api.hierarchyPages['!bakery:example.com'] = [
        {
          'rooms': [_chunk('!a:example.com', name: 'a')],
        },
      ];
      final hierarchy = MatrixHierarchy(client, onChange: () {});
      addTearDown(hierarchy.dispose);

      hierarchy.children('!bakery:example.com');
      await _settle();
      final good = hierarchy.children('!bakery:example.com');
      expect(good!.map((c) => c.roomId), ['!a:example.com']);

      api.hierarchyFailures.add('!bakery:example.com');
      hierarchy.invalidate('!bakery:example.com');
      final duringRefetch = hierarchy.children('!bakery:example.com');
      expect(duringRefetch!.map((c) => c.roomId), ['!a:example.com']);
      await _settle();

      final afterFailure = hierarchy.children('!bakery:example.com');
      expect(afterFailure!.map((c) => c.roomId), ['!a:example.com']);

      // And it tries again once told to.
      hierarchy.invalidate('!bakery:example.com');
      hierarchy.children('!bakery:example.com');
      await _settle();
      expect(
        api.hierarchyCalls.where((id) => id == '!bakery:example.com'),
        hasLength(3),
      );
    });
  });

  group('space hierarchy in MatrixRooms', () {
    Space bakery(MatrixRooms rooms) =>
        rooms.spaces.firstWhere((s) => s.id == '!bakery:example.com');

    Future<MatrixRooms> bakeryWith(
      Client client,
      List<Map<String, Object?>> children,
    ) async {
      final rooms = MatrixRooms(client);
      addTearDown(rooms.dispose);
      await _settle();
      await _sync(client, {
        'join': {
          '!bakery:example.com': _room(
            'Bakery',
            type: 'm.space',
            extra: children,
          ),
        },
      });
      await _settle();
      return rooms;
    }

    test('an unjoined child shows as an unjoined channel', () async {
      final api = _Api();
      final client = await _client(api);
      api.hierarchyPages['!bakery:example.com'] = [
        {
          'rooms': [
            _chunk(
              '!unjoined:example.com',
              name: 'proofing',
              topic: 'rise slowly',
            ),
          ],
        },
      ];
      final rooms = await bakeryWith(client, [_child('!unjoined:example.com')]);
      await _settle();

      final channel = bakery(rooms).categories.first.channels
          .singleWhere((c) => c.id == '!unjoined:example.com');
      expect(channel.name, 'proofing');
      expect(channel.topic, 'rise slowly');
      expect(channel.joined, isFalse);
      expect(channel.kind, ChannelKind.text);
    });

    test('invite-only and knock children are not shown', () async {
      final api = _Api();
      final client = await _client(api);
      api.hierarchyPages['!bakery:example.com'] = [
        {
          'rooms': [
            _chunk('!invited:example.com', joinRule: 'invite'),
            _chunk('!knockable:example.com', joinRule: 'knock'),
          ],
        },
      ];
      final rooms = await bakeryWith(client, [
        _child('!invited:example.com'),
        _child('!knockable:example.com'),
      ]);
      await _settle();

      final ids = bakery(rooms).categories
          .expand((c) => c.channels)
          .map((c) => c.id);
      expect(ids, isNot(contains('!invited:example.com')));
      expect(ids, isNot(contains('!knockable:example.com')));
    });

    test('a new child in a sync fetches again', () async {
      final api = _Api();
      final client = await _client(api);
      api.hierarchyPages['!bakery:example.com'] = [
        {'rooms': <Object?>[]},
      ];
      final rooms = await bakeryWith(client, []);
      await _settle();
      expect(bakery(rooms).categories, isEmpty);
      expect(
        api.hierarchyCalls.where((id) => id == '!bakery:example.com'),
        hasLength(1),
      );

      api.hierarchyPages['!bakery:example.com'] = [
        {
          'rooms': [_chunk('!fresh:example.com', name: 'fresh')],
        },
      ];
      await _sync(client, {
        'join': {
          '!bakery:example.com': {
            'state': {
              'events': [_child('!fresh:example.com')],
            },
          },
        },
      });
      await _settle();

      expect(
        api.hierarchyCalls.where((id) => id == '!bakery:example.com').length,
        greaterThan(1),
      );
      final ids = bakery(rooms).categories
          .expand((c) => c.channels)
          .map((c) => c.id);
      expect(ids, contains('!fresh:example.com'));
    });

    test('joining a listed channel goes through its via servers', () async {
      final api = _Api();
      final client = await _client(api);
      api.hierarchyPages['!bakery:example.com'] = [
        {
          'rooms': [
            {
              ..._chunk('!bakery:example.com', roomType: 'm.space'),
              'children_state': [
                _child(
                  '!unjoined:example.com',
                  via: ['one.example.com', 'two.example.com'],
                ),
              ],
            },
            _chunk('!unjoined:example.com', name: 'unjoined'),
          ],
        },
      ];
      final rooms = await bakeryWith(client, [_child('!unjoined:example.com')]);
      await _settle();

      await rooms.setJoined('!unjoined:example.com', true);
      await _settle();

      final join = api.answered.singleWhere(
        (r) => r.url.path.contains('/join/'),
      );
      expect(
        join.url.queryParametersAll['via'],
        unorderedEquals(['one.example.com', 'two.example.com']),
      );
    });

    test(
      'a new child in a nested subspace fetches its top space again',
      () async {
        final api = _Api();
        final client = await _client(api);
        api.hierarchyPages['!bakery:example.com'] = [
          {
            'rooms': [
              _chunk('!annex:example.com', name: 'annex', roomType: 'm.space'),
            ],
          },
        ];
        final rooms = await bakeryWith(client, [_child('!annex:example.com')]);
        await _settle();
        expect(
          bakery(rooms).categories
              .singleWhere((c) => c.name == 'annex')
              .channels,
          isEmpty,
        );
        // Bakery's own initial state lists annex too, so it may already
        // have refetched itself once by now — that's fine. What matters
        // is that the sync below, naming annex rather than bakery, makes
        // it fetch again.
        final callsBefore = api.hierarchyCalls
            .where((id) => id == '!bakery:example.com')
            .length;

        // Annex itself is joined; its new child, listed by its own
        // m.space.child, is not — its name only comes from the top
        // space's hierarchy, which the sync below must refetch.
        api.hierarchyPages['!bakery:example.com'] = [
          {
            'rooms': [
              _chunk('!annex:example.com', name: 'annex', roomType: 'm.space'),
              _chunk('!fresh:example.com', name: 'fresh'),
            ],
          },
        ];
        await _sync(client, {
          'join': {
            '!annex:example.com': _room(
              'annex',
              type: 'm.space',
              extra: [_child('!fresh:example.com')],
            ),
          },
        });
        await _settle();

        expect(
          api.hierarchyCalls.where((id) => id == '!bakery:example.com').length,
          greaterThan(callsBefore),
        );
        final channels = bakery(rooms).categories
            .singleWhere((c) => c.name == 'annex')
            .channels;
        expect(channels.map((c) => c.id), contains('!fresh:example.com'));
      },
    );
  });
}
