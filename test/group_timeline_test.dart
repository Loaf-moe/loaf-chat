import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/mock/fixtures.dart';

const _a = Member('@a', 'Ada Crumb', Colors.purple);
const _b = Member('@b', 'Sam Poolish', Colors.blue);

Message _msg(
  Member author,
  DateTime at, {
  String body = 'hi',
  Message? replyTo,
}) => Message(
  id: '$author-$at-$body',
  author: author,
  sentAt: at,
  body: body,
  replyTo: replyTo,
);

DateTime _at(int day, int hour, int minute) =>
    DateTime(2026, 9, day, hour, minute);

void main() {
  test('empty timeline produces no entries', () {
    expect(groupTimeline([]), isEmpty);
  });

  test('a run from one author within the window is a single group', () {
    final entries = groupTimeline([
      _msg(_a, _at(1, 10, 0)),
      _msg(_a, _at(1, 10, 2)),
      _msg(_a, _at(1, 10, 4)),
    ]);

    expect(entries, hasLength(2));
    expect(entries.first, isA<DaySeparator>());
    expect((entries[1] as MessageGroup).messages, hasLength(3));
  });

  test('a different author starts a new group', () {
    final entries = groupTimeline([
      _msg(_a, _at(1, 10, 0)),
      _msg(_b, _at(1, 10, 1)),
      _msg(_a, _at(1, 10, 2)),
    ]);

    final groups = entries.whereType<MessageGroup>().toList();
    expect(groups, hasLength(3));
    expect(groups.map((g) => g.author.id), ['@a', '@b', '@a']);
  });

  test('a gap longer than the window breaks the group', () {
    final entries = groupTimeline([
      _msg(_a, _at(1, 10, 0)),
      _msg(_a, _at(1, 10, 5)), // exactly the window — still grouped
      _msg(_a, _at(1, 10, 11)), // six minutes later — broken
    ]);

    final groups = entries.whereType<MessageGroup>().toList();
    expect(groups, hasLength(2));
    expect(groups[0].messages, hasLength(2));
    expect(groups[1].messages, hasLength(1));
  });

  test('a reply always starts its own group', () {
    final target = _msg(_a, _at(1, 10, 0));
    final entries = groupTimeline([
      target,
      _msg(_a, _at(1, 10, 1), body: 'reply', replyTo: target),
    ]);

    final groups = entries.whereType<MessageGroup>().toList();
    expect(
      groups,
      hasLength(2),
      reason:
          'a reply tucked under its own '
          'target reads as if it has no context',
    );
  });

  test('each day gets one separator, and a day change breaks the group', () {
    final entries = groupTimeline([
      _msg(_a, _at(1, 23, 58)),
      _msg(_a, _at(2, 0, 1)), // three minutes later, but a new day
      _msg(_a, _at(2, 0, 2)),
    ]);

    expect(entries.whereType<DaySeparator>(), hasLength(2));
    final groups = entries.whereType<MessageGroup>().toList();
    expect(groups, hasLength(2));
    expect(groups[1].messages, hasLength(2));
  });

  test(
    'the fixture timeline groups into something a human would recognise',
    () {
      final entries = groupTimeline(mockTimeline());

      expect(entries.whereType<DaySeparator>(), hasLength(2));
      expect(entries.first, isA<DaySeparator>());
      // Mika's two consecutive messages collapse into one group.
      final mika = entries.whereType<MessageGroup>().first;
      expect(mika.author.name, 'Mika Rye');
      expect(mika.messages, hasLength(2));
    },
  );

  test('a call line stands alone, splitting the messages around it', () {
    final call = Message(
      id: 'call',
      author: _a,
      sentAt: _at(24, 10, 1),
      body: 'call · 12m',
      callLine: CallLine.ended,
    );
    final entries = groupTimeline([
      _msg(_a, _at(24, 10, 0)),
      call,
      _msg(_a, _at(24, 10, 2)),
    ]);

    expect(entries, hasLength(4));
    expect(entries[2], isA<CallEntry>());
    expect((entries[2] as CallEntry).message, call);
    expect((entries[3] as MessageGroup).messages, hasLength(1));
  });
}
