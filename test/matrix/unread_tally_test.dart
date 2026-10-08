import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/matrix/unread_tally.dart';

void main() {
  test('counts entries and mentions; an entry twice counts once', () {
    final tally = RoomTally()
      ..add(const TallyEntry(r'$a', 1))
      ..add(const TallyEntry(r'$b', 2, mention: true))
      ..add(const TallyEntry(r'$b', 2, mention: true));
    expect(tally.count, 2);
    expect(tally.mentions, 1);
    expect(tally.isEmpty, isFalse);
  });

  test('a receipt on a counted event reads it and everything before', () {
    final tally = RoomTally()
      ..add(const TallyEntry(r'$a', 1))
      ..add(const TallyEntry(r'$b', 2))
      ..add(const TallyEntry(r'$c', 3));
    expect(tally.readUpTo(r'$b', 0), isTrue);
    expect(tally.entries.map((e) => e.id), [r'$c']);
  });

  test('a receipt on an event never counted reads by time', () {
    // Read on another device, on a reaction or your own message.
    final tally = RoomTally()
      ..add(const TallyEntry(r'$a', 10))
      ..add(const TallyEntry(r'$b', 20))
      ..add(const TallyEntry(r'$c', 30));
    expect(tally.readUpTo(r'$elsewhere', 20), isTrue);
    expect(tally.entries.map((e) => e.id), [r'$c']);
  });

  test('a receipt older than everything changes nothing', () {
    final tally = RoomTally()..add(const TallyEntry(r'$a', 10));
    expect(tally.readUpTo(r'$old', 5), isFalse);
    expect(tally.count, 1);
  });

  test('past 99 the oldest drop and the count reads as more than 99', () {
    final tally = RoomTally();
    for (var i = 0; i < 120; i++) {
      tally.add(TallyEntry('\$e$i', i));
    }
    expect(tally.entries, hasLength(RoomTally.cap));
    expect(tally.capped, isTrue);
    expect(tally.count, RoomTally.cap + 1);
  });

  test('a receipt inside a capped tally uncaps it', () {
    final tally = RoomTally();
    for (var i = 0; i < 120; i++) {
      tally.add(TallyEntry('\$e$i', i));
    }
    tally.readUpTo(r'$e110', 0);
    expect(tally.capped, isFalse);
    expect(tally.count, 9);
  });

  test('a receipt before a capped tally leaves it capped', () {
    final tally = RoomTally(capped: true)..add(const TallyEntry(r'$a', 10));
    expect(tally.readUpTo(r'$old', 5), isFalse);
    expect(tally.capped, isTrue);
  });

  test('a receipt on an empty capped tally uncaps it', () {
    // Everything counted was read; a receipt newer than all of it leaves
    // nothing older unread either.
    final tally = RoomTally(capped: true);
    expect(tally.readUpTo(r'$elsewhere', 5), isTrue);
    expect(tally.capped, isFalse);
    expect(tally.isEmpty, isTrue);
  });

  test('clear empties and uncaps; remove drops one deleted message', () {
    final tally = RoomTally(capped: true)
      ..add(const TallyEntry(r'$a', 1))
      ..add(const TallyEntry(r'$b', 2));
    expect(tally.remove(r'$a'), isTrue);
    expect(tally.remove(r'$missing'), isFalse);
    expect(tally.entries.map((e) => e.id), [r'$b']);
    tally.clear();
    expect(tally.isEmpty, isTrue);
    expect(tally.count, 0);
  });

  test('replace swaps an entry in place, for a message read late', () {
    final tally = RoomTally()
      ..add(const TallyEntry(r'$a', 1, locked: true))
      ..add(const TallyEntry(r'$b', 2));
    expect(tally.replace(const TallyEntry(r'$a', 1, mention: true)), isTrue);
    expect(tally.mentions, 1);
    expect(tally.entries.first.locked, isFalse);
    expect(tally.replace(const TallyEntry(r'$zz', 1)), isFalse);
  });

  test('survives JSON', () {
    final tally = RoomTally(capped: true)
      ..add(const TallyEntry(r'$a', 1, mention: true, locked: true));
    final back = RoomTally.fromJson(tally.toJson());
    expect(back.capped, isTrue);
    expect(back.entries.single.id, r'$a');
    expect(back.entries.single.ts, 1);
    expect(back.entries.single.mention, isTrue);
    expect(back.entries.single.locked, isTrue);
  });

  test('a locked entry keeps its session through JSON', () {
    final tally = RoomTally()
      ..add(const TallyEntry(r'$a', 1, locked: true, session: 's1'));
    final json = tally.toJson();
    expect((json['e']! as List).single, [r'$a', 1, false, 's1']);
    final back = RoomTally.fromJson(json).entries.single;
    expect(back.locked, isTrue);
    expect(back.session, 's1');
  });

  test('a file from before sessions loads locked, session unknown', () {
    final back = RoomTally.fromJson({
      'e': [
        [r'$a', 1, false, true],
      ],
    }).entries.single;
    expect(back.locked, isTrue);
    expect(back.session, isNull);
    // And writes back the way it came.
    expect(back.toJson(), [r'$a', 1, false, true]);
  });

  test('an unlocked entry has no session in its JSON', () {
    const entry = TallyEntry(r'$a', 1, mention: true);
    expect(entry.toJson(), [r'$a', 1, true]);
    final back = TallyEntry.fromJson(entry.toJson());
    expect(back.locked, isFalse);
    expect(back.session, isNull);
  });

  test('lockedUnder takes the locked entries a key could open', () {
    final tally = RoomTally()
      ..add(const TallyEntry(r'$open', 1))
      ..add(const TallyEntry(r'$one', 2, locked: true, session: 's1'))
      ..add(const TallyEntry(r'$two', 3, locked: true, session: 's2'))
      // From an older file: any key might open it.
      ..add(const TallyEntry(r'$old', 4, locked: true));
    expect(tally.lockedUnder({'s1'}).map((e) => e.id), [r'$one', r'$old']);
    expect(tally.lockedUnder({'s1', 's2'}).map((e) => e.id), [
      r'$one',
      r'$two',
      r'$old',
    ]);
    expect(tally.lockedUnder({'other'}).map((e) => e.id), [r'$old']);
  });
}
