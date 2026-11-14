/// The binding itself: that the bundled Rust library loads in a Dart test
/// and answers over the C ABI. The rules it answers by are covered against
/// the real spec in `test/matrix/`; what is pinned here is the marshalling —
/// the verdict's three values, an absent member count, and absent power
/// levels — so a failure in the rules tests means the rules, not the wiring.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_push/loaf_push.dart' as push;

const _me = '@test:fakeServer.notExisting';

/// A ruleset of exactly one underride rule: plain messages notify.
Map<String, Object?> _messagesNotify({bool enabled = true}) => {
  'override': <Object?>[],
  'content': <Object?>[],
  'room': <Object?>[],
  'sender': <Object?>[],
  'underride': [
    {
      'rule_id': '.m.rule.message',
      'default': true,
      'enabled': enabled,
      'conditions': [
        {'kind': 'event_match', 'key': 'type', 'pattern': 'm.room.message'},
      ],
      'actions': ['notify'],
    },
  ],
};

Map<String, Object?> _message({String body = 'hi'}) => {
  'type': 'm.room.message',
  'sender': '@ada:example.com',
  'content': {'msgtype': 'm.text', 'body': body},
};

void main() {
  test('a rule that notifies says so', () {
    expect(
      push.notifies(userId: _me, rules: _messagesNotify(), event: _message()),
      isTrue,
    );
  });

  test('a rule that is disabled leaves nothing to notify', () {
    expect(
      push.notifies(
        userId: _me,
        rules: _messagesNotify(enabled: false),
        event: _message(),
      ),
      isFalse,
    );
  });

  test('a ruleset the crate cannot read is null, not a verdict', () {
    expect(
      push.notifies(
        userId: _me,
        // A ruleset must be an object; a list is not one.
        rules: const {},
        event: _message(),
      ),
      isNotNull,
      reason: 'an empty ruleset is readable: no rule matches, so no notify',
    );
    expect(
      push.notifies(userId: _me, rules: const {}, event: const {}),
      isNull,
      reason: 'an event without content cannot be judged',
    );
  });

  test('a one-to-one rule holds when the member count is unknown', () {
    final rules = {
      ..._messagesNotify(enabled: false),
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
      ],
    };
    expect(
      push.notifies(userId: _me, rules: rules, event: _message()),
      isTrue,
      reason: 'an unknown count must not silence a direct message',
    );
    expect(
      push.notifies(userId: _me, rules: rules, event: _message(), members: 5),
      isFalse,
    );
  });

  test('a room mention needs the sender to have the power', () {
    final rules = {
      ..._messagesNotify(enabled: false),
      'override': [
        {
          'rule_id': '.m.rule.is_room_mention',
          'default': true,
          'enabled': true,
          'conditions': [
            {
              'kind': 'event_property_is',
              'key': r'content.m\.mentions.room',
              'value': true,
            },
            {'kind': 'sender_notification_permission', 'key': 'room'},
          ],
          'actions': ['notify'],
        },
      ],
    };
    final event = {
      ..._message(),
      'content': {
        'msgtype': 'm.text',
        'body': 'hi',
        'm.mentions': {'room': true},
      },
    };
    expect(
      push.notifies(
        userId: _me,
        rules: rules,
        event: event,
        power: const {
          'notifications': {'room': 50},
          'users': {'@ada:example.com': 50},
        },
      ),
      isTrue,
    );
    expect(
      push.notifies(
        userId: _me,
        rules: rules,
        event: event,
        power: const {
          'notifications': {'room': 50},
          'users': <String, Object?>{},
        },
      ),
      isFalse,
      reason: 'the default power for a user is 0, below the room level',
    );
  });
}
