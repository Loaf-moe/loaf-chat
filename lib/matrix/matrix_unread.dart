import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import 'unread_rules.dart';
import 'unread_tally.dart';

/// Each joined room's unread messages, counted here rather than taken from
/// the server's push-rule numbers: those are zero in a muted or
/// mentions-only room, and blind to mentions in an encrypted one. Syncs are
/// applied one at a time, in order, since decrypting makes each one wait.
class MatrixUnread {
  MatrixUnread(this.client, {required this.onChange, this.file}) {
    // Syncs and the seed wait for what the last run saved.
    _queue = _load();
  }

  final Client client;

  /// Where tallies are kept between runs. Beside the media folder, so
  /// signing out, which clears that folder's parent, clears this too.
  final File? file;
  Timer? _saveTimer;

  /// Called after counts change, outside any sync's own rebuild.
  final void Function() onChange;

  final _tallies = <String, RoomTally>{};

  /// The last receipt of yours applied to each room. The SDK keeps handing
  /// back the same one, and applying it again would read a message that
  /// arrived late with a time before it.
  final _receipts = <String, ({String eventId, int ts})>{};

  /// Rooms whose local history can't be trusted and must be counted from
  /// the server: a limited sync skipped messages, or a fill failed.
  final _needsFill = <String>{};
  final _filling = <String>{};

  /// Rooms that needed a fill again while one was already out: a gap, or
  /// your own message, that the fetch in flight may have missed.
  final _refill = <String>{};

  /// At most this many rooms fetch at once, so a launch with many unread
  /// rooms doesn't fire every request together.
  static const _parallelFills = 4;
  final _fillQueue = <String>[];
  Future<void> _queue = Future.value();
  var _disposed = false;

  RoomTally of(String roomId) => _tallies[roomId] ?? RoomTally();

  /// Completes once every sync handed to [apply] so far is counted.
  @visibleForTesting
  Future<void> get idle => _queue;

