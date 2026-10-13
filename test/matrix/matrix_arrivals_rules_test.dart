/// Arrivals against the push rules a server really holds: its defaults, the
/// account's channel default, and a room's own level. Every account level,
/// room level, room kind and way of mentioning you, in one table; then the
/// same through encryption; then the kinds of event the defaults silence.
///
/// What a case expects is the Matrix spec and Loaf's levels, not what the
/// SDK does today. A case the SDK fails is skipped by the finding it
/// confirms, until the fix commit unskips it.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:loaf_native/matrix/matrix_arrivals.dart';
import 'package:loaf_native/ui/model/arrival.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'crypto_harness.dart' show cryptoClient, me, other;

const _ada = '@ada:example.com';
const _bob = '@bob:example.com';
const _group = '!group:example.com';
const _dm = '!dm:example.com';

/// "Launch": the instant the shell opens. Messages are sent after it.
final _launch = DateTime.utc(2024, 1, 1, 12);
final _after = _launch.millisecondsSinceEpoch + 60000;

var _n = 0;

enum _Account { all, mentionsOnly, dnd }

enum _RoomRule { all, mentionsOnly, mute }

enum _Kind { group, dm, dmOpened }

enum _Mention {
  none,
  userIds,
  roomMention,
  roomMentionNoPower,
  bodyName,
  bodyLocalpart,
  bodyAtRoom,
  emptyMentionsNameInBody,
}

/// Whether the spec says a message of [mention] notifies, under these
/// levels, in this kind of room.
bool _expected(_Account account, _RoomRule rule, _Kind kind, _Mention mention) {
  if (account == _Account.dnd || rule == _RoomRule.mute) return false;
  // A message carrying `m.mentions` decides by it alone: an empty one
  // mentions nobody, whatever the body says.
  final mentioned = const {
    _Mention.userIds,
    _Mention.roomMention,
    _Mention.bodyName,
    _Mention.bodyLocalpart,
    _Mention.bodyAtRoom,
  }.contains(mention);
  if (rule == _RoomRule.mentionsOnly) return mentioned;
  // A DM notifies on its own underride rule, which mentions only leaves on.
  if (account == _Account.mentionsOnly) return mentioned || kind != _Kind.group;
  return true;
}

Future<Client> _client() async {
  final api = FakeMatrixApi();
  final client = await openClient(
    httpClient: api,
    databasePath: inMemoryDatabasePath,
  );
  FakeMatrixApi.client = client;
  await client.init(
    newToken: 'abcd',
    newHomeserver: Uri.parse('https://fakeServer.notExisting'),
    newUserID: me,
    newDeviceID: 'GHTYAJCE',
    newDeviceName: 'loaf on test',
    waitForFirstSync: true,
  );
  addTearDown(client.dispose);
  return client;
}

Map<String, Object?> _state(
  String type,
  Map<String, Object?> content, {
  String key = '',
  String sender = me,
}) => {
  'type': type,
  'state_key': key,
  'sender': sender,
  'content': content,
  'event_id': '\$s${_n++}',
  'origin_server_ts': 1700000000000,
};

