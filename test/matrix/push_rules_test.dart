import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:loaf_native/matrix/push_rules.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _me = '@test:fakeServer.notExisting';
const _room = '!r:example.com';
var _n = 0;

Future<Client> _client() async {
  final client = await openClient(
    httpClient: FakeMatrixApi(),
    databasePath: inMemoryDatabasePath,
  );
  FakeMatrixApi.client = client;
  await client.init(
    newToken: 'abcd',
    newHomeserver: Uri.parse('https://fakeServer.notExisting'),
    newUserID: _me,
    newDeviceID: 'GHTYAJCE',
    newDeviceName: 'loaf on test',
    waitForFirstSync: false,
  );
  addTearDown(client.dispose);
  return client;
}

/// A room you are in as Mochi, with Ada.
Room _joined(Client client) {
  final room = Room(id: _room, client: client);
  for (final (id, name) in [(_me, 'Mochi'), ('@ada:example.com', 'Ada')]) {
    room.setState(
      Event(
        type: EventTypes.RoomMember,
        stateKey: id,
        senderId: id,
        eventId: '\$m${_n++}',
        originServerTs: DateTime(2026),
        room: room,
        content: {'membership': 'join', 'displayname': name},
      ),
    );
  }
  return room;
}

Event _message(Room room, String body, {Map<String, Object?>? mentions}) =>
    Event(
      type: EventTypes.Message,
      content: {'msgtype': 'm.text', 'body': body, 'm.mentions': ?mentions},
      senderId: '@ada:example.com',
      eventId: '\$e${_n++}',
      originServerTs: DateTime(2026),
      room: room,
    );

Map<String, Object?> _rule(
  String id,
  List<Map<String, Object?>> conditions,
  List<Object?> actions, {
  bool enabled = true,
  String? pattern,
}) => {
  'rule_id': id,
  'default': true,
  'enabled': enabled,
  'conditions': conditions,
  'actions': actions,
  'pattern': ?pattern,
};

Future<void> _rules(
  Client client, {
  bool message = true,
  List<String> mentionsOnly = const [],
}) => client.handleSync(
  SyncUpdate.fromJson({
    'next_batch': 'b${_n++}',
    'account_data': {
      'events': [
        {
          'type': 'm.push_rules',
          'content': {
            'global': {
              'override': [
                _rule(
                  '.m.rule.contains_display_name',
                  [
                    {'kind': 'contains_display_name'},
                  ],
                  ['notify'],
                ),
              ],
              'content': [
                _rule('.m.rule.contains_user_name', [], [
                  'notify',
                ], pattern: 'test'),
              ],
              'room': [for (final id in mentionsOnly) _rule(id, [], [])],
              'sender': <Object?>[],
              'underride': [
                _rule(
                  '.m.rule.message',
                  [
                    {
                      'kind': 'event_match',
                      'key': 'type',
                      'pattern': 'm.room.message',
                    },
                  ],
                  ['notify'],
                  enabled: message,
                ),
              ],
            },
          },
        },
      ],
    },
  }),
);

void main() {
  test('a content rule outranks a room rule', () async {
    final client = await _client();
    await _rules(client, message: false, mentionsOnly: [_room]);
    final room = _joined(client);
    final rules = PushRules(client);
    expect(rules.notifies(_message(room, 'hi test')), isTrue);
    expect(rules.notifies(_message(room, 'hi')), isFalse);
  });

  test('a message with m.mentions is judged by it alone', () async {
    final client = await _client();
    await _rules(client, message: false);
    final room = _joined(client);
    final rules = PushRules(client);
    expect(rules.notifies(_message(room, 'hi Mochi')), isTrue);
    expect(rules.notifies(_message(room, 'hi Mochi', mentions: {})), isFalse);
    expect(
      rules.notifies(
        _message(
          room,
          'hi Mochi',
          mentions: {
            'user_ids': [_me],
          },
        ),
      ),
      isFalse,
      reason: 'no rule for user_ids here: the legacy rule alone is skipped',
    );
  });

  test('new rules on a sync apply', () async {
    final client = await _client();
    await _rules(client);
    final room = _joined(client);
    final rules = PushRules(client);
    expect(rules.notifies(_message(room, 'hi')), isTrue);
    await _rules(client, message: false);
    expect(rules.notifies(_message(room, 'hi')), isFalse);
  });
}
