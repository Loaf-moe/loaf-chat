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

/// A room you are in as Mochi, with Ada in memory too unless [withAda]
/// is off, and [count] joined by the server's summary. Your own member
/// event is always in memory, as the arrivals load it before judging.
Room _joined(Client client, {int? count, bool withAda = true}) {
  final room = Room(
    id: _room,
    client: client,
    summary: RoomSummary.fromJson({'m.joined_member_count': ?count}),
  );
  for (final (id, name) in [
    (_me, 'Mochi'),
    if (withAda) ('@ada:example.com', 'Ada'),
  ]) {
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

/// The rules: a name mention, your localpart, a direct message, any
/// message unless [message] is off, and a rule for rooms whose member
/// count [countRule] says.
Future<void> _rules(
  Client client, {
  bool message = true,
  List<String> mentionsOnly = const [],
  String? countRule,
  bool oneToOne = false,
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
                if (countRule != null)
                  _rule(
                    '.loaf.count',
                    [
                      {'kind': 'room_member_count', 'is': countRule},
                    ],
                    ['notify'],
                  ),
                if (oneToOne)
                  _rule(
                    '.m.rule.room_one_to_one',
                    [
                      {'kind': 'room_member_count', 'is': '2'},
                      {
                        'kind': 'event_match',
                        'key': 'type',
                        'pattern': 'm.room.message',
                      },
                    ],
                    ['notify'],
                  ),
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

  test('a two-person room by the server\'s count is a direct message to '
      'the rules', () async {
    final client = await _client();
    await _rules(client, message: false, oneToOne: true);
    final room = _joined(client, count: 2, withAda: false);
    expect(PushRules(client).notifies(_message(room, 'hi')), isTrue);
  });

  test(
    'a bigger room by the server\'s count is not, whatever memory holds',
    () async {
      final client = await _client();
      await _rules(client, message: false, oneToOne: true);
      final room = _joined(client, count: 3);
      expect(PushRules(client).notifies(_message(room, 'hi')), isFalse);
    },
  );

  test(
    'a count condition with an operator follows the server\'s count',
    () async {
      final client = await _client();
      await _rules(client, message: false, countRule: '>=100');
      final rules = PushRules(client);
      expect(
        rules.notifies(_message(_joined(client, count: 150), 'hi')),
        isTrue,
      );
      expect(
        rules.notifies(_message(_joined(client, count: 50), 'hi')),
        isFalse,
      );
    },
  );

  test('without a server\'s count the members in memory decide', () async {
    final client = await _client();
    await _rules(client, message: false, oneToOne: true);
    final room = _joined(client);
    expect(PushRules(client).notifies(_message(room, 'hi')), isTrue);
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
