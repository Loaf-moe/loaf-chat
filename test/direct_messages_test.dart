import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/home/direct_messages.dart';
import 'package:loaf_native/ui/mock/fixtures.dart';

const _ana = Member('@ana', 'Ana Levain', Colors.blue);
const _bo = Member('@bo', 'Bo Rye', Colors.green);
const _cy = Member('@cy', 'Cy Crumb', Colors.orange);

Channel _dm(
  String id,
  List<Member> members, {
  int daysAgo = 0,
  int unread = 0,
  String? name,
}) => Channel(
  id: id,
  name: name ?? members.first.name,
  kind: ChannelKind.direct,
  members: members,
  unread: unread,
  lastActivity: DateTime(2026, 9, 24).subtract(Duration(days: daysAgo)),
);

void main() {
  group('collapseDuplicates', () {
    test('keeps one row per person: the newest room, with every unread', () {
      final rows = collapseDuplicates([
        _dm('ana-old', [_ana], daysAgo: 40, unread: 2),
        _dm('ana-new', [_ana], daysAgo: 1, unread: 1),
        _dm('bo', [_bo]),
      ]);

      expect(rows.map((r) => r.id), ['ana-new', 'bo']);
      final ana = rows.first;
      expect(ana.unread, 3);
      expect(ana.earlier.map((r) => r.id), ['ana-old']);
    });

    test('leaves group DMs and rooms alone', () {
      final rows = collapseDuplicates([
        _dm('g1', [_ana, _bo]),
        _dm('g2', [_ana, _bo]),
        const Channel(id: 'r', name: 'r', kind: ChannelKind.room),
      ]);

      expect(rows.map((r) => r.id), ['g1', 'g2', 'r']);
    });
  });

  group('startMessage', () {
    final dms = [
      _dm('ana-old', [_ana], daysAgo: 40),
      _dm('ana-new', [_ana], daysAgo: 1),
      _dm('crew', [_ana, _bo], name: 'the crew'),
    ];

    test('one person you already talk to opens the newest room', () {
      final start = startMessage([_ana], dms);

      expect(start, isA<OpenExisting>());
      expect((start as OpenExisting).room.id, 'ana-new');
      expect(start.label, 'open');
    });

    test('one new person is a new message', () {
      final start = startMessage([_cy], dms);

      expect(start, isA<CreateDirect>());
      expect(start!.label, 'message');
    });

    test('exactly the people of a group DM open it, in any order', () {
      final start = startMessage([_bo, _ana], dms);

      expect((start as OpenExisting).room.id, 'crew');
      expect(start.label, 'open the crew');
    });

    test('a new set of people starts a group', () {
      final start = startMessage([_ana, _bo, _cy], dms);

      expect(start, isA<CreateDirect>());
      expect(start!.label, 'start group');
    });

    test('nobody picked, nothing to do', () {
      expect(startMessage([], dms), isNull);
    });
  });

  group('existingWith', () {
    test("lists a person's 1:1 rooms, newest first, and no groups", () {
      final rooms = existingWith(_ana, [
        _dm('ana-old', [_ana], daysAgo: 40),
        _dm('crew', [_ana, _bo]),
        _dm('ana-new', [_ana], daysAgo: 1),
      ]);

      expect(rooms.map((r) => r.id), ['ana-new', 'ana-old']);
    });
  });

  test('activeLabel speaks in days', () {
    final now = DateTime(2026, 9, 24, 12);
    expect(activeLabel(DateTime(2026, 9, 24, 8), now), 'active today');
    expect(activeLabel(DateTime(2026, 9, 23, 20), now), 'active yesterday');
    expect(activeLabel(DateTime(2026, 9, 21), now), 'active 3 days ago');
  });
}
