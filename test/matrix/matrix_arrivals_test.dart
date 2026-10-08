import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:loaf_native/matrix/matrix_arrivals.dart';
import 'package:loaf_native/ui/model/arrival.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _me = '@test:fakeServer.notExisting';
const _general = '!general:example.com';
const _ada = '@ada:example.com';

/// "Launch": the instant the shell opens. Events are sent either side of it.
final _launch = DateTime.utc(2024, 1, 1, 12);
final _before = _launch.millisecondsSinceEpoch - 60000;
final _after = _launch.millisecondsSinceEpoch + 60000;

var _n = 0;

/// A client signed in to the fake server. With [firstSync] false it has not
/// synced, so `prevBatch` is null, as during a sign-in's first sync.
Future<Client> _client({bool firstSync = true}) async {
  final api = FakeMatrixApi();
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
    waitForFirstSync: firstSync,
  );
  addTearDown(client.dispose);
  return client;
}

Map<String, Object?> _state(
  String type,
  Map<String, Object?> content, {
  String key = '',
}) => {
  'type': type,
  'state_key': key,
  'sender': _me,
  'content': content,
  'event_id': '\$s${_n++}',
  'origin_server_ts': 1700000000000,
};

Map<String, Object?> _room() => {
  'state': {
    'events': [
      _state('m.room.create', {'creator': _me}),
      _state('m.room.name', {'name': 'general'}),
      _state('m.room.member', {'membership': 'join'}, key: _me),
    ],
  },
};

Map<String, Object?> _msg(
  String id, {
  String sender = _ada,
  int? ts,
  Map<String, Object?>? mentions,
}) => {
  'type': 'm.room.message',
  'sender': sender,
  'content': {'msgtype': 'm.text', 'body': 'hi', 'm.mentions': ?mentions},
  'event_id': id,
  'origin_server_ts': ts ?? _after,
};

Future<void> _sync(
  Client client, {
  Map<String, Object?> rooms = const {},
  List<Map<String, Object?>> accountData = const [],
}) => client.handleSync(
  SyncUpdate.fromJson({
    'next_batch': 'b${_n++}',
    'rooms': rooms,
    if (accountData.isNotEmpty) 'account_data': {'events': accountData},
  }),
);

/// The client joined to #general, as an earlier sync left it.
Future<void> _join(Client client) => _sync(
  client,
  rooms: {
    'join': {_general: _room()},
  },
);

/// A sync of [events] landing in #general.
Future<void> _deliver(Client client, List<Map<String, Object?>> events) =>
    _sync(
      client,
      rooms: {
        'join': {
          _general: {
            'timeline': {
              'events': events,
              'limited': false,
              'prev_batch': 'p${_n++}',
            },
          },
        },
      },
    );

/// Push rules as a server holds them: a mention of you notifies, and so does
/// any message, except where a room rule says [muted].
Map<String, Object?> _pushRules({List<String> muted = const []}) => {
  'type': 'm.push_rules',
  'content': {
    'global': {
      'override': [
        {
          'rule_id': '.m.rule.is_user_mention',
          'default': true,
          'enabled': true,
          'conditions': [
            {
              'kind': 'event_property_contains',
              'key': r'content.m\.mentions.user_ids',
              'value': _me,
            },
          ],
          'actions': [
            'notify',
            {'set_tweak': 'highlight'},
          ],
        },
      ],
      'content': <Object?>[],
      'room': [
        for (final id in muted)
          {
            'rule_id': id,
            'default': false,
            'enabled': true,
            'actions': ['dont_notify'],
          },
      ],
      'sender': <Object?>[],
      'underride': [
        {
          'rule_id': '.m.rule.message',
          'default': true,
          'enabled': true,
          'conditions': [
            {'kind': 'event_match', 'key': 'type', 'pattern': 'm.room.message'},
          ],
          'actions': ['notify'],
        },
      ],
    },
  },
};

/// The arrivals under test, collected, and every timeline event the SDK
/// emitted (so a test can tell "filtered" from "never delivered").
class _Rig {
  _Rig(this.client, {DateTime Function()? now})
    : arrivals = MatrixArrivals(client, now: now ?? () => _launch) {
    _subs = [
      arrivals.stream.listen(got.add, onDone: () => closed = true),
      // Subscribed after the arrivals' own, so it runs after them.
      client.onTimelineEvent.stream.listen((e) {
        seen.add(e.eventId);
        events[e.eventId] = e;
      }),
    ];
  }

  final Client client;
  final MatrixArrivals arrivals;
  final got = <Arrival>[];
  final seen = <String>[];
  final events = <String, Event>{};
  var closed = false;
  late final List<StreamSubscription<Object?>> _subs;

  /// Waits until the SDK has emitted [id], then lets the arrivals settle.
  Future<void> reached(String id) async {
    await _until(() => seen.contains(id));
    expect(seen, contains(id));
    await Future<void>.delayed(Duration.zero);
  }

  void dispose() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    arrivals.dispose();
  }
}

Future<_Rig> _rig(Client client, {DateTime Function()? now}) async {
  final rig = _Rig(client, now: now);
  addTearDown(rig.dispose);
  return rig;
}

