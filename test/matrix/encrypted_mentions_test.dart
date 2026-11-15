// A channel set to mentions only holds a room-kind push rule with no
// actions, and the server checks room rules before `.m.rule.encrypted`. In
// an encrypted channel that rule silences every message at the server,
// mentions included, because the server cannot see inside one to find the
// mention. These tests pin the override that carries such a channel's
// encrypted messages to the device anyway, where the extension decrypts
// them and the real rules decide.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:loaf_native/matrix/encrypted_mentions.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _me = '@test:fakeServer.notExisting';
const _secret = '!secret:example.com';
const _open = '!open:example.com';

/// Records every push-rule write as `METHOD kind/rule_id`, decoded, and
/// each PUT's body by rule id.
class _Api extends FakeMatrixApi {
  final writes = <String>[];
  final bodies = <String, Map<String, Object?>>{};

  @override
  FutureOr<http.Response> mockIntercept(http.Request request) async {
    final path = request.url.path;
    const marker = '/pushrules/global/';
    if ((request.method == 'PUT' || request.method == 'DELETE') &&
        path.contains(marker)) {
      final rest = path.substring(path.indexOf(marker) + marker.length);
      final slash = rest.indexOf('/');
      final kind = rest.substring(0, slash);
      final id = Uri.decodeComponent(rest.substring(slash + 1));
      writes.add('${request.method} $kind/$id');
      if (request.method == 'PUT') {
        bodies[id] = jsonDecode(request.body) as Map<String, Object?>;
      }
      return http.Response('{}', 200);
    }
    return super.mockIntercept(request);
  }
}

Future<(Client, _Api)> _client() async {
  final api = _Api();
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
  return (client, api);
}

Map<String, Object?> _state(
  String type,
  Map<String, Object?> content, {
  String key = '',
}) => {
  'type': type,
  'state_key': key,
  'sender': _me,
  'event_id': '\$$type$key',
  'origin_server_ts': 0,
  'content': content,
};

Map<String, Object?> _room({required bool encrypted}) => {
  'state': {
    'events': [
      _state('m.room.create', {'creator': _me}),
      _state('m.room.member', {'membership': 'join'}, key: _me),
      if (encrypted)
        _state('m.room.encryption', {'algorithm': 'm.megolm.v1.aes-sha2'}),
    ],
  },
};

Map<String, Object?> _ours(String roomId) => {
  'rule_id': encryptedMentionsRuleId(roomId),
  'default': false,
  'enabled': true,
  'conditions': [
    {'kind': 'event_match', 'key': 'room_id', 'pattern': roomId},
    {'kind': 'event_match', 'key': 'type', 'pattern': 'm.room.encrypted'},
  ],
  'actions': ['notify'],
};

/// The account's rules: [mentions] rooms hold the SDK's room rule, [muted]
/// rooms its override, and [carried] rooms already hold ours.
Map<String, Object?> _rules({
  List<String> mentions = const [],
  List<String> muted = const [],
  List<String> carried = const [],
}) => {
  'type': 'm.push_rules',
  'content': {
    'global': {
      'override': [
        for (final id in carried) _ours(id),
        for (final id in muted)
          {
            'rule_id': id,
            'default': false,
            'enabled': true,
            'conditions': [
              {'kind': 'event_match', 'key': 'room_id', 'pattern': id},
            ],
            'actions': <Object>[],
          },
      ],
      'room': [
        for (final id in mentions)
          {
            'rule_id': id,
            'default': false,
            'enabled': true,
            'actions': <Object>[],
          },
      ],
    },
  },
};

