import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:loaf_native/matrix/matrix_arrivals.dart';
import 'package:loaf_native/ui/model/arrival.dart';
import 'package:loaf_native/ui/model/models.dart' show AvatarRef;
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _me = '@test:fakeServer.notExisting';
const _general = '!general:example.com';
const _dm = '!dm:example.com';
const _ada = '@ada:example.com';

/// The fake server, with its member list refused the first time it is
/// asked (unless [refuseFirst] is off) and, after that, you and Ada; each
/// answer waits on [hold] when set.
class _MembersLater extends FakeMatrixApi {
  var asked = 0;
  var refuseFirst = true;
  Completer<void>? hold;

  @override
  FutureOr<http.Response> mockIntercept(http.Request request) async {
    if (request.method == 'GET' && request.url.path.endsWith('/members')) {
      await hold?.future;
      if (asked++ == 0 && refuseFirst) {
        return http.Response(
          jsonEncode({'errcode': 'M_UNKNOWN', 'error': 'no'}),
          500,
        );
      }
      return http.Response(
        jsonEncode({
          'chunk': [
            for (final id in [_me, _ada])
              {
                'type': 'm.room.member',
                'state_key': id,
                'sender': id,
                'content': {'membership': 'join'},
                'event_id': '\$member_$id',
                'origin_server_ts': 1,
              },
          ],
        }),
        200,
      );
    }
    return super.mockIntercept(request);
  }
}

/// "Launch": the instant the shell opens. Events are sent either side of it.
final _launch = DateTime.utc(2024, 1, 1, 12);
final _before = _launch.millisecondsSinceEpoch - 60000;
final _after = _launch.millisecondsSinceEpoch + 60000;

var _n = 0;