/// Waits until [done], however long a busy machine takes.
Future<void> _until(bool Function() done) async {
  final give = DateTime.now().add(const Duration(seconds: 10));
  while (!done() && DateTime.now().isBefore(give)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  group('arrivals', () {
    test('a message from someone else, after launch, arrives', () async {
      final client = await _client();
      await _join(client);
      final rig = await _rig(client);
      await _deliver(client, [_msg(r'$m')]);
      await _until(() => rig.got.isNotEmpty);
      expect(rig.got, [const Arrival(roomId: _general, eventId: r'$m')]);
    });

    test('your own message does not', () async {
      final client = await _client();
      await _join(client);
      final rig = await _rig(client);
      await _deliver(client, [_msg(r'$mine', sender: _me), _msg(r'$theirs')]);
      await rig.reached(r'$theirs');
      expect(rig.got.map((a) => a.eventId), [r'$theirs']);
    });

    test('the catch-up after a relaunch is quiet', () async {
      final client = await _client();
      await _join(client);
      final rig = await _rig(client);
      await _deliver(client, [
        _msg(r'$old', ts: _before),
        _msg(r'$new', ts: _after),
      ]);
      await rig.reached(r'$new');
      expect(rig.got.map((a) => a.eventId), [r'$new']);
    });

    test('nothing arrives from an initial sync', () async {
      // Not yet synced: prevBatch is null, as during a sign-in's first sync.
      final client = await _client(firstSync: false);
      expect(client.prevBatch, isNull);
      // The rules are in place (the SDK applies a sync's account data after
      // its rooms), so only the first-sync rule keeps $first quiet.
      await _sync(client, accountData: [_pushRules()]);
      expect(client.prevBatch, isNull);
      final rig = await _rig(client);
      await _sync(
        client,
        rooms: {
          'join': {
            _general: {
              ..._room(),
              'timeline': {
                'events': [_msg(r'$first')],
                'limited': false,
                'prev_batch': 'p0',
              },
            },
          },
        },
      );
      await rig.reached(r'$first');
      expect(client.prevBatch, isNull);
      expect(rig.got, isEmpty);
    });

    test('a reaction, an edit and a state change do not arrive', () async {
      final client = await _client();
      await _join(client);
      final rig = await _rig(client);
      await _deliver(client, [
        {
          'type': 'm.reaction',
          'sender': _ada,
          'content': {
            'm.relates_to': {
              'rel_type': 'm.annotation',
              'event_id': r'$target',
              'key': 'x',
            },
          },
          'event_id': r'$react',
          'origin_server_ts': _after,
        },
        {
          'type': 'm.room.message',
          'sender': _ada,
          'content': {
            'msgtype': 'm.text',
            'body': '* fixed',
            'm.new_content': {'msgtype': 'm.text', 'body': 'fixed'},
            'm.relates_to': {'rel_type': 'm.replace', 'event_id': r'$target'},
          },
          'event_id': r'$edit',
          'origin_server_ts': _after,
        },
        {
          'type': 'm.room.topic',
          'state_key': '',
          'sender': _ada,
          'content': {'topic': 'wild yeast'},
          'event_id': r'$topic',
          'origin_server_ts': _after,
        },
        _msg(r'$real'),
      ]);
      await rig.reached(r'$real');
      expect(rig.seen, containsAll([r'$react', r'$edit', r'$topic']));
      expect(rig.got.map((a) => a.eventId), [r'$real']);
    });

    test('a muted room is quiet but a mention in it chimes', () async {
      final client = await _client();
      await _join(client);
      // The SDK builds its evaluator from the `m.push_rules` account data
      // of a sync: a room rule named for the room, with no notify action.
      await _sync(
        client,
        accountData: [
          _pushRules(muted: [_general]),
        ],
      );
      final rig = await _rig(client);
      await _deliver(client, [
        _msg(r'$plain'),
        _msg(
          r'$mention',
          mentions: {
            'user_ids': [_me],
          },
        ),
      ]);
      await rig.reached(r'$mention');
      expect(rig.got.map((a) => a.eventId), [r'$mention']);
    });

    test('the same messages arrive once the room is unmuted', () async {
      // Guards the muted test: its rules, not the fixture, silence $plain.
      final client = await _client();
      await _join(client);
      await _sync(client, accountData: [_pushRules()]);
      final rig = await _rig(client);
      await _deliver(client, [_msg(r'$plain')]);
      await _until(() => rig.got.isNotEmpty);
      expect(rig.got.single.eventId, r'$plain');
    });

    test('a room you have left does not notify', () async {
      final client = await _client();
      await _join(client);
      final rig = await _rig(client);
      // A room the client holds only as left: the SDK builds its event's
      // room with that membership.
      await _sync(
        client,
        rooms: {
          'leave': {
            '!gone:example.com': {
              'timeline': {
                'events': [_msg(r'$parting')],
                'limited': false,
                'prev_batch': 'p${_n++}',
              },
            },
          },
        },
      );
      await rig.reached(r'$parting');
      expect(rig.events[r'$parting']?.room.membership, Membership.leave);
      expect(rig.got, isEmpty);
    });

    test('after dispose, nothing arrives and the stream closes', () async {
      final client = await _client();
      await _join(client);
      final rig = await _rig(client);
      rig.arrivals.dispose();
      await _until(() => rig.closed);
      expect(rig.closed, isTrue);
      await _deliver(client, [_msg(r'$late')]);
      await rig.reached(r'$late');
      expect(rig.got, isEmpty);
    });
  });
}