/// A room with [members] joined (you first, named Mochi), where @room takes
/// power 50, which [_ada] has and [_bob] does not.
Map<String, Object?> _room(
  String name,
  List<String> members, {
  bool encrypted = false,
}) => {
  'state': {
    'events': [
      _state('m.room.create', {'creator': me}),
      _state('m.room.name', {'name': name}),
      _state('m.room.power_levels', {
        'users': {me: 100, _ada: 50},
        'users_default': 0,
        'notifications': {'room': 50},
      }),
      for (final id in members)
        _state(
          'm.room.member',
          {'membership': 'join', if (id == me) 'displayname': 'Mochi'},
          key: id,
          sender: id,
        ),
      if (encrypted)
        _state('m.room.encryption', {'algorithm': 'm.megolm.v1.aes-sha2'}),
    ],
  },
  'summary': {
    'm.joined_member_count': members.length,
    'm.invited_member_count': 0,
  },
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

/// Joins the room [kind] names, as an earlier sync left it. For
/// [_Kind.dmOpened] its members are loaded too, as showing them does: a
/// room nobody has looked at this session keeps none in memory.
Future<String> _join(Client client, _Kind kind) async {
  final id = kind == _Kind.group ? _group : _dm;
  await _sync(
    client,
    rooms: {
      'join': {
        id: _room(kind == _Kind.group ? 'general' : 'Ada', [
          me,
          _ada,
          if (kind == _Kind.group) _bob,
        ]),
      },
    },
    accountData: [
      if (kind != _Kind.group)
        {
          'type': 'm.direct',
          'content': {
            _ada: [_dm],
          },
        },
    ],
  );
  if (kind == _Kind.dmOpened) {
    await client.getRoomById(id)!.requestParticipants([Membership.join]);
  }
  return id;
}

Future<void> _deliver(
  Client client,
  String roomId,
  List<Map<String, Object?>> events,
) => _sync(
  client,
  rooms: {
    'join': {
      roomId: {
        'timeline': {
          'events': events,
          'limited': false,
          'prev_batch': 'p${_n++}',
        },
      },
    },
  },
);

Map<String, Object?> _msg(
  String id, {
  String sender = _ada,
  String body = 'hi',
  String msgtype = 'm.text',
  String type = 'm.room.message',
  Map<String, Object?>? mentions,
  Map<String, Object?> extra = const {},
}) => {
  'type': type,
  'sender': sender,
  'content': {
    'msgtype': msgtype,
    'body': body,
    'm.mentions': ?mentions,
    ...extra,
  },
  'event_id': id,
  'origin_server_ts': _after,
};

Map<String, Object?> _mentioning(_Mention mention, String id) =>
    switch (mention) {
      _Mention.none => _msg(id),
      _Mention.userIds => _msg(
        id,
        mentions: {
          'user_ids': [me],
        },
      ),
      _Mention.roomMention => _msg(id, mentions: {'room': true}),
      _Mention.roomMentionNoPower => _msg(
        id,
        sender: _bob,
        mentions: {'room': true},
      ),
      _Mention.bodyName => _msg(id, body: 'hi Mochi'),
      _Mention.bodyLocalpart => _msg(id, body: 'hi test'),
      _Mention.bodyAtRoom => _msg(id, body: '@room hi'),
      _Mention.emptyMentionsNameInBody => _msg(
        id,
        body: 'hi Mochi',
        mentions: {},
      ),
    };

Map<String, Object?> _rule(
  String id,
  List<Map<String, Object?>> conditions,
  List<Object?> actions, {
  bool enabled = true,
  bool isDefault = true,
  String? pattern,
}) => {
  'rule_id': id,
  'default': isDefault,
  'enabled': enabled,
  'conditions': conditions,
  'actions': actions,
  'pattern': ?pattern,
};

Map<String, Object?> _match(String key, String pattern) => {
  'kind': 'event_match',
  'key': key,
  'pattern': pattern,
};

const _notify = ['notify'];
const _notifySound = [
  'notify',
  {'set_tweak': 'sound', 'value': 'default'},
];
const _highlight = [
  'notify',
  {'set_tweak': 'highlight'},
];
const _highlightSound = [
  'notify',
  {'set_tweak': 'sound', 'value': 'default'},
  {'set_tweak': 'highlight'},
];

/// The push rules a homeserver holds for you: its defaults (the spec's,
/// in Synapse's order, legacy body-mention rules included), the account's
/// channel default ([message] and [encrypted] on or off), do not disturb
/// ([master]), and rooms at their own level. User rules rank above the
/// server's, except the master rule.
Map<String, Object?> _serverRules({
  bool master = false,
  bool message = true,
  bool encrypted = true,
  List<String> muted = const [],
  List<String> mentionsOnly = const [],
}) => {
  'type': 'm.push_rules',
  'content': {
    'global': {
      'override': [
        _rule('.m.rule.master', [], [], enabled: master),
        for (final id in muted)
          _rule(id, [_match('room_id', id)], [], isDefault: false),
        _rule('.m.rule.suppress_notices', [
          _match('content.msgtype', 'm.notice'),
        ], []),
        _rule('.m.rule.invite_for_me', [
          _match('type', 'm.room.member'),
          _match('content.membership', 'invite'),
          _match('state_key', me),
        ], _notifySound),
        _rule('.m.rule.member_event', [_match('type', 'm.room.member')], []),
        _rule('.m.rule.is_user_mention', [
          {
            'kind': 'event_property_contains',
            'key': r'content.m\.mentions.user_ids',
            'value': me,
          },
        ], _highlightSound),
        _rule('.m.rule.contains_display_name', [
          {'kind': 'contains_display_name'},
        ], _highlightSound),
        _rule('.m.rule.is_room_mention', [
          {
            'kind': 'event_property_is',
            'key': r'content.m\.mentions.room',
            'value': true,
          },
          {'kind': 'sender_notification_permission', 'key': 'room'},
        ], _highlight),
        _rule('.m.rule.roomnotif', [
          _match('content.body', '@room'),
          {'kind': 'sender_notification_permission', 'key': 'room'},
        ], _highlight),
        _rule('.m.rule.tombstone', [
          _match('type', 'm.room.tombstone'),
          _match('state_key', ''),
        ], _highlight),
        _rule('.m.rule.reaction', [_match('type', 'm.reaction')], []),
        _rule('.m.rule.room.server_acl', [
          _match('type', 'm.room.server_acl'),
          _match('state_key', ''),
        ], []),
        _rule('.m.rule.suppress_edits', [
          {
            'kind': 'event_property_is',
            'key': r'content.m\.relates_to.rel_type',
            'value': 'm.replace',
          },
        ], []),
      ],
      'content': [
        _rule(
          '.m.rule.contains_user_name',
          [],
          _highlightSound,
          pattern: 'test',
        ),
      ],
      'room': [
        for (final id in mentionsOnly) _rule(id, [], [], isDefault: false),
      ],
      'sender': <Object?>[],
      'underride': [
        _rule(
          '.m.rule.call',
          [_match('type', 'm.call.invite')],
          [
            'notify',
            {'set_tweak': 'sound', 'value': 'ring'},
          ],
        ),
        _rule('.m.rule.encrypted_room_one_to_one', [
          {'kind': 'room_member_count', 'is': '2'},
          _match('type', 'm.room.encrypted'),
        ], _notifySound),
        _rule('.m.rule.room_one_to_one', [
          {'kind': 'room_member_count', 'is': '2'},
          _match('type', 'm.room.message'),
        ], _notifySound),
        _rule(
          '.m.rule.message',
          [_match('type', 'm.room.message')],
          _notify,
          enabled: message,
        ),
        _rule(
          '.m.rule.encrypted',
          [_match('type', 'm.room.encrypted')],
          _notify,
          enabled: encrypted,
        ),
      ],
    },
  },
};

/// The finding a case confirms while it fails, or null where it passes.
/// Its fix commit unskips it.
///
/// - F4: the SDK checks room rules before content rules; the spec says
///   content first, so a mentions-only room silences your localpart.
/// - F6: the SDK applies the legacy body rules to a message that carries
///   `m.mentions`; Synapse skips them, and so does Loaf's unread count.
String? _finding(
  _Account account,
  _RoomRule rule,
  _Kind kind,
  _Mention mention,
) {
  // F6 is a message that notifies when it should not; the rest are
  // messages that should notify and do not.
  if (mention == _Mention.emptyMentionsNameInBody &&
      account != _Account.dnd &&
      (rule == _RoomRule.mentionsOnly ||
          (account == _Account.mentionsOnly &&
              rule == _RoomRule.all &&
              kind == _Kind.group))) {
    return 'F6: the SDK applies legacy body rules beside m.mentions';
  }
  if (!_expected(account, rule, kind, mention)) return null;
  if (rule == _RoomRule.mentionsOnly && mention == _Mention.bodyLocalpart) {
    return 'F4: the SDK checks room rules before content rules';
  }
  return null;
}

Map<String, Object?> _rulesFor(_Account account, _RoomRule rule, String room) =>
    _serverRules(
      master: account == _Account.dnd,
      message: account != _Account.mentionsOnly,
      encrypted: account != _Account.mentionsOnly,
      muted: [if (rule == _RoomRule.mute) room],
      mentionsOnly: [if (rule == _RoomRule.mentionsOnly) room],
    );

/// The arrivals under test, collected, and every timeline event the SDK
/// emitted (so a test can tell "filtered" from "never delivered").
class _Rig {
  _Rig(this.client) : arrivals = MatrixArrivals(client, now: () => _launch) {
    _subs = [
      arrivals.stream.listen(got.add),
      // Subscribed after the arrivals' own, so it runs after them.
      client.onTimelineEvent.stream.listen((e) => seen.add(e.eventId)),
    ];
  }

  final Client client;
  final MatrixArrivals arrivals;
  final got = <Arrival>[];
  final seen = <String>[];
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

Future<_Rig> _rig(Client client) async {
  final rig = _Rig(client);
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
  group('rules', () {
    for (final account in _Account.values) {
      for (final rule in _RoomRule.values) {
        for (final kind in _Kind.values) {
          for (final mention in _Mention.values) {
            test(
              '${account.name} account, ${rule.name} room, '
              '${kind.name}, ${mention.name}',
              skip: _finding(account, rule, kind, mention),
              () async {
                final client = await _client();
                final room = await _join(client, kind);
                await _sync(
                  client,
                  accountData: [_rulesFor(account, rule, room)],
                );
                final rig = await _rig(client);
                await _deliver(client, room, [_mentioning(mention, r'$m')]);
                await rig.reached(r'$m');
                expect(
                  rig.got.map((a) => a.eventId),
                  _expected(account, rule, kind, mention) ? [r'$m'] : isEmpty,
                );
              },
            );
          }
        }
      }
    }
  });

  group('encryption', () {
    const kinds = [_Kind.group, _Kind.dm];
    const mentions = [_Mention.none, _Mention.userIds];
    const accounts = [_Account.all, _Account.mentionsOnly];

    /// You and @othertest, keys exchanged, both in the room [kind] names,
    /// encrypted; the message is sealed by them.
    Future<(Client, String, Map<String, Object?>)> sealed(
      _Kind kind,
      _Mention mention,
    ) async {
      final mine = await cryptoClient();
      final theirs = await cryptoClient(
        api: FakeMatrixApi.currentApi,
        asOther: true,
      );
      await theirs.updateUserDeviceKeys(additionalUsers: {me});
      final room = await _joinEncrypted(theirs, kind);
      await _joinEncrypted(mine, kind);
      final content = await theirs.encryption!.encryptGroupMessagePayload(
        room,
        {
          'msgtype': 'm.text',
          'body': 'hi',
          if (mention == _Mention.userIds)
            'm.mentions': {
              'user_ids': [me],
            },
        },
      );
      _keyOf(theirs, room, content);
      return (mine, room, content);
    }

    for (final account in accounts) {
      for (final kind in kinds) {
        for (final mention in mentions) {
          final rules = _rulesFor(
            account,
            _RoomRule.all,
            kind == _Kind.group ? _group : _dm,
          );
          final notifies = _expected(account, _RoomRule.all, kind, mention);
          // Unreadable, the mention is unseen: only the room's own rule for
          // encrypted messages can say yes.
          final sealedNotifies = account == _Account.all || kind != _Kind.group;
          test('${account.name} account, ${kind.name}, ${mention.name}: '
              'readable at once', () async {
            final (mine, room, content) = await sealed(kind, mention);
            await _sync(mine, accountData: [rules]);
            await _giveKey(mine, room, content);
            final rig = await _rig(mine);
            await _deliver(mine, room, [_sealedMsg(content, r'$m')]);
            await rig.reached(r'$m');
            expect(
              rig.got.map((a) => (a.eventId, a.kind, a.text)),
              notifies ? [(r'$m', ArrivalKind.text, 'hi')] : isEmpty,
            );
          });

          test('${account.name} account, ${kind.name}, ${mention.name}: '
              'no key here', () async {
            final (mine, room, content) = await sealed(kind, mention);
            await _sync(mine, accountData: [rules]);
            final rig = await _rig(mine);
            await _deliver(mine, room, [_sealedMsg(content, r'$m')]);
            await rig.reached(r'$m');
            expect(
              rig.got.map((a) => (a.eventId, a.kind)),
              sealedNotifies ? [(r'$m', ArrivalKind.encrypted)] : isEmpty,
            );
          });

          test('${account.name} account, ${kind.name}, ${mention.name}: '
              'the key comes later', () async {
            final (mine, room, content) = await sealed(kind, mention);
            await _sync(mine, accountData: [rules]);
            final rig = await _rig(mine);
            await _deliver(mine, room, [_sealedMsg(content, r'$m')]);
            await rig.reached(r'$m');
            final before = rig.got.length;
            await _giveKey(mine, room, content);
            if (notifies) await _until(() => rig.got.length > before);
            final readable = rig.got.where((a) => a.kind == ArrivalKind.text);
            expect(
              readable.map((a) => (a.eventId, a.text)),
              notifies ? [(r'$m', 'hi')] : isEmpty,
            );
          });
        }
      }
    }
  });

  group('other events', () {
    Future<(Client, _Rig)> ready() async {
      final client = await _client();
      await _join(client, _Kind.group);
      await _sync(client, accountData: [_serverRules()]);
      return (client, await _rig(client));
    }

    test('a notice does not notify', () async {
      final (client, rig) = await ready();
      await _deliver(client, _group, [_msg(r'$n', msgtype: 'm.notice')]);
      await rig.reached(r'$n');
      expect(rig.got, isEmpty);
    });

    test('an edit does not notify', () async {
      final (client, rig) = await ready();
      await _deliver(client, _group, [
        _msg(r'$orig'),
        _msg(
          r'$edit',
          body: '* hello',
          extra: {
            'm.new_content': {'msgtype': 'm.text', 'body': 'hello'},
            'm.relates_to': {'rel_type': 'm.replace', 'event_id': r'$orig'},
          },
        ),
      ]);
      await rig.reached(r'$edit');
      expect(rig.got.map((a) => a.eventId), [r'$orig']);
    });

    test('a deleted message does not notify', () async {
      final (client, rig) = await ready();
      await _deliver(client, _group, [
        {
          ..._msg(r'$gone'),
          'unsigned': {
            'redacted_because': {
              'type': 'm.room.redaction',
              'sender': _ada,
              'redacts': r'$gone',
              'event_id': r'$why',
              'origin_server_ts': _after,
              'content': <String, Object?>{},
            },
          },
        },
      ]);
      await rig.reached(r'$gone');
      expect(rig.got, isEmpty);
    });

    test('a tombstone does not notify', () async {
      final (client, rig) = await ready();
      await _deliver(client, _group, [
        {
          ..._state('m.room.tombstone', {
            'body': 'moved',
            'replacement_room': '!new:example.com',
          }, sender: _ada),
          'event_id': r'$stone',
          'origin_server_ts': _after,
        },
      ]);
      await rig.reached(r'$stone');
      expect(rig.got, isEmpty);
    });

    test('an invite for you does not notify', () async {
      final (client, rig) = await ready();
      await _sync(
        client,
        rooms: {
          'invite': {
            '!new:example.com': {
              'invite_state': {
                'events': [
                  {
                    'type': 'm.room.member',
                    'state_key': me,
                    'sender': _ada,
                    'content': {'membership': 'invite'},
                  },
                ],
              },
            },
          },
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(rig.got, isEmpty);
    });
  });
}

/// Joins [client] to the encrypted room [kind] names, with @othertest as
/// the other member.
Future<String> _joinEncrypted(Client client, _Kind kind) async {
  final id = kind == _Kind.group ? _group : _dm;
  await _sync(
    client,
    rooms: {
      'join': {
        id: _room(kind == _Kind.group ? 'general' : 'Other', [
          me,
          other,
          if (kind == _Kind.group) _bob,
        ], encrypted: true),
      },
    },
    accountData: [
      if (kind != _Kind.group)
        {
          'type': 'm.direct',
          'content': {
            other: [_dm],
          },
        },
    ],
  );
  return id;
}

Map<String, Object?> _sealedMsg(Map<String, Object?> content, String id) => {
  'type': EventTypes.Encrypted,
  'sender': other,
  'content': content,
  'event_id': id,
  'origin_server_ts': _after,
};

/// The room key each sealed message was made under, and the sealer's
/// identity key, so [_giveKey] needs only the receiving client.
final _keys = <String, (String, String)>{};

void _keyOf(Client theirs, String room, Map<String, Object?> content) {
  final sessionId = content['session_id'] as String;
  _keys[sessionId] = (
    theirs.encryption!.keyManager
        .getInboundGroupSession(room, sessionId)!
        .inboundGroupSession!
        .exportAtFirstKnownIndex(),
    theirs.identityKey,
  );
}

/// Hands [mine] the key for [content], as a forwarded key or key backup
/// would.
Future<void> _giveKey(
  Client mine,
  String room,
  Map<String, Object?> content,
) async {
  final sessionId = content['session_id'] as String;
  final (sessionKey, senderKey) = _keys[sessionId]!;
  await mine.encryption!.keyManager.setInboundGroupSession(
    room,
    sessionId,
    senderKey,
    {
      'algorithm': AlgorithmTypes.megolmV1AesSha2,
      'room_id': room,
      'session_id': sessionId,
      'session_key': sessionKey,
    },
    forwarded: true,
  );
  await Future<void>.delayed(const Duration(milliseconds: 100));
}