Future<void> _sync(
  Client client, {
  Map<String, Object?> rooms = const {},
  Map<String, Object?>? rules,
  String batch = 'b1',
}) => client.handleSync(
  SyncUpdate.fromJson({
    'next_batch': batch,
    'rooms': {'join': rooms},
    'account_data': {
      'events': [?rules],
    },
  }),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a mentions-only encrypted channel gains the override', () async {
    final (client, api) = await _client();
    await _sync(
      client,
      rooms: {_secret: _room(encrypted: true)},
      rules: _rules(mentions: [_secret]),
    );
    await reconcileEncryptedMentions(client);
    final id = encryptedMentionsRuleId(_secret);
    expect(api.writes, ['PUT override/$id']);
    expect(api.bodies[id], {
      'actions': ['notify'],
      'conditions': [
        {'kind': 'event_match', 'key': 'room_id', 'pattern': _secret},
        {'kind': 'event_match', 'key': 'type', 'pattern': 'm.room.encrypted'},
      ],
    });
  });

  test('an unencrypted mentions-only channel needs nothing', () async {
    // The server can see a mention there, so the room rule is enough.
    final (client, api) = await _client();
    await _sync(
      client,
      rooms: {_open: _room(encrypted: false)},
      rules: _rules(mentions: [_open]),
    );
    await reconcileEncryptedMentions(client);
    expect(api.writes, isEmpty);
  });

  test('a channel that already has the override is left alone', () async {
    final (client, api) = await _client();
    await _sync(
      client,
      rooms: {_secret: _room(encrypted: true)},
      rules: _rules(mentions: [_secret], carried: [_secret]),
    );
    await reconcileEncryptedMentions(client);
    expect(api.writes, isEmpty);
  });

  test('a channel back on all messages loses the override', () async {
    final (client, api) = await _client();
    await _sync(
      client,
      rooms: {_secret: _room(encrypted: true)},
      rules: _rules(carried: [_secret]),
    );
    await reconcileEncryptedMentions(client);
    expect(api.writes, ['DELETE override/${encryptedMentionsRuleId(_secret)}']);
  });

  test('a muted channel loses the override', () async {
    // Mute must silence it at the server; carrying it to the phone only to
    // drop it there spends a wake-up on nothing.
    final (client, api) = await _client();
    await _sync(
      client,
      rooms: {_secret: _room(encrypted: true)},
      rules: _rules(muted: [_secret], carried: [_secret]),
    );
    await reconcileEncryptedMentions(client);
    expect(api.writes, ['DELETE override/${encryptedMentionsRuleId(_secret)}']);
  });

  test('a channel you are no longer in loses the override', () async {
    final (client, api) = await _client();
    await _sync(client, rules: _rules(carried: ['!gone:example.com']));
    await reconcileEncryptedMentions(client);
    expect(api.writes, [
      'DELETE override/${encryptedMentionsRuleId('!gone:example.com')}',
    ]);
  });

  test('other overrides are never touched', () async {
    final (client, api) = await _client();
    await _sync(
      client,
      rooms: {_secret: _room(encrypted: true)},
      rules: _rules(muted: [_secret]),
    );
    await reconcileEncryptedMentions(client);
    expect(api.writes, isEmpty);
  });

  test(
    'the watcher adds the override when a channel turns mentions-only',
    () async {
      final (client, api) = await _client();
      final watcher = EncryptedMentions(client);
      addTearDown(watcher.dispose);
      await _sync(client, rooms: {_secret: _room(encrypted: true)});
      await pumpEventQueue();
      expect(api.writes, isEmpty);

      // What the server echoes after setPushRuleState(mentionsOnly), from
      // this app or any other client.
      await _sync(
        client,
        rules: _rules(mentions: [_secret]),
        batch: 'b2',
      );
      await pumpEventQueue();
      expect(api.writes, ['PUT override/${encryptedMentionsRuleId(_secret)}']);
    },
  );

  test(
    'the watcher adds the override when a channel turns encrypted',
    () async {
      final (client, api) = await _client();
      final watcher = EncryptedMentions(client);
      addTearDown(watcher.dispose);
      await _sync(
        client,
        rooms: {_secret: _room(encrypted: false)},
        rules: _rules(mentions: [_secret]),
      );
      await pumpEventQueue();
      expect(api.writes, isEmpty);

      await _sync(
        client,
        rooms: {
          _secret: {
            'timeline': {
              'events': [
                _state('m.room.encryption', {
                  'algorithm': 'm.megolm.v1.aes-sha2',
                }),
              ],
            },
          },
        },
        batch: 'b2',
      );
      await pumpEventQueue();
      expect(api.writes, ['PUT override/${encryptedMentionsRuleId(_secret)}']);
    },
  );
}