/// A client signed in to the fake server. With [firstSync] false it has not
/// synced, so `prevBatch` is null, as during a sign-in's first sync.
Future<Client> _client({bool firstSync = true, FakeMatrixApi? api}) async {
  api ??= FakeMatrixApi();
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

/// A direct message with Ada, [count] members by the server's summary
/// (none said when null); her member event comes only when [withAda];
/// you are named [myName] when given.
Map<String, Object?> _directRoom({
  required bool withAda,
  int? count = 2,
  String? myName,
}) => {
  'state': {
    'events': [
      _state('m.room.create', {'creator': _me}),
      _state('m.room.member', {
        'membership': 'join',
        'displayname': ?myName,
      }, key: _me),
      if (withAda)
        {
          ..._state('m.room.member', {'membership': 'join'}, key: _ada),
          'sender': _ada,
        },
    ],
  },
  if (count != null)
    'summary': {'m.joined_member_count': count, 'm.invited_member_count': 0},
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

/// Push rules as a server holds them: a mention of you notifies, so does
/// a direct message, and so does any other message unless [message] is
/// off (the account's mentions only). A room in [mentionsOnly] keeps its
/// mentions, by a room rule; one in [muted] keeps nothing, by an override
/// rule, which the server ranks above its own mention rule.
Map<String, Object?> _pushRules({
  List<String> muted = const [],
  List<String> mentionsOnly = const [],
  bool message = true,
  bool displayName = false,
}) => {
  'type': 'm.push_rules',
  'content': {
    'global': {
      'override': [
        if (displayName)
          {
            'rule_id': '.m.rule.contains_display_name',
            'default': true,
            'enabled': true,
            'conditions': [
              {'kind': 'contains_display_name'},
            ],
            'actions': [
              'notify',
              {'set_tweak': 'highlight'},
            ],
          },
        for (final id in muted)
          {
            'rule_id': id,
            'default': false,
            'enabled': true,
            'conditions': [
              {'kind': 'event_match', 'key': 'room_id', 'pattern': id},
            ],
            'actions': <Object?>[],
          },
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
        for (final id in mentionsOnly)
          {
            'rule_id': id,
            'default': false,
            'enabled': true,
            'actions': <Object?>[],
          },
      ],
      'sender': <Object?>[],
      'underride': [
        {
          'rule_id': '.m.rule.room_one_to_one',
          'default': true,
          'enabled': true,
          'conditions': [
            {'kind': 'room_member_count', 'is': '2'},
            {'kind': 'event_match', 'key': 'type', 'pattern': 'm.room.message'},
          ],
          'actions': ['notify'],
        },
        {
          'rule_id': '.m.rule.message',
          'default': true,
          'enabled': message,
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

  /// Waits until the SDK has emitted [id], then for the arrivals' verdict
  /// on its sync.
  Future<void> reached(String id) async {
    await _until(() => seen.contains(id));
    expect(seen, contains(id));
    await Future<void>.delayed(Duration.zero);
    await arrivals.settled;
    // The verdict's arrival reaches listeners a beat after it is added.
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

    test('a room joined mid-session is quiet about its history', () async {
      final client = await _client();
      await _join(client);
      final rig = await _rig(client);
      const fresh = '!fresh:example.com';
      await _sync(
        client,
        rooms: {
          'join': {
            fresh: {
              'timeline': {
                'events': [
                  // Sent after launch but before you joined: history.
                  _msg(r'$before', ts: _after),
                  {
                    ..._state('m.room.member', {
                      'membership': 'join',
                    }, key: _me),
                    'origin_server_ts': _after + 1000,
                  },
                  _msg(r'$since', ts: _after + 2000),
                ],
                'limited': false,
                'prev_batch': 'p${_n++}',
              },
            },
          },
        },
      );
      await rig.reached(r'$since');
      expect(rig.seen, contains(r'$before'));
      expect(rig.got.map((a) => a.eventId), [r'$since']);
    });

    test('a profile change is not a join', () async {
      final client = await _client();
      await _join(client);
      final rig = await _rig(client);
      await _deliver(client, [
        _msg(r'$ada1', ts: _after),
        {
          ..._state('m.room.member', {
            'membership': 'join',
            'displayname': 'New',
          }, key: _me),
          'origin_server_ts': _after + 500,
          'unsigned': {
            'prev_content': {'membership': 'join', 'displayname': 'Old'},
          },
        },
      ]);
      await rig.reached(r'$ada1');
      expect(rig.got.map((a) => a.eventId), [r'$ada1']);
      // Still after your real join: the profile change moved nothing.
      await _deliver(client, [_msg(r'$ada2', ts: _after + 200)]);
      await rig.reached(r'$ada2');
      expect(rig.got.map((a) => a.eventId), [r'$ada1', r'$ada2']);
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

    test('a mentions-only room is quiet but a mention in it chimes', () async {
      final client = await _client();
      await _join(client);
      // The SDK builds its evaluator from the `m.push_rules` account data
      // of a sync.
      await _sync(
        client,
        accountData: [
          _pushRules(mentionsOnly: [_general]),
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

    test('a muted room is quiet, mention or not', () async {
      final client = await _client();
      await _join(client);
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
      expect(rig.got, isEmpty);
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

    test('a direct message notifies under mentions only once its members are '
        'known', () async {
      final client = await _client();
      await _sync(
        client,
        rooms: {
          'join': {_dm: _directRoom(withAda: true)},
        },
        accountData: [_pushRules(message: false)],
      );
      final rig = await _rig(client);
      await _sync(
        client,
        rooms: {
          'join': {
            _dm: {
              'timeline': {
                'events': [_msg(r'$plain')],
                'limited': false,
                'prev_batch': 'p${_n++}',
              },
            },
          },
        },
      );
      await _until(() => rig.got.isNotEmpty);
      expect(rig.got.map((a) => a.eventId), [r'$plain']);
    });

    test('members the server refuses leave the rules to what is known, and are '
        'asked for again with the next message', () async {
      final api = _MembersLater();
      final client = await _client(api: api);
      await _sync(
        client,
        rooms: {
          'join': {_dm: _directRoom(withAda: false, count: null)},
        },
        accountData: [_pushRules(message: false)],
      );
      final rig = await _rig(client);
      await _sync(
        client,
        rooms: {
          'join': {
            _dm: {
              'timeline': {
                'events': [
                  _msg(r'$plain'),
                  _msg(
                    r'$mention',
                    mentions: {
                      'user_ids': [_me],
                    },
                  ),
                ],
                'limited': false,
                'prev_batch': 'p${_n++}',
              },
            },
          },
        },
      );
      await rig.reached(r'$mention');
      // One member known of two when the first message is judged: not a
      // direct message to the rules, so it stays quiet; the second message
      // asks again, and the mention gets through either way.
      expect(rig.got.map((a) => a.eventId), [r'$mention']);
      expect(api.asked, 2);

      await _sync(
        client,
        rooms: {
          'join': {
            _dm: {
              'timeline': {
                'events': [_msg(r'$again')],
                'limited': false,
                'prev_batch': 'p${_n++}',
              },
            },
          },
        },
      );
      await rig.reached(r'$again');
      // The list is whole now: no third ask, and a direct message again.
      expect(api.asked, 2);
      expect(rig.got.map((a) => a.eventId), [r'$mention', r'$again']);
    });

    test(
      'a direct message by the server\'s count asks for no member list',
      () async {
        final api = _MembersLater();
        final client = await _client(api: api);
        await _sync(
          client,
          rooms: {
            'join': {_dm: _directRoom(withAda: false)},
          },
          accountData: [_pushRules(message: false)],
        );
        final rig = await _rig(client);
        await _sync(
          client,
          rooms: {
            'join': {
              _dm: {
                'timeline': {
                  'events': [_msg(r'$plain')],
                  'limited': false,
                  'prev_batch': 'p${_n++}',
                },
              },
            },
          },
        );
        await rig.reached(r'$plain');
        expect(rig.got.map((a) => a.eventId), [r'$plain']);
        expect(api.asked, 0);
      },
    );

    test('a message deleted in the same sync does not notify', () async {
      final client = await _client();
      await _join(client);
      final rig = await _rig(client);
      await _deliver(client, [
        _msg(r'$gone'),
        {
          'type': 'm.room.redaction',
          'sender': _ada,
          'redacts': r'$gone',
          'content': <String, Object?>{},
          'event_id': r'$why',
          'origin_server_ts': _after + 1,
        },
      ]);
      await rig.reached(r'$why');
      expect(rig.got, isEmpty);
    });

    test('a room left and rejoined is judged afresh', () async {
      final client = await _client();
      await _sync(
        client,
        rooms: {
          'join': {_dm: _directRoom(withAda: true, myName: 'Mochi')},
        },
        accountData: [_pushRules(message: false, displayName: true)],
      );
      final rig = await _rig(client);
      await _sync(
        client,
        rooms: {
          'leave': {
            _dm: {
              'timeline': {
                'events': [
                  {
                    'type': 'm.room.member',
                    'state_key': _me,
                    'sender': _me,
                    'content': {'membership': 'leave'},
                    'event_id': r'$left',
                    'origin_server_ts': _after,
                  },
                ],
                'limited': false,
                'prev_batch': 'p${_n++}',
              },
            },
          },
        },
      );
      expect(client.getRoomById(_dm), isNull);
      // Rejoined: the SDK builds the room anew. Your join dates your
      // start in it, so the message comes after.
      await _sync(
        client,
        rooms: {
          'join': {_dm: _directRoom(withAda: true, myName: 'Mochi')},
        },
      );
      final room = client.getRoomById(_dm)!;
      await _sync(
        client,
        rooms: {
          'join': {
            _dm: {
              'timeline': {
                'events': [
                  {
                    'type': 'm.room.member',
                    'state_key': _me,
                    'sender': _me,
                    'content': {'membership': 'join', 'displayname': 'Mochi'},
                    'event_id': r'$rejoined',
                    'origin_server_ts': _after + 1000,
                  },
                  {
                    ..._msg(r'$named', ts: _after + 2000),
                    'content': {'msgtype': 'm.text', 'body': 'hi Mochi'},
                  },
                ],
                'limited': false,
                'prev_batch': 'p${_n++}',
              },
            },
          },
        },
      );
      await rig.reached(r'$named');
      // Your name in the body notifies only with your member event at hand
      // for the room object judged.
      expect(room.getState('m.room.member', _me), isNotNull);
      expect(rig.got.map((a) => a.eventId), [r'$named']);
    });

    test('a room left while its verdict waits does not notify', () async {
      final api = _MembersLater()
        ..refuseFirst = false
        ..hold = Completer();
      final client = await _client(api: api);
      await _sync(
        client,
        rooms: {
          'join': {_dm: _directRoom(withAda: false, count: null)},
        },
        accountData: [_pushRules()],
      );
      final rig = await _rig(client);
      await _sync(
        client,
        rooms: {
          'join': {
            _dm: {
              'timeline': {
                'events': [_msg(r'$plain')],
                'limited': false,
                'prev_batch': 'p${_n++}',
              },
            },
          },
        },
      );
      await _until(() => api.asked == 1);
      await _sync(
        client,
        rooms: {
          'leave': {
            _dm: {
              'timeline': {
                'events': [
                  {
                    'type': 'm.room.member',
                    'state_key': _me,
                    'sender': _me,
                    'content': {'membership': 'leave'},
                    'event_id': r'$left',
                    'origin_server_ts': _after + 1,
                  },
                ],
                'limited': false,
                'prev_batch': 'p${_n++}',
              },
            },
          },
        },
      );
      api.hold!.complete();
      await rig.reached(r'$plain');
      expect(rig.got, isEmpty);
    });

    test('a room you have just left does not notify', () async {
      final client = await _client();
      await _join(client);
      final rig = await _rig(client);
      // The SDK drops a known room from its list before it emits that
      // room's leave-section events, which then carry the evicted Room.
      await _sync(
        client,
        rooms: {
          'leave': {
            _general: {
              'timeline': {
                'events': [
                  {
                    'type': 'm.room.member',
                    'state_key': _me,
                    'sender': _me,
                    'content': {'membership': 'leave'},
                    'event_id': r'$left',
                    'origin_server_ts': _after,
                  },
                  _msg(r'$parting', ts: _after + 1000),
                ],
                'limited': false,
                'prev_batch': 'p${_n++}',
              },
            },
          },
        },
      );
      await rig.reached(r'$parting');
      expect(client.getRoomById(_general), isNull);
      expect(rig.got, isEmpty);
    });

    test('a room you only know as left does not notify', () async {
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

  group('what an arrival carries', () {
    /// Delivers [events] into #general and returns the one arrival.
    Future<Arrival> arriveOne(
      Client client,
      List<Map<String, Object?>> events,
      String id,
    ) async {
      final rig = await _rig(client);
      await _deliver(client, events);
      await _until(() => rig.got.isNotEmpty);
      expect(rig.got.map((a) => a.eventId), [id]);
      return rig.got.single;
    }

    Event event(Client client, String type, Map<String, Object?> content) =>
        Event.fromJson({
          'type': type,
          'sender': _ada,
          'content': content,
          'event_id': '\$e${_n++}',
          'origin_server_ts': _after,
        }, client.getRoomById(_general)!);

    test('an arrival carries the sender, their picture and the text', () async {
      final client = await _client();
      await _join(client);
      final a = await arriveOne(client, [
        {
          ..._state('m.room.member', {
            'membership': 'join',
            'displayname': 'Ada',
            'avatar_url': 'mxc://loaf.moe/ada',
          }, key: _ada),
          'sender': _ada,
          'origin_server_ts': _before,
        },
        {
          ..._msg(r'$hello'),
          'content': {'msgtype': 'm.text', 'body': 'hello **there**'},
        },
      ], r'$hello');
      expect(a.senderId, _ada);
      expect(a.senderName, 'Ada');
      expect(a.senderAvatar, const AvatarRef('mxc://loaf.moe/ada'));
      expect(a.kind, ArrivalKind.text);
      expect(a.text, 'hello there');
    });

    test('a reply carries its own text, not the quote', () async {
      final client = await _client();
      await _join(client);
      final a = await arriveOne(client, [
        {
          ..._msg(r'$reply'),
          'content': {
            'msgtype': 'm.text',
            'body': '> <@bob:example.com> earlier\n\nmy answer',
            'm.relates_to': {
              'm.in_reply_to': {'event_id': r'$earlier'},
            },
          },
        },
      ], r'$reply');
      expect(a.text, 'my answer');
    });

    test('an undecryptable message reads as encrypted', () async {
      final client = await _client();
      await _join(client);
      // A room rule makes the event notify whatever the default rules say
      // about encrypted events.
      await _sync(
        client,
        accountData: [
          {
            'type': 'm.push_rules',
            'content': {
              'global': {
                'room': [
                  {
                    'rule_id': _general,
                    'default': false,
                    'enabled': true,
                    'actions': ['notify'],
                  },
                ],
              },
            },
          },
        ],
      );
      final a = await arriveOne(client, [
        {
          'type': 'm.room.encrypted',
          'sender': _ada,
          'content': {
            'algorithm': 'm.megolm.v1.aes-sha2',
            'ciphertext': 'AwgAEnAv',
            'device_id': 'ADEVICE',
            'sender_key': 'senderkey',
            'session_id': 'nosuchsession',
          },
          'event_id': r'$secret',
          'origin_server_ts': _after,
        },
      ], r'$secret');
      expect(a.kind, ArrivalKind.encrypted);
    });

    test('pictures, stickers and files are told apart', () async {
      final client = await _client();
      await _join(client);
      ArrivalKind kind(String type, Map<String, Object?> c) =>
          arrivalKind(event(client, type, c));
      expect(
        kind('m.room.message', {'msgtype': 'm.image', 'body': 'x.png'}),
        ArrivalKind.picture,
      );
      expect(kind('m.sticker', {'body': 'wave'}), ArrivalKind.picture);
      expect(
        kind('m.room.message', {'msgtype': 'm.file', 'body': 'x.pdf'}),
        ArrivalKind.file,
      );
      expect(
        kind('m.room.message', {'msgtype': 'm.video', 'body': 'x.mp4'}),
        ArrivalKind.file,
      );
      expect(
        kind('m.room.message', {'msgtype': 'm.audio', 'body': 'x.ogg'}),
        ArrivalKind.file,
      );
      expect(
        kind('m.room.message', {'msgtype': 'm.notice', 'body': 'hi'}),
        ArrivalKind.text,
      );
    });
  });
}
