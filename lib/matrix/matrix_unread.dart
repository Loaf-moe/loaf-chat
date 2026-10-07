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

  /// The last receipt of yours applied to each room. The SDK keeps handing
  /// back the same one, and applying it again would read a message that
  /// arrived late with a time before it.
  final _receipts = <String, ({String eventId, int ts})>{};
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
        if (_readReceipt(room, tally)) changed = true;
      }
    }
    for (final roomId in update.rooms?.leave?.keys ?? const <String>[]) {
      _receipts.remove(roomId);
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

  void dispose() => _disposed = true;
}
