# Notifications A — Unread State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Unread bold, badges and the space pip follow the messages after your read receipt, counted by the client, independent of push rules, and correct on cold start and resume.

**Architecture:** Two pure units (`unread_rules.dart`: which events count and which mention you; `unread_tally.dart`: one room's ordered unread entries) under one stateful unit, `MatrixUnread`, which `MatrixRooms` owns. `MatrixUnread` applies each sync in order, fetches with `/messages` whenever local history can't be trusted (a limited sync, a room it has never counted), and persists its tallies to `unread.json` beside the media folder. `MatrixRooms._channel` reads counts from it instead of `notificationCount`/`highlightCount`. The UI stops letting mute hide bold, shows `99+`, and gives spaces a pip for unreads and a badge for mentions only.

**Tech Stack:** Flutter/Dart, `matrix` 13.0.0 SDK, `flutter_test` with the SDK's `FakeMatrixApi`.

**Spec:** `docs/superpowers/specs/2026-10-06-notifications-design.md` (section "A. Unread state")

## Global Constraints

- Unread state follows the messages. Mute and mentions-only affect sound and notifications only.
- Unread message: one from someone else after your read receipt, of a kind the timeline shows. Edits, reactions and state changes don't count.
- Mention: `m.mentions.user_ids` names you, or `m.mentions.room` from a sender allowed to notify the room. Without `m.mentions`, your display name or user id in the body (and a legacy `@room`). Encrypted messages are checked after decryption.
- Channel: bold when it has unreads, muted or not. Badge: unread count in a DM, mention count elsewhere.
- Space: a pip when any joined channel has unreads; a badge of total mentions; no unread count.
- Gaps are fetched with `/messages`, at most 99 counted events; at the cap the badge reads `99+`.
- Run tests with `mise exec -- flutter test <path>`. Encryption tests need vodozemac built once (README).
- Comments explain why, in the repo's voice: short declarative sentences, no "we".

## Review Focus

1. **A fresh install or first launch after this update** — every room has no tally. Rooms with new messages must show counts after the first fill, not zero. Pinned by Task 4's seed test.
2. **Reading on another device** — a receipt arriving by sync for an event the tally never saw (a reaction, your own message elsewhere) must clear everything sent before it. Pinned by Task 2's receipt-by-time test and Task 3's other-device test.
3. **A sync arriving while a fill is in flight** — messages that arrive during the fill must not be lost when the fill's result lands. Pinned by Task 4's in-flight test.
4. **The server failing a fill** (offline on resume) — counts keep their old value and the fill is retried on the next sync, not abandoned. Pinned by Task 4's retry test.
5. **Leaving a room** — its tally goes, so a rejoin doesn't resurrect stale counts, and `unread.json` doesn't grow forever. Pinned by Task 3's leave test.

---

### Task 1: Unread rules

**Files:**
- Create: `lib/matrix/unread_rules.dart`
- Test: `test/matrix/unread_rules_test.dart`

**Interfaces:**
- Produces: `bool countsAsMessage(Event event)`; `bool mentionsMe(Event event, {required String userId, String? displayName})`.

- [ ] **Step 1: Write the failing tests**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/matrix/unread_rules.dart';
import 'package:matrix/matrix.dart';

const _me = '@me:example.com';
var _n = 0;

Room _room({int? roomNotify, Map<String, int> users = const {}}) {
  final room = Room(id: '!r:example.com', client: Client('unread rules'));
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
  Map<String, Object?>? unsigned,
}) => Event(
  type: type,
  content: content,
  senderId: sender,
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
  group('countsAsMessage', () {
    test('a message and a sticker count', () {
      final room = _room();
      expect(countsAsMessage(_event(room)), isTrue);
      expect(
        countsAsMessage(_event(room, type: EventTypes.Sticker, content: {'body': 's'})),
        isTrue,
      );
    });

    test('an edit, a reaction and state do not', () {
      final room = _room();
      expect(
        countsAsMessage(
          _event(room, content: {
            'msgtype': 'm.text',
            'body': '* hi',
            'm.relates_to': {'rel_type': 'm.replace', 'event_id': r'$x'},
          }),
        ),
        isFalse,
      );
      expect(
        countsAsMessage(
          _event(room, type: EventTypes.Reaction, content: {
            'm.relates_to': {'rel_type': 'm.annotation', 'event_id': r'$x', 'key': '👍'},
          }),
        ),
        isFalse,
      );
      expect(
        countsAsMessage(_event(room, type: EventTypes.RoomTopic, content: {'topic': 't'})),
        isFalse,
      );
    });

    test('an encrypted message counts; an encrypted edit or reaction does not', () {
      final room = _room();
      expect(
        countsAsMessage(_event(room, type: EventTypes.Encrypted, content: {'ciphertext': 'x'})),
        isTrue,
      );
      expect(
        countsAsMessage(
          _event(room, type: EventTypes.Encrypted, content: {
            'ciphertext': 'x',
            'm.relates_to': {'rel_type': 'm.replace', 'event_id': r'$x'},
          }),
        ),
        isFalse,
      );
    });

    test('a deleted message does not', () {
      final room = _room();
      expect(
        countsAsMessage(
          _event(room, unsigned: {
            'redacted_because': {'type': 'm.room.redaction', 'sender': '@ada:example.com'},
          }),
        ),
        isFalse,
      );
    });
  });

  group('mentionsMe', () {
    test('m.mentions naming you is a mention', () {
      final room = _room();
      final event = _event(room, content: _text('hey', mentions: {'user_ids': [_me]}));
      expect(mentionsMe(event, userId: _me, displayName: 'Me'), isTrue);
    });

    test('m.mentions decides alone: a name in the body is not a mention', () {
      final room = _room();
      final event = _event(room, content: _text('Me, look', mentions: <String, Object?>{}));
      expect(mentionsMe(event, userId: _me, displayName: 'Me'), isFalse);
    });

    test('@room counts from a sender with the power to notify the room', () {
      final room = _room(users: {'@ada:example.com': 50});
      final event = _event(room, content: _text('all', mentions: {'room': true}));
      expect(mentionsMe(event, userId: _me), isTrue);
    });

    test('@room from a sender below the room level is not a mention', () {
      final room = _room(roomNotify: 75, users: {'@ada:example.com': 50});
      final event = _event(room, content: _text('all', mentions: {'room': true}));
      expect(mentionsMe(event, userId: _me), isFalse);
    });

    test('without m.mentions, your name or id in the body is a mention', () {
      final room = _room();
      expect(
        mentionsMe(_event(room, content: _text('ask me later, Ada')), userId: _me, displayName: 'Ada'),
        isTrue,
      );
      expect(
        mentionsMe(_event(room, content: _text('cc @me:example.com')), userId: _me),
        isTrue,
      );
    });

    test('a name inside another word is not a mention', () {
      final room = _room();
      expect(
        mentionsMe(_event(room, content: _text('Adamant')), userId: _me, displayName: 'Ada'),
        isFalse,
      );
    });

    test('without m.mentions, a legacy @room from a sender with power counts', () {
      final room = _room(users: {'@ada:example.com': 50});
      expect(mentionsMe(_event(room, content: _text('@room lunch')), userId: _me), isTrue);
    });

    test('a still-encrypted message mentions no one', () {
      final room = _room();
      final event = _event(room, type: EventTypes.Encrypted, content: {'ciphertext': 'x'});
      expect(mentionsMe(event, userId: _me, displayName: 'Me'), isFalse);
    });
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- flutter test test/matrix/unread_rules_test.dart`
Expected: FAIL — `unread_rules.dart` doesn't exist.

- [ ] **Step 3: Implement**

```dart
import 'package:matrix/matrix.dart';

/// Whether [event] is a message the timeline draws as a row of its own, and
/// so one that can be unread. The same test as `MatrixTimeline._message`:
/// deleted messages, edits, reactions and state are not messages. An
/// encrypted event counts before it is read, since its relation stays in
/// the clear and tells an edit or a reaction apart.
bool countsAsMessage(Event event) {
  if (event.redacted) return false;
  if (event.type == EventTypes.Encrypted) {
    return !const {
      RelationshipTypes.reaction,
      RelationshipTypes.edit,
    }.contains(event.relationshipType);
  }
  return const {EventTypes.Message, EventTypes.Sticker}.contains(event.type) &&
      event.relationshipType != RelationshipTypes.edit;
}

/// Whether [event] mentions you. `m.mentions` decides alone when a sender
/// includes it (intentional mentions); a message without it comes from an
/// older client, and falls back to your name or id in the body, the way
/// the default push rules do. A message still encrypted mentions no one
/// until it can be read.
bool mentionsMe(Event event, {required String userId, String? displayName}) {
  if (!const {EventTypes.Message, EventTypes.Sticker}.contains(event.type)) {
    return false;
  }
  final content = event.content;
  final mentions = content['m.mentions'];
  if (mentions is Map) {
    final ids = mentions['user_ids'];
    if (ids is List && ids.contains(userId)) return true;
    return mentions['room'] == true && _mayNotifyRoom(event);
  }
  final body = content.tryGet<String>('body') ?? '';
  if (_containsWord(body, '@room') && _mayNotifyRoom(event)) return true;
  final name = displayName?.trim();
  return _containsWord(body, userId) ||
      (name != null && name.isNotEmpty && _containsWord(body, name));
}

/// Whether the sender has the power level the room asks of `@room`, 50
/// unless the room says otherwise.
bool _mayNotifyRoom(Event event) {
  final room = event.room;
  final levels = room.getState(EventTypes.RoomPowerLevels)?.content;
  final notifications = levels?['notifications'];
  final needed = notifications is Map && notifications['room'] is int
      ? notifications['room'] as int
      : 50;
  return room.getPowerLevelByUserId(event.senderId).level >= needed;
}

/// [word] in [text] on its own, ignoring case: "Ada" is in "hi Ada!" but
/// not in "Adamant".
bool _containsWord(String text, String word) => RegExp(
  '(^|[^\\p{L}\\p{N}_])${RegExp.escape(word)}(\$|[^\\p{L}\\p{N}_])',
  caseSensitive: false,
  unicode: true,
).hasMatch(text);
```

- [ ] **Step 4: Run to verify it passes**

Run: `mise exec -- flutter test test/matrix/unread_rules_test.dart`
Expected: PASS. If `getPowerLevelByUserId(...).level` doesn't compile, check `PowerLevel` in `matrix-13.0.0/lib/src/room.dart:2211` (it's used as `.level` in `matrix_rooms.dart:_member`).

- [ ] **Step 5: Commit**

```bash
git add lib/matrix/unread_rules.dart test/matrix/unread_rules_test.dart
git commit -m "feat(unread): which events count as unread, and which mention you"
```

---

### Task 2: A room's tally

**Files:**
- Create: `lib/matrix/unread_tally.dart`
- Test: `test/matrix/unread_tally_test.dart`

**Interfaces:**
- Produces:
  - `class TallyEntry { const TallyEntry(this.id, this.ts, {this.mention = false, this.locked = false}); final String id; final int ts; final bool mention; final bool locked; }`
  - `class RoomTally` with `RoomTally({List<TallyEntry> entries, bool capped})`, `static const cap = 99`, `int get count` (`cap + 1` when capped), `int get mentions`, `bool get isEmpty`, `List<TallyEntry> get entries`, `bool capped`, `void add(TallyEntry)`, `bool readUpTo(String eventId, int ts)`, `void clear()`, `bool remove(String eventId)`, `bool replace(TallyEntry)`, `Map<String, Object?> toJson()`, `factory RoomTally.fromJson(Map<String, Object?>)`.

- [ ] **Step 1: Write the failing tests**

```dart
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
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- flutter test test/matrix/unread_tally_test.dart`
Expected: FAIL — `unread_tally.dart` doesn't exist.

- [ ] **Step 3: Implement**

```dart
/// One unread message: its id, when it was sent (ms since epoch), whether
/// it mentions you, and whether it was still encrypted when counted, so it
/// can be looked at again once its key arrives.
class TallyEntry {
  const TallyEntry(this.id, this.ts, {this.mention = false, this.locked = false});

  final String id;
  final int ts;
  final bool mention;
  final bool locked;

  List<Object> toJson() => [id, ts, if (mention || locked) mention, if (locked) locked];

  factory TallyEntry.fromJson(List<Object?> json) => TallyEntry(
    json[0]! as String,
    json[1]! as int,
    mention: json.length > 2 && json[2] == true,
    locked: json.length > 3 && json[3] == true,
  );
}

/// A room's unread messages, oldest first: every message from someone
/// else after your read receipt. At most [cap] are kept. Past that the
/// oldest drop and [capped] says there were more, which the badge shows as
/// `99+`.
class RoomTally {
  RoomTally({List<TallyEntry> entries = const [], this.capped = false})
    : _entries = [...entries];

  static const cap = 99;

  final List<TallyEntry> _entries;

  /// More unread messages than [cap] came before the first entry.
  bool capped;

  /// [cap] + 1 when capped: a number the badge draws as `99+`.
  int get count => capped ? cap + 1 : _entries.length;

  int get mentions => _entries.where((e) => e.mention).length;

  bool get isEmpty => _entries.isEmpty && !capped;

  List<TallyEntry> get entries => List.unmodifiable(_entries);

  void add(TallyEntry entry) {
    if (_entries.any((e) => e.id == entry.id)) return;
    _entries.add(entry);
    if (_entries.length > cap) {
      _entries.removeAt(0);
      capped = true;
    }
  }

  /// Your receipt is on [eventId], placed at [ts]. A counted event reads it
  /// and everything before it. An event never counted (a reaction, your
  /// own message, something read on another device) reads by time:
  /// whatever was sent by then. Whether anything changed.
  bool readUpTo(String eventId, int ts) {
    final before = _entries.length;
    final at = _entries.indexWhere((e) => e.id == eventId);
    if (at >= 0) {
      _entries.removeRange(0, at + 1);
    } else {
      _entries.removeWhere((e) => e.ts <= ts);
    }
    final changed = _entries.length != before;
    // The receipt landed inside what is counted, so nothing older is
    // unread any more.
    if (changed) capped = false;
    return changed;
  }

  void clear() {
    _entries.clear();
    capped = false;
  }

  /// A message deleted while unread. Whether it was counted.
  bool remove(String eventId) {
    final before = _entries.length;
    _entries.removeWhere((e) => e.id == eventId);
    return _entries.length != before;
  }

  /// Swaps the entry with [entry]'s id for [entry], in place. Whether there
  /// was one.
  bool replace(TallyEntry entry) {
    final at = _entries.indexWhere((e) => e.id == entry.id);
    if (at < 0) return false;
    _entries[at] = entry;
    return true;
  }

  Map<String, Object?> toJson() => {
    'e': [for (final e in _entries) e.toJson()],
    if (capped) 'capped': true,
  };

  factory RoomTally.fromJson(Map<String, Object?> json) => RoomTally(
    entries: [
      for (final e in json['e'] as List? ?? const [])
        TallyEntry.fromJson((e as List).cast<Object?>()),
    ],
    capped: json['capped'] == true,
  );
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `mise exec -- flutter test test/matrix/unread_tally_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/matrix/unread_tally.dart test/matrix/unread_tally_test.dart
git commit -m "feat(unread): a room's tally of unread messages, capped at 99"
```

---

### Task 3: Counting from sync, wired into the rooms

**Files:**
- Create: `lib/matrix/matrix_unread.dart`
- Modify: `lib/matrix/matrix_rooms.dart` (constructor, `_onSync`, `_channel`, `markRead`, `dispose`)
- Test: `test/matrix/matrix_rooms_test.dart` (helpers, a new `group('unread', ...)`, and the two count tests that read server numbers)

**Interfaces:**
- Consumes: `countsAsMessage`, `mentionsMe` (Task 1); `RoomTally`, `TallyEntry` (Task 2).
- Produces: `class MatrixUnread { MatrixUnread(Client client, {required void Function() onChange}); RoomTally of(String roomId); void apply(SyncUpdate update); Future<void> get idle; void dispose(); }`. Tasks 4–6 add to it. `of` returns an empty tally for a room it doesn't know.

- [ ] **Step 1: Add sync helpers to the test file**

In `test/matrix/matrix_rooms_test.dart`, below `_sync`:

```dart
/// A text message from [sender], [id] or a fresh one, sent at [ts] or a
/// fresh, later time.
Map<String, Object?> _msg(
  String body, {
  String sender = '@ada:example.com',
  String? id,
  int? ts,
  Map<String, Object?>? mentions,
}) => {
  'type': 'm.room.message',
  'sender': sender,
  'content': {'msgtype': 'm.text', 'body': body, 'm.mentions': ?mentions},
  'event_id': id ?? '\$m${_events++}',
  'origin_server_ts': ts ?? 1700000000000 + _events++ * 1000,
};

/// Your receipt on [eventId], placed at [ts].
Map<String, Object?> _receipt(String eventId, {required int ts}) => {
  'type': 'm.receipt',
  'content': {
    eventId: {
      'm.read': {
        _me: {'ts': ts},
      },
    },
  },
};

/// A sync of one joined room's new [timeline] events and [ephemeral]
/// events. [limited] says the server skipped some.
Future<void> _timeline(
  Client client,
  String roomId,
  List<Map<String, Object?>> timeline, {
  List<Map<String, Object?>> ephemeral = const [],
  bool limited = false,
}) => _sync(client, {
  'join': {
    roomId: {
      'timeline': {'events': timeline, 'limited': limited, 'prev_batch': 'p${_events++}'},
      'ephemeral': {'events': ephemeral},
    },
  },
});
```

- [ ] **Step 2: Write the failing tests**

Add to `main()`:

```dart
  group('unread', () {
    const general = '!general:example.com';

    // _Api, not the plain fake: muting needs its push-rules answers.
    Future<(Client, MatrixRooms)> bakery() async {
      final client = await _client(api: _Api());
      final rooms = await _rooms(client);
      await _bakery(client);
      await _settle();
      return (client, rooms);
    }

    Channel channel(MatrixRooms rooms, String id) => rooms.spaces
        .expand((s) => s.allChannels)
        .firstWhere((c) => c.id == id);

    test('messages from others count; the server\'s numbers do not', () async {
      final (client, rooms) = await bakery();
      // _bakery gives #general a notification_count of 3 and no messages.
      expect(channel(rooms, general).unread, 0);

      await _timeline(client, general, [_msg('one'), _msg('two')]);
      await _settle();
      expect(channel(rooms, general).unread, 2);
    });

    test('a mention counts toward mentions', () async {
      final (client, rooms) = await bakery();
      await _timeline(client, general, [
        _msg('hey', mentions: {'user_ids': [_me]}),
        _msg('chatter', mentions: <String, Object?>{}),
      ]);
      await _settle();
      expect(channel(rooms, general).unread, 2);
      expect(channel(rooms, general).mentions, 1);
    });

    test('a muted room still counts', () async {
      final (client, rooms) = await bakery();
      await rooms.setMuted(general, true);
      await _timeline(client, general, [_msg('one')]);
      await _settle();
      expect(channel(rooms, general).unread, 1);
    });

    test('your receipt reads what came before it', () async {
      final (client, rooms) = await bakery();
      await _timeline(client, general, [
        _msg('one', id: r'$one'),
        _msg('two', id: r'$two'),
        _msg('three', id: r'$three'),
      ]);
      await _timeline(client, general, const [], ephemeral: [_receipt(r'$two', ts: 0)]);
      await _settle();
      expect(channel(rooms, general).unread, 1);
    });

    test('read on another device, by time, on an event never counted', () async {
      final (client, rooms) = await bakery();
      await _timeline(client, general, [
        _msg('one', ts: 1000),
        _msg('two', ts: 2000),
      ]);
      await _timeline(client, general, const [], ephemeral: [
        _receipt(r'$reaction-elsewhere', ts: 2000),
      ]);
      await _settle();
      expect(channel(rooms, general).unread, 0);
    });

    test('your own message reads everything before it', () async {
      final (client, rooms) = await bakery();
      await _timeline(client, general, [_msg('one'), _msg('two')]);
      await _timeline(client, general, [_msg('mine', sender: _me)]);
      await _settle();
      expect(channel(rooms, general).unread, 0);
    });

    test('a message deleted while unread stops counting', () async {
      final (client, rooms) = await bakery();
      await _timeline(client, general, [_msg('oops', id: r'$oops')]);
      await _timeline(client, general, [
        {
          'type': 'm.room.redaction',
          'sender': '@ada:example.com',
          'redacts': r'$oops',
          'content': {'redacts': r'$oops'},
          'event_id': '\$r${_events++}',
          'origin_server_ts': 1700000000000 + _events++ * 1000,
        },
      ]);
      await _settle();
      expect(channel(rooms, general).unread, 0);
    });

    test('edits and reactions do not count', () async {
      final (client, rooms) = await bakery();
      await _timeline(client, general, [
        {
          'type': 'm.reaction',
          'sender': '@ada:example.com',
          'content': {
            'm.relates_to': {'rel_type': 'm.annotation', 'event_id': r'$x', 'key': '👍'},
          },
          'event_id': '\$x${_events++}',
          'origin_server_ts': 1700000000000 + _events++ * 1000,
        },
      ]);
      await _settle();
      expect(channel(rooms, general).unread, 0);
    });

    test('leaving a room forgets its count', () async {
      final (client, rooms) = await bakery();
      await _timeline(client, general, [_msg('one')]);
      await _sync(client, {
        'leave': {general: <String, Object?>{}},
      });
      await _settle();
      expect(rooms.unreadTally(general).isEmpty, isTrue);
    });

    test('mark as read is sent while something is unread', () async {
      final api = _Api();
      final client = await _client(api: api);
      final rooms = await _rooms(client);
      await _bakery(client);
      await _timeline(client, general, [_msg('one')]);
      await _settle();
      rooms.markRead(general);
      await _settle();
      expect(api.answered.where((p) => p.contains('read_markers')), isNotEmpty);
    });
  });
```

The leave test reads `rooms.unreadTally`, which Step 5 adds.

The mark-as-read test needs `_Api.mockIntercept` to record `read_markers` posts. If it doesn't already, add before the final `return super.mockIntercept(request);`:

```dart
    if (request.method == 'POST' && path.endsWith('/read_markers')) {
      answered.add(path);
      return http.Response('{}', 200);
    }
```

- [ ] **Step 3: Run to verify the new tests fail**

Run: `mise exec -- flutter test test/matrix/matrix_rooms_test.dart --name unread`
Expected: FAIL — counts still come from `notificationCount`; `unreadTally` is undefined.

- [ ] **Step 4: Implement `MatrixUnread`**

```dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import 'unread_rules.dart';
import 'unread_tally.dart';

/// Each joined room's unread messages, counted here rather than taken from
/// the server's push-rule numbers: those are zero in a muted or
/// mentions-only room, and blind to mentions in an encrypted one. Syncs are
/// applied one at a time, in order, since decrypting makes each one wait.
class MatrixUnread {
  MatrixUnread(this.client, {required this.onChange});

  final Client client;

  /// Called after counts change, outside any sync's own rebuild.
  final void Function() onChange;

  final _tallies = <String, RoomTally>{};
  Future<void> _queue = Future.value();
  var _disposed = false;

  RoomTally of(String roomId) => _tallies[roomId] ?? RoomTally();

  /// Completes once every sync handed to [apply] so far is counted.
  @visibleForTesting
  Future<void> get idle => _queue;

  void apply(SyncUpdate update) {
    _queue = _queue.then((_) => _apply(update)).catchError((Object e, StackTrace s) {
      Logs().w('[loaf] unread count failed', e, s);
    });
  }

  Future<void> _apply(SyncUpdate update) async {
    if (_disposed) return;
    var changed = false;
    for (final MapEntry(key: roomId, value: joined)
        in (update.rooms?.join ?? const <String, JoinedRoomUpdate>{}).entries) {
      final room = client.getRoomById(roomId);
      if (room == null) continue;
      final tally = _tallies.putIfAbsent(roomId, RoomTally.new);
      for (final raw in joined.timeline?.events ?? const <MatrixEvent>[]) {
        if (await _take(room, tally, Event.fromMatrixEvent(raw, room))) {
          changed = true;
        }
      }
      if (_readReceipt(room, tally)) changed = true;
    }
    for (final roomId in update.rooms?.leave?.keys ?? const <String>[]) {
      if (_tallies.remove(roomId) != null) changed = true;
    }
    if (changed && !_disposed) onChange();
  }

  /// Counts, uncounts or reads by one new timeline event. Whether the
  /// tally changed.
  Future<bool> _take(Room room, RoomTally tally, Event event) async {
    if (event.type == EventTypes.Redaction) {
      final redacts = event.redacts;
      return redacts != null && tally.remove(redacts);
    }
    if (!countsAsMessage(event)) return false;
    if (event.senderId == client.userID) {
      // Sending in a room reads it, as the server counts it too.
      final had = !tally.isEmpty;
      tally.clear();
      return had;
    }
    tally.add(await _entry(room, event));
    return true;
  }

  /// [event] as an unread entry: decrypted first where a key is here, so a
  /// mention in an encrypted room is seen.
  Future<TallyEntry> _entry(Room room, Event event) async {
    final shown = await _decrypted(event);
    final me = client.userID!;
    return TallyEntry(
      event.eventId,
      event.originServerTs.millisecondsSinceEpoch,
      mention: mentionsMe(
        shown,
        userId: me,
        displayName: room.unsafeGetUserFromMemoryOrFallback(me).calcDisplayname(),
      ),
      locked: shown.type == EventTypes.Encrypted,
    );
  }

  Future<Event> _decrypted(Event event) async {
    if (event.type != EventTypes.Encrypted) return event;
    final encryption = client.encryption;
    if (encryption == null) return event;
    try {
      return await encryption.decryptRoomEvent(event);
    } on Object {
      return event;
    }
  }

  bool _readReceipt(Room room, RoomTally tally) {
    final own = room.receiptState.global.latestOwnReceipt;
    return own != null && tally.readUpTo(own.eventId, own.ts);
  }

  void dispose() => _disposed = true;
}
```

If `JoinedRoomUpdate` isn't the type name in `matrix-13.0.0/lib/matrix_api_lite/model/sync_update.dart`, use the type of `RoomsUpdate.join`'s values.

- [ ] **Step 5: Wire it into `MatrixRooms`**

In `lib/matrix/matrix_rooms.dart`:

1. Import `'matrix_unread.dart'` and `'unread_tally.dart'`.
2. Add the field after `_hierarchy`:

```dart
  /// What is unread in each room, counted from the messages themselves.
  late final MatrixUnread _unread = MatrixUnread(
    client,
    onChange: () {
      if (!_disposed) _rebuild();
    },
  );

  @visibleForTesting
  RoomTally unreadTally(String roomId) => _unread.of(roomId);
```

3. In `_onSync`, before `_synced = true;`: `_unread.apply(update);`
4. In `_channel`, replace the two count lines:

```dart
      unread: tally.count,
      mentions: tally.mentions,
```

with `final tally = _unread.of(room.id);` declared beside `final topic = room.topic;`.
5. In `markRead`, replace `room.notificationCount == 0` with `_unread.of(roomId).isEmpty`.
6. In `dispose`, call `_unread.dispose();` beside the other teardown.

- [ ] **Step 6: Fix the tests that read server numbers**

The counts now come from messages, so in `test/matrix/matrix_rooms_test.dart`:

- In `'rooms in no space land in Home, a DM as a DM'`, delete `expect(dm.unread, 2);` and `expect(dm.mentions, 2);`. That test is about placement; counting is covered in `group('unread')`.
- In `'a channel carries its counts, topic and lock'`, rename it to `'a channel carries its topic and lock'` and delete the three `unread`/`mentions` expectations (`sourdough.unread`, `sourdough.mentions`, `rooms.spaces.last.mentions`).

- [ ] **Step 7: Run the whole rooms suite**

Run: `mise exec -- flutter test test/matrix/matrix_rooms_test.dart`
Expected: PASS. If a test outside `group('unread')` now fails on a count, it read the server's numbers; remove that expectation the same way and say so in the commit message.

- [ ] **Step 8: Commit**

```bash
git add lib/matrix/matrix_unread.dart lib/matrix/matrix_rooms.dart test/matrix/matrix_rooms_test.dart
git commit -m "feat(unread): count unread messages and mentions from sync, not push rules"
```

---

### Task 4: Filling gaps from the server

**Files:**
- Modify: `lib/matrix/matrix_unread.dart`
- Modify: `lib/matrix/matrix_rooms.dart` (seed after construction)
- Test: `test/matrix/matrix_rooms_test.dart` (`_Api` gets `/messages`; new tests in `group('unread')`)

**Interfaces:**
- Consumes: Task 3's `MatrixUnread`.
- Produces: `void MatrixUnread.seed()` — fills every joined room without a tally that `hasNewMessages`, and gives the rest empty tallies. `MatrixRooms` calls it once, after construction.

- [ ] **Step 1: Teach `_Api` to answer `/messages`**

Add to `_Api`:

```dart
  /// Each room's events, newest first, served by `/messages?dir=b` in
  /// pages of the request's `limit`. `from` is the index to start at.
  final roomHistory = <String, List<Map<String, Object?>>>{};

  /// How many `/messages` calls each room has had.
  final historyCalls = <String, int>{};

  /// While set, `/messages` fails with a server error.
  var failHistory = false;
```

and in `mockIntercept`, before the final `return super.mockIntercept(request);`:

```dart
    if (request.method == 'GET' && path.endsWith('/messages')) {
      final roomId = Uri.decodeComponent(path.split('/rooms/')[1].split('/messages')[0]);
      historyCalls[roomId] = (historyCalls[roomId] ?? 0) + 1;
      if (failHistory) {
        return http.Response(jsonEncode({'errcode': 'M_UNKNOWN', 'error': 'boom'}), 500);
      }
      final events = roomHistory[roomId] ?? const [];
      final from = int.tryParse(request.url.queryParameters['from'] ?? '') ?? 0;
      final limit = int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 10;
      final end = (from + limit).clamp(0, events.length);
      return http.Response(
        jsonEncode({
          'start': '$from',
          'chunk': events.sublist(from.clamp(0, events.length), end),
          if (end < events.length) 'end': '$end',
        }),
        200,
      );
    }
```

- [ ] **Step 2: Write the failing tests**

Inside `group('unread')`:

```dart
    test('a limited sync refetches the room from the server', () async {
      final api = _Api();
      final client = await _client(api: api);
      final rooms = await _rooms(client);
      await _bakery(client);
      api.roomHistory[general] = [
        _msg('newest'),
        _msg('newer'),
        _msg('read one', id: r'$read'),
        _msg('older'),
      ];
      await _timeline(client, general, const [], ephemeral: [_receipt(r'$read', ts: 0)]);
      await _timeline(client, general, [api.roomHistory[general]!.first], limited: true);
      await _settle();
      expect(channel(rooms, general).unread, 2);
    });

    test('history past 99 unread reads as more than 99', () async {
      final api = _Api();
      final client = await _client(api: api);
      final rooms = await _rooms(client);
      await _bakery(client);
      api.roomHistory[general] = [for (var i = 0; i < 150; i++) _msg('m$i')];
      await _timeline(client, general, [api.roomHistory[general]!.first], limited: true);
      await _settle();
      expect(channel(rooms, general).unread, RoomTally.cap + 1);
    });

    test('a failed fill keeps the count and tries again next sync', () async {
      final api = _Api()..failHistory = true;
      final client = await _client(api: api);
      final rooms = await _rooms(client);
      await _bakery(client);
      await _timeline(client, general, [_msg('before')]);
      api.roomHistory[general] = [_msg('a'), _msg('b'), _msg('c')];
      await _timeline(client, general, [api.roomHistory[general]!.first], limited: true);
      await _settle();
      expect(channel(rooms, general).unread, 1, reason: 'the old count stays');

      api.failHistory = false;
      await _timeline(client, general, const []);
      await _settle();
      expect(channel(rooms, general).unread, 3);
    });

    test('messages that arrive during a fill are kept', () async {
      final api = _Api()..hold = Completer<void>();
      final client = await _client(api: api);
      final rooms = await _rooms(client);
      await _bakery(client);
      api.roomHistory[general] = [_msg('a', ts: 1000), _msg('b', ts: 900)];
      await _timeline(client, general, [api.roomHistory[general]!.first], limited: true);
      await _settle();
      await _timeline(client, general, [_msg('during', ts: 2000)]);
      await _settle();
      api.hold!.complete();
      await _settle();
      expect(channel(rooms, general).unread, 3);
    });

    test('rooms that synced before the counts existed are filled once', () async {
      final api = _Api();
      final client = await _client(api: api);
      await _bakery(client);
      // A message from someone else is the newest event: hasNewMessages.
      await _timeline(client, general, [_msg('waiting')]);
      api.roomHistory[general] = [_msg('waiting'), _msg('earlier')];
      final rooms = await _rooms(client);
      await _settle();
      expect(channel(rooms, general).unread, 2);
      expect(api.historyCalls[general], 1);
      expect(api.historyCalls['!sourdough:example.com'], isNull,
          reason: 'a room with nothing new is not fetched');
    });
```

For the in-flight test, `_Api.hold` must also hold `/messages`: add `await hold?.future;` at the top of the `/messages` branch, after counting the call.

- [ ] **Step 3: Run to verify they fail**

Run: `mise exec -- flutter test test/matrix/matrix_rooms_test.dart --name unread`
Expected: the five new tests FAIL.

- [ ] **Step 4: Implement filling**

In `MatrixUnread`, add:

```dart
  /// Rooms whose local history can't be trusted and must be counted from
  /// the server: a limited sync skipped messages, or a fill failed.
  final _needsFill = <String>{};
  final _filling = <String>{};

  /// At most this many rooms fetch at once, so a launch with many unread
  /// rooms doesn't fire every request together.
  static const _parallelFills = 4;
  final _fillQueue = <String>[];

  /// Gives every joined room a tally: those with something new since your
  /// receipt are counted from the server, the rest start empty. For a
  /// session that synced before these counts existed.
  void seed() {
    for (final room in client.rooms) {
      if (room.membership != Membership.join || _tallies.containsKey(room.id)) continue;
      if (room.hasNewMessages) {
        _scheduleFill(room.id);
      } else {
        _tallies[room.id] = RoomTally();
      }
    }
  }

  void _scheduleFill(String roomId) {
    _needsFill.add(roomId);
    if (_filling.contains(roomId) || _fillQueue.contains(roomId)) return;
    _fillQueue.add(roomId);
    _pump();
  }

  void _pump() {
    while (!_disposed && _filling.length < _parallelFills && _fillQueue.isNotEmpty) {
      final roomId = _fillQueue.removeAt(0);
      _filling.add(roomId);
      unawaited(_fill(roomId).whenComplete(() {
        _filling.remove(roomId);
        _pump();
      }));
    }
  }

  /// Counts [roomId] from the server's history, newest first, back to your
  /// receipt, your own last message, or [RoomTally.cap] messages.
  Future<void> _fill(String roomId) async {
    final room = client.getRoomById(roomId);
    if (room == null) {
      _needsFill.remove(roomId);
      return;
    }
    final own = room.receiptState.global.latestOwnReceipt;
    final found = <TallyEntry>[];
    var capped = false;
    int? newestSeen;
    try {
      String? from;
      pages:
      for (var page = 0; page < 10; page++) {
        final response = await client.getRoomEvents(roomId, Direction.b, from: from, limit: 50);
        for (final raw in response.chunk) {
          final event = Event.fromMatrixEvent(raw, room);
          final ts = event.originServerTs.millisecondsSinceEpoch;
          newestSeen ??= ts;
          if (own != null && (event.eventId == own.eventId || ts <= own.ts)) break pages;
          if (!countsAsMessage(event)) continue;
          if (event.senderId == client.userID) break pages;
          if (found.length == RoomTally.cap) {
            capped = true;
            break pages;
          }
          found.add(await _entry(room, event));
        }
        from = response.end;
        if (from == null) break;
      }
    } on Object catch (e) {
      Logs().v('[loaf] unread fill for $roomId failed: $e');
      return; // Still in _needsFill: the next sync tries again.
    }
    if (_disposed) return;
    // Messages a sync counted while this fill was out are newer than
    // anything it saw; keep them.
    final during = (_tallies[roomId]?.entries ?? const <TallyEntry>[])
        .where((e) => newestSeen == null || e.ts > newestSeen!)
        .where((e) => !found.any((f) => f.id == e.id));
    final tally = RoomTally(entries: [...found.reversed, ...during], capped: capped);
    _readReceipt(room, tally);
    _tallies[roomId] = tally;
    _needsFill.remove(roomId);
    onChange();
  }
```

In `_apply`, at the start of each joined room's loop body (after `room` is found):

```dart
      if (joined.timeline?.limited == true) {
        // The server skipped messages; only it knows how many were unread.
        _scheduleFill(roomId);
        continue;
      }
```

and after the joined-rooms loop:

```dart
    // Fills that failed get another go now the server answers syncs again.
    for (final roomId in [..._needsFill]) {
      _scheduleFill(roomId);
    }
```

Note the retry loop: `_scheduleFill` is a no-op for a room already filling or queued, so this can't stack requests.

In `MatrixRooms`'s constructor, after `_rebuild();`: `_unread.seed();`.

- [ ] **Step 5: Run to verify they pass**

Run: `mise exec -- flutter test test/matrix/matrix_rooms_test.dart`
Expected: PASS, the whole file.

- [ ] **Step 6: Commit**

```bash
git add lib/matrix/matrix_unread.dart lib/matrix/matrix_rooms.dart test/matrix/matrix_rooms_test.dart
git commit -m "feat(unread): count from the server after a gap or on first launch, up to 99"
```

---

### Task 5: Counts survive a relaunch

**Files:**
- Modify: `lib/matrix/matrix_unread.dart`
- Modify: `lib/matrix/matrix_rooms.dart` (pass the file)
- Test: `test/matrix/matrix_rooms_test.dart`

**Interfaces:**
- Consumes: Tasks 3–4.
- Produces: `MatrixUnread(Client client, {required void Function() onChange, File? file})`. With a file, tallies load from it before any sync applies or the seed runs, and changes are written back at most once a second and on dispose.

- [ ] **Step 1: Write the failing test**

```dart
    test('a relaunch shows the counts before the server answers', () async {
      final api = _Api();
      final client = await _client(api: api);
      final dir = await Directory.systemTemp.createTemp('loaf-unread');
      addTearDown(() => dir.delete(recursive: true));
      final files = Directory('${dir.path}${Platform.pathSeparator}files');

      final first = MatrixRooms(client, mediaRoot: files);
      await _bakery(client);
      await _timeline(client, general, [_msg('one'), _msg('two')]);
      await _settle();
      first.dispose();
      // Disposing writes the file; let it land.
      await _settle();

      // The server is unreachable: only the saved counts can say 2.
      api.failHistory = true;
      final second = MatrixRooms(client, mediaRoot: files);
      addTearDown(second.dispose);
      await _settle();
      expect(channel(second, general).unread, 2);
      expect(File('${dir.path}${Platform.pathSeparator}unread.json').existsSync(), isTrue);
    });
```

Check the constructor's parameter name for the media root (`MatrixRooms(this.client, {this._mediaRoot, ...})` is a private named parameter; tests already pass it somewhere — `grep -n "MatrixRooms(" test` — and use the same spelling).

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- flutter test test/matrix/matrix_rooms_test.dart --name relaunch`
Expected: FAIL — the second instance counts 0 (the seed's fill fails).

- [ ] **Step 3: Implement persistence**

In `MatrixUnread`:

```dart
  MatrixUnread(this.client, {required this.onChange, this.file}) {
    // Syncs and the seed wait for what the last run saved.
    _queue = _load();
  }

  /// Where tallies are kept between runs. Beside the media folder, so
  /// signing out, which clears that folder's parent, clears this too.
  final File? file;
  Timer? _saveTimer;

  Future<void> _load() async {
    final file = this.file;
    if (file == null || !await file.exists()) return;
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
      if (json['user'] != client.userID) return;
      final rooms = json['rooms'] as Map<String, Object?>? ?? const {};
      for (final MapEntry(:key, :value) in rooms.entries) {
        _tallies[key] = RoomTally.fromJson(value! as Map<String, Object?>);
      }
      onChange();
    } on Object catch (e) {
      // A torn or foreign file: the seed counts afresh from the server.
      Logs().w('[loaf] unread.json unreadable: $e');
    }
  }

  void _scheduleSave() {
    if (file == null || _disposed) return;
    _saveTimer ??= Timer(const Duration(seconds: 1), () {
      _saveTimer = null;
      unawaited(_save());
    });
  }

  Future<void> _save() async {
    final file = this.file;
    if (file == null) return;
    final json = jsonEncode({
      'user': client.userID,
      'rooms': {for (final MapEntry(:key, :value) in _tallies.entries) key: value.toJson()},
    });
    try {
      // Written aside and renamed, so a crash mid-write leaves the old one.
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(json, flush: true);
      await tmp.rename(file.path);
    } on Object catch (e) {
      Logs().w('[loaf] unread.json not saved: $e');
    }
  }
```

Change `seed()` to run after the load: wrap its body in `_queue = _queue.then((_) { ...existing body... });`.

Call `_scheduleSave()` everywhere `onChange()` is called after a change (`_apply`, `_fill`). Change `dispose()`:

```dart
  void dispose() {
    _disposed = true;
    if (_saveTimer != null) {
      _saveTimer!.cancel();
      _saveTimer = null;
      unawaited(_save());
    }
  }
```

Add imports `dart:convert` and `dart:io`.

In `MatrixRooms`, give the field its file:

```dart
  late final MatrixUnread _unread = MatrixUnread(
    client,
    file: switch (_mediaRoot ?? _storageRoot()) {
      final root? => File('${root.parent.path}${Platform.pathSeparator}unread.json'),
      null => null,
    },
    onChange: () {
      if (!_disposed) _rebuild();
    },
  );
```

The file lives in the media root's parent, not inside it: `MediaStore.evict` walks the media root and must never see it.

- [ ] **Step 4: Run to verify it passes**

Run: `mise exec -- flutter test test/matrix/matrix_rooms_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/matrix/matrix_unread.dart lib/matrix/matrix_rooms.dart test/matrix/matrix_rooms_test.dart
git commit -m "feat(unread): counts saved between runs, so a relaunch shows them at once"
```

---

### Task 6: A mention found once its key arrives

**Files:**
- Modify: `lib/matrix/matrix_unread.dart`
- Test: `test/matrix/matrix_rooms_test.dart`

**Interfaces:**
- Consumes: `TallyEntry.locked`, `RoomTally.replace` (Task 2).
- Produces: nothing new outside the class.

- [ ] **Step 1: Write the failing test**

```dart
    test('an encrypted message is checked again once it can be read', () async {
      final (client, rooms) = await bakery();
      await _timeline(client, general, [
        {
          'type': 'm.room.encrypted',
          'sender': '@ada:example.com',
          'content': {
            'algorithm': 'm.megolm.v1.aes-sha2',
            'ciphertext': 'locked',
            'session_id': 'nokey',
            'sender_key': 'k',
            'device_id': 'D',
          },
          'event_id': r'$locked',
          'origin_server_ts': 1700000000000 + _events++ * 1000,
        },
      ]);
      await _settle();
      expect(channel(rooms, general).unread, 1);
      expect(channel(rooms, general).mentions, 0);

      // The key arrived and the SDK stored the message decrypted.
      final room = client.getRoomById(general)!;
      await client.database.storeEventUpdate(
        general,
        Event(
          type: EventTypes.Message,
          content: {'msgtype': 'm.text', 'body': 'hey', 'm.mentions': {'user_ids': [_me]}},
          senderId: '@ada:example.com',
          eventId: r'$locked',
          originServerTs: DateTime.fromMillisecondsSinceEpoch(1700000000000),
          room: room,
        ),
        EventUpdateType.timeline,
        client,
      );
      await _timeline(client, general, const []);
      await _settle();
      expect(channel(rooms, general).mentions, 1);
    });
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- flutter test test/matrix/matrix_rooms_test.dart --name "checked again"`
Expected: FAIL — mentions stays 0.

- [ ] **Step 3: Implement**

In `MatrixUnread._apply`, after the joined-rooms loop and before the retry loop:

```dart
    // Messages counted while still encrypted: once the SDK has stored them
    // readable, see whether they mention you.
    for (final MapEntry(key: roomId, value: tally) in _tallies.entries) {
      final locked = tally.entries.where((e) => e.locked).toList();
      if (locked.isEmpty) continue;
      final room = client.getRoomById(roomId);
      if (room == null) continue;
      for (final entry in locked) {
        final stored = await client.database.getEventById(entry.id, room);
        if (stored == null || stored.type == EventTypes.Encrypted) continue;
        if (tally.replace(await _entry(room, stored))) changed = true;
      }
    }
```

`_entry` uses the stored event's id and timestamp, which match the original's.

- [ ] **Step 4: Run to verify it passes**

Run: `mise exec -- flutter test test/matrix/matrix_rooms_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/matrix/matrix_unread.dart test/matrix/matrix_rooms_test.dart
git commit -m "feat(unread): an encrypted message's mention counts once its key arrives"
```

---

### Task 7: Bold despite mute, 99+, and the space pip

**Files:**
- Create: `lib/ui/widgets/count_label.dart`
- Modify: `lib/ui/shell/channel_list.dart` (`build` around line 523, `_CountBadge`)
- Modify: `lib/ui/shell/spaces_rail.dart` (`_SelectionPill`, `_SpaceItem.build`, `_CountBadge`)
- Modify: `lib/ui/model/models.dart` (`Space.unread`)
- Test: `test/app_shell_test.dart`

**Interfaces:**
- Produces: `String countLabel(int count)` — `'99+'` above 99, else the number.

- [ ] **Step 1: Write the failing tests**

In `test/app_shell_test.dart`, in the group holding `'mark as read clears the badge'` (it defines `inRow`), add:

```dart
    testWidgets('a muted channel with unreads is still bold', variant: desktop, (
      tester,
    ) async {
      await _pumpShell(tester, const Size(1440, 900));
      await rightClick(tester, 'chess');
      await pick(tester, 'Mute channel');

      final name = tester.widget<Text>(inRow('chess', find.text('chess')));
      expect(name.style!.fontWeight, FontWeight.w600);
    });
```

Replace `'the rail badge recounts as you read'` with:

```dart
    testWidgets('the rail badges mentions and pips unreads', variant: desktop, (
      tester,
    ) async {
      await _pumpShell(tester, const Size(1440, 900));
      Finder inSpace(String id, Finder matching) => find.descendant(
        of: find.byKey(ValueKey('space-$id')),
        matching: matching,
      );
      final ryePip = find.byKey(const ValueKey('space-unread-ryedevs'));

      // The Starter Pack: kitchen's 3 mentions.
      expect(inSpace('starter', find.text('3')), findsOneWidget);
      // Rye Devs: loaf-native's 2 unreads, no mentions — a pip, no number.
      expect(ryePip, findsOneWidget);
      expect(inSpace('ryedevs', find.text('2')), findsNothing);

      await rightClick(tester, 'kitchen');
      await pick(tester, 'Mark as read');
      expect(inSpace('starter', find.text('3')), findsNothing);
      // chess still has 2 unread, but a space never shows an unread count.
      expect(inSpace('starter', find.text('2')), findsNothing);

      // Reading loaf-native clears Rye Devs' pip.
      await tester.tap(find.text('RD'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('loaf-native'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('TS')); // back to The Starter Pack
      await tester.pumpAndSettle();
      expect(ryePip, findsNothing);
    });
```

The Starter Pack's rail initials may not be `TS`. Check with `Space(name: 'The Starter Pack').initials` in `models.dart` and use what it returns, or tap `find.byKey(const ValueKey('space-starter'))` instead.

Add a pure test file `test/count_label_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/widgets/count_label.dart';

void main() {
  test('counts read as numbers up to 99, then 99+', () {
    expect(countLabel(1), '1');
    expect(countLabel(99), '99');
    expect(countLabel(100), '99+');
    expect(countLabel(250), '99+');
  });
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `mise exec -- flutter test test/app_shell_test.dart test/count_label_test.dart`
Expected: FAIL — muted rows aren't bold, there's no pip, and `count_label.dart` doesn't exist.

- [ ] **Step 3: Implement**

`lib/ui/widgets/count_label.dart`:

```dart
/// A badge's number: past 99 it stops counting, since the tally does too.
String countLabel(int count) => count > 99 ? '99+' : '$count';
```

`lib/ui/shell/channel_list.dart`, in `build`:

```dart
    // Mute quiets notifications and sound, not what's unread.
    final unread = joined && channel.unread > 0;
```

(replacing the muted comment and the line that read `!channel.muted`). In `_CountBadge.build`, `'$count'` becomes `countLabel(count)` with the import added.

`lib/ui/model/models.dart`, `Space.unread`:

```dart
  /// Unread messages across the channels you are in, muted or not.
  int get unread => allChannels
      .where((c) => c.joined)
      .fold(0, (sum, c) => sum + c.unread);
```

`lib/ui/shell/spaces_rail.dart`:

`_SelectionPill` grows an unread state:

```dart
class _SelectionPill extends StatelessWidget {
  const _SelectionPill({
    super.key,
    required this.tokens,
    required this.selected,
    this.unread = false,
  });

  final LoafTokens tokens;
  final bool selected;

  /// Something unread in a space you aren't in: a short pip where the
  /// selection pill goes.
  final bool unread;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: LoafMotion.fast,
    curve: LoafMotion.ease,
    width: 4,
    height: selected ? 26 : unread ? 8 : 0,
    decoration: BoxDecoration(
      color: selected ? tokens.accent : tokens.textStrong,
      borderRadius: BorderRadius.circular(2),
    ),
  );
}
```

In `_SpaceItem.build`, the badge becomes mentions only, and the pill gets the unread state:

```dart
    final showBadge = space.mentions > 0;
```

(deleting `badgeCount`; the badge's `count:` becomes `space.mentions`), and:

```dart
                child: _SelectionPill(
                  key: !selected && space.unread > 0
                      ? ValueKey('space-unread-${space.id}')
                      : null,
                  tokens: tokens,
                  selected: selected,
                  unread: space.unread > 0,
                ),
```

In the rail's `_CountBadge.build`, `'$count'` becomes `countLabel(count)`.

Leave the Home item alone: its badge is DM unreads plus mentions elsewhere, which the spec keeps.

- [ ] **Step 4: Run the UI suites**

Run: `mise exec -- flutter test test/app_shell_test.dart test/count_label_test.dart test/home_test.dart test/app_shell_rooms_test.dart`
Expected: PASS. If a test asserts a space's badge shows an unread count (not mentions), it encodes the old rule. Change it to expect the pip, and name it in the commit message.

- [ ] **Step 5: Commit**

```bash
git add lib/ui/widgets/count_label.dart lib/ui/shell/channel_list.dart lib/ui/shell/spaces_rail.dart lib/ui/model/models.dart test/app_shell_test.dart test/count_label_test.dart
git commit -m "feat(unread): muted channels stay bold, 99+, and spaces pip unreads and badge mentions"
```

---

### Task 8: Whole suite and analysis

- [ ] **Step 1: Analyze**

Run: `mise exec -- flutter analyze`
Expected: No issues.

- [ ] **Step 2: Full test run**

Run: `mise exec -- flutter test`
Expected: PASS. A failure in a file this plan didn't touch most likely read a server count through `MatrixRooms`. Fix it as in Task 3 Step 6.

- [ ] **Step 3: Check by hand on macOS**

Run: `mise exec -- flutter run -d macos`. Sign in, then:

- A muted channel with new messages is bold.
- A space with unreads and no mentions shows a pip and no number.
- Quit the app, have someone send messages, relaunch: the counts show before the first sync finishes.

Report what you saw.

- [ ] **Step 4: Commit any fixes**

```bash
git add -A
git commit -m "fix(unread): <what the full run turned up>"
```

Only if Steps 1–3 needed changes.
