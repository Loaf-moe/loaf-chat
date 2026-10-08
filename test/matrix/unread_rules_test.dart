import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:loaf_native/matrix/unread_rules.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _me = '@me:example.com';
var _n = 0;
// The SDK's Client wants a database; an in-memory one serves every room.
late Client _client;

Room _room({int? roomNotify, Map<String, int> users = const {}}) {
  final room = Room(id: '!r:example.com', client: _client);
  room.setState(
    Event(
      type: EventTypes.RoomPowerLevels,
      stateKey: '',
      senderId: _me,
      eventId: '\$pl',
      originServerTs: DateTime(2026),
      room: room,
      content: {
        'users': users,
        if (roomNotify != null) 'notifications': {'room': roomNotify},
      },
    ),
  );
  return room;
}

Event _event(
  Room room, {
  String type = EventTypes.Message,
  Map<String, Object?> content = const {'msgtype': 'm.text', 'body': 'hi'},
  String sender = '@ada:example.com',
  String? stateKey,
  Map<String, Object?>? unsigned,
}) => Event(
  type: type,
  content: content,
  senderId: sender,
  stateKey: stateKey,
  eventId: '\$e${_n++}',
  originServerTs: DateTime(2026),
  room: room,
  unsigned: unsigned,
);

Map<String, Object?> _text(String body, {Object? mentions}) => {
  'msgtype': 'm.text',
  'body': body,
  'm.mentions': ?mentions,
};

void main() {
  setUpAll(() async {
    _client = await openClient(databasePath: inMemoryDatabasePath);
  });
  tearDownAll(() => _client.dispose());

  group('countsAsMessage', () {
    test('a message and a sticker count', () {
      final room = _room();
      expect(countsAsMessage(_event(room)), isTrue);
      expect(
        countsAsMessage(
          _event(room, type: EventTypes.Sticker, content: {'body': 's'}),
        ),
        isTrue,
      );
    });

    test('an edit, a reaction and state do not', () {
      final room = _room();
      expect(
        countsAsMessage(
          _event(
            room,
            content: {
              'msgtype': 'm.text',
              'body': '* hi',
              'm.relates_to': {'rel_type': 'm.replace', 'event_id': r'$x'},
            },
          ),
        ),
        isFalse,
      );
      expect(
        countsAsMessage(
          _event(
            room,
            type: EventTypes.Reaction,
            content: {
              'm.relates_to': {
                'rel_type': 'm.annotation',
                'event_id': r'$x',
                'key': '👍',
              },
            },
          ),
        ),
        isFalse,
      );
      expect(
        countsAsMessage(
          _event(room, type: EventTypes.RoomTopic, content: {'topic': 't'}),
        ),
        isFalse,
      );
    });

    test(
      'an encrypted message counts; an encrypted edit or reaction does not',
      () {
        final room = _room();
        expect(
          countsAsMessage(
            _event(
              room,
              type: EventTypes.Encrypted,
              content: {'ciphertext': 'x'},
            ),
          ),
          isTrue,
        );
        expect(
          countsAsMessage(
            _event(
              room,
              type: EventTypes.Encrypted,
              content: {
                'ciphertext': 'x',
                'm.relates_to': {'rel_type': 'm.replace', 'event_id': r'$x'},
              },
            ),
          ),
          isFalse,
        );
      },
    );

    test('a deleted message does not', () {
      final room = _room();
      expect(
        countsAsMessage(
          _event(
            room,
            unsigned: {
              'redacted_because': {
                'type': 'm.room.redaction',
                'sender': '@ada:example.com',
              },
            },
          ),
        ),
        isFalse,
      );
    });
  });

  group('mentionsMe', () {
    test('m.mentions naming you is a mention', () {
      final room = _room();
      final event = _event(
        room,
        content: _text(
          'hey',
          mentions: {
            'user_ids': [_me],
          },
        ),
      );
      expect(mentionsMe(event, userId: _me, displayName: 'Me'), isTrue);
    });

    test('m.mentions decides alone: a name in the body is not a mention', () {
      final room = _room();
      final event = _event(
        room,
        content: _text('Me, look', mentions: <String, Object?>{}),
      );
      expect(mentionsMe(event, userId: _me, displayName: 'Me'), isFalse);
    });

    test('@room counts from a sender with the power to notify the room', () {
      final room = _room(users: {'@ada:example.com': 50});
      final event = _event(
        room,
        content: _text('all', mentions: {'room': true}),
      );
      expect(mentionsMe(event, userId: _me), isTrue);
    });

    test('@room from a sender below the room level is not a mention', () {
      final room = _room(roomNotify: 75, users: {'@ada:example.com': 50});
      final event = _event(
        room,
        content: _text('all', mentions: {'room': true}),
      );
      expect(mentionsMe(event, userId: _me), isFalse);
    });

    test('without m.mentions, your name or id in the body is a mention', () {
      final room = _room();
      expect(
        mentionsMe(
          _event(room, content: _text('ask me later, Ada')),
          userId: _me,
          displayName: 'Ada',
        ),
        isTrue,
      );
      expect(
        mentionsMe(
          _event(room, content: _text('cc @me:example.com')),
          userId: _me,
        ),
        isTrue,
      );
    });

    test('a name inside another word is not a mention', () {
      final room = _room();
      expect(
        mentionsMe(
          _event(room, content: _text('Adamant')),
          userId: _me,
          displayName: 'Ada',
        ),
        isFalse,
      );
    });

    test(
      'without m.mentions, a legacy @room from a sender with power counts',
      () {
        final room = _room(users: {'@ada:example.com': 50});
        expect(
          mentionsMe(_event(room, content: _text('@room lunch')), userId: _me),
          isTrue,
        );
      },
    );

    test('a still-encrypted message mentions no one', () {
      final room = _room();
      final event = _event(
        room,
        type: EventTypes.Encrypted,
        content: {'ciphertext': 'x'},
      );
      expect(mentionsMe(event, userId: _me, displayName: 'Me'), isFalse);
    });
  });

  group('isOwnJoin', () {
    Event member(Room room, String membership, {String? was}) => _event(
      room,
      type: EventTypes.RoomMember,
      content: {'membership': membership},
      stateKey: _me,
      unsigned: {
        if (was != null) 'prev_content': {'membership': was},
      },
    );

    test('your arrival is one, with or without a previous state', () {
      final room = _room();
      expect(isOwnJoin(member(room, 'join'), _me), isTrue);
      expect(isOwnJoin(member(room, 'join', was: 'invite'), _me), isTrue);
    });

    test('a change of name, a leave and someone else are not', () {
      final room = _room();
      expect(isOwnJoin(member(room, 'join', was: 'join'), _me), isFalse);
      expect(isOwnJoin(member(room, 'leave', was: 'join'), _me), isFalse);
      expect(isOwnJoin(member(room, 'join'), '@ada:example.com'), isFalse);
      expect(isOwnJoin(_event(room), _me), isFalse);
    });
  });
}