  void apply(SyncUpdate update) {
    _queue = _queue.then((_) => _apply(update)).catchError((
      Object e,
      StackTrace s,
    ) {
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
      if (joined.timeline?.limited == true) {
        // The server skipped messages; only it knows how many were unread.
        // The fill applies the receipt itself.
        _scheduleFill(roomId);
        continue;
      }
      final tally = _tallies.putIfAbsent(roomId, RoomTally.new);
      for (final raw in joined.timeline?.events ?? const <MatrixEvent>[]) {
        if (await _take(room, tally, Event.fromMatrixEvent(raw, room))) {
          changed = true;
        }
      }
      final own = room.receiptState.global.latestOwnReceipt;
      if (own != null &&
          _receipts[roomId] != (eventId: own.eventId, ts: own.ts)) {
        _receipts[roomId] = (eventId: own.eventId, ts: own.ts);
        _scheduleSave();
        if (_readReceipt(room, tally)) changed = true;
      }
    }
    // Fills that failed get another go now the server answers syncs again.
    for (final roomId in [..._needsFill]) {
      _scheduleFill(roomId);
    }
    for (final roomId in update.rooms?.leave?.keys ?? const <String>[]) {
      _receipts.remove(roomId);
      _needsFill.remove(roomId);
      _fillQueue.remove(roomId);
      _refill.remove(roomId);
      if (_tallies.remove(roomId) != null) changed = true;
      _scheduleSave();
    }
    if (changed && !_disposed) {
      _scheduleSave();
      onChange();
    }
  }

  /// Gives every joined room a tally: those with something new since your
  /// receipt are counted from the server, the rest start empty. For a
  /// session that synced before these counts existed.
  void seed() {
    // After the load, or it would count rooms the saved file already knows.
    _queue = _queue
        .then((_) {
          if (_disposed) return;
          for (final room in client.rooms) {
            if (room.membership != Membership.join ||
                _tallies.containsKey(room.id)) {
              continue;
            }
            if (room.hasNewMessages) {
              _scheduleFill(room.id);
            } else {
              _tallies[room.id] = RoomTally();
            }
          }
          _scheduleSave();
        })
        .catchError((Object e, StackTrace s) {
          Logs().w('[loaf] unread seed failed', e, s);
        });
  }

  void _scheduleFill(String roomId) {
    _needsFill.add(roomId);
    if (_filling.contains(roomId)) {
      _refill.add(roomId);
      return;
    }
    if (_fillQueue.contains(roomId)) return;
    _fillQueue.add(roomId);
    _pump();
  }

  void _pump() {
    while (!_disposed &&
        _filling.length < _parallelFills &&
        _fillQueue.isNotEmpty) {
      final roomId = _fillQueue.removeAt(0);
      _filling.add(roomId);
      unawaited(
        _fill(roomId).whenComplete(() {
          _filling.remove(roomId);
          if (_refill.remove(roomId) && _needsFill.contains(roomId)) {
            _fillQueue.add(roomId);
          }
          _pump();
        }),
      );
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
        final response = await client.getRoomEvents(
          roomId,
          Direction.b,
          from: from,
          limit: 50,
        );
        for (final raw in response.chunk) {
          final event = Event.fromMatrixEvent(raw, room);
          final ts = event.originServerTs.millisecondsSinceEpoch;
          newestSeen ??= ts;
          if (own != null && (event.eventId == own.eventId || ts <= own.ts)) {
            break pages;
          }
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
    if (client.getRoomById(roomId)?.membership != Membership.join) {
      // Left while the fetch was out: nothing to count.
      _needsFill.remove(roomId);
      return;
    }
    // Messages a sync counted while this fill was out are newer than
    // anything it saw; keep them.
    final during = (_tallies[roomId]?.entries ?? const <TallyEntry>[])
        .where((e) => newestSeen == null || e.ts > newestSeen)
        .where((e) => !found.any((f) => f.id == e.id));
    final tally = RoomTally(
      entries: [...found.reversed, ...during],
      capped: capped,
    );
    _readReceipt(room, tally);
    // Remembered so the next sync doesn't apply this receipt a second time.
    final current = room.receiptState.global.latestOwnReceipt;
    if (current != null) {
      _receipts[roomId] = (eventId: current.eventId, ts: current.ts);
    }
    _tallies[roomId] = tally;
    // A refill is still owed when something landed that this fetch may have
    // missed; the flag stays so it runs.
    if (!_refill.contains(roomId)) _needsFill.remove(roomId);
    _scheduleSave();
    onChange();
  }

  Future<void> _load() async {
    final file = this.file;
    if (file == null || !await file.exists()) return;
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, Object?>;
      if (json['user'] != client.userID) return;
      final rooms = json['rooms'] as Map<String, Object?>? ?? const {};
      for (final MapEntry(:key, :value) in rooms.entries) {
        final room = value! as Map<String, Object?>;
        _tallies[key] = RoomTally.fromJson(room);
        // The receipt that was applied, so the SDK handing it back after a
        // relaunch doesn't read a late message with a time before it.
        final r = room['r'] as List?;
        if (r != null) {
          _receipts[key] = (eventId: r[0] as String, ts: r[1] as int);
        }
      }
      if (!_disposed) onChange();
    } on Object catch (e) {
      // A torn or foreign file: the seed counts afresh from the server.
      _tallies.clear();
      _receipts.clear();
      Logs().w('[loaf] unread.json unreadable: $e');
    }
  }

  /// At most one write a second, however fast syncs change counts.
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
      'rooms': {
        for (final MapEntry(:key, :value) in _tallies.entries)
          key: {
            ...value.toJson(),
            if (_receipts[key] case final r?) 'r': [r.eventId, r.ts],
          },
      },
    });
    try {
      // Written aside and renamed, so a crash mid-write leaves the old one.
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(json, flush: true);
      await tmp.rename(file.path);
    } on Object catch (e) {
      Logs().w('[loaf] unread.json not saved: $e');
    }
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
      // Sending in a room reads it, as the server counts it too. A fill in
      // flight would bring the older unreads back, so it runs again.
      if (_filling.contains(room.id)) _scheduleFill(room.id);
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
        displayName: room
            .unsafeGetUserFromMemoryOrFallback(me)
            .calcDisplayname(),
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

  /// Applies your current receipt in [room], changed or not.
  bool _readReceipt(Room room, RoomTally tally) {
    final own = room.receiptState.global.latestOwnReceipt;
    return own != null && tally.readUpTo(own.eventId, own.ts);
  }

  void dispose() {
    _disposed = true;
    if (_saveTimer != null) {
      _saveTimer!.cancel();
      _saveTimer = null;
      unawaited(_save());
    }
  }
}
