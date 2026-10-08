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

  /// Rooms whose last fill failed. Their counts stay as they were and the
  /// next sync tries again.
  final _failed = <String>{};
  final _filling = <String>{};

  /// Rooms that needed a fill again while one was already out: a gap, or
  /// your own message, that the fetch in flight may have missed.
  final _refill = <String>{};

  /// At most this many rooms fetch at once, so a launch with many unread
  /// rooms doesn't fire every request together.
  static const _parallelFills = 4;
  final _fillQueue = <String>[];

  /// Each room's key-arrival subscription, with the [Room] it listens to: a
  /// room left and joined again is a new object.
  final _keySubs = <String, ({Room room, StreamSubscription<String> sub})>{};

  /// Rooms with a re-check of their locked messages already waiting, and the
  /// sessions whose keys have come for it.
  final _rechecks = <String, Set<String>>{};
  Future<void> _queue = Future.value();
  var _disposed = false;

  /// Whether [roomId] has been counted. Until it has, the server's numbers
  /// are all there is.
  bool knows(String roomId) => _tallies.containsKey(roomId);

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
      _watchKeys(room);
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
      final own = _ownReceipt(room);
      if (own != null) {
        final fresh = _receipts[roomId] != (eventId: own.eventId, ts: own.ts);
        // The by-time reading is what the gate guards against repeating. A
        // receipt on a message that is counted is exact, and applies even
        // when it was recorded before that message arrived, as happens when
        // the queue lags behind the SDK.
        final onCounted = tally.entries.any((e) => e.id == own.eventId);
        if (fresh || onCounted) {
          _receipts[roomId] = (eventId: own.eventId, ts: own.ts);
          if (fresh) _scheduleSave();
          if (_readReceipt(room, tally)) changed = true;
        }
      }
    }
    // Fills that failed get another go now the server answers syncs again.
    // Only those: a room mid-fill would otherwise be asked for again by
    // every sync that lands, and never finish.
    for (final roomId in [..._failed]) {
      if (!_filling.contains(roomId) && !_fillQueue.contains(roomId)) {
        _scheduleFill(roomId);
      }
    }
    for (final roomId in update.rooms?.leave?.keys ?? const <String>[]) {
      _receipts.remove(roomId);
      _failed.remove(roomId);
      _fillQueue.remove(roomId);
      _refill.remove(roomId);
      _keySubs.remove(roomId)?.sub.cancel();
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
            if (room.membership != Membership.join) continue;
            // Saved tallies may hold locked messages, too.
            _watchKeys(room);
            if (_tallies.containsKey(room.id)) continue;
            if (_hasNewMessages(room)) {
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

  /// Looks again at [room]'s locked messages whenever a key for it arrives.
  /// The SDK stores a decrypted copy only for the room's last event or a
  /// timeline that is open, so key arrival is the one moment a message
  /// counted while locked can be read.
  void _watchKeys(Room room) {
    if (_keySubs[room.id] case final known? when identical(known.room, room)) {
      return;
    }
    _keySubs[room.id]?.sub.cancel();
    _keySubs[room.id] = (
      room: room,
      sub: room.onSessionKeyReceived.stream.listen(
        (sessionId) => _recheckSoon(room.id, sessionId),
      ),
    );
  }

  /// Queues one re-check of [roomId] for the key of [sessionId], behind the
  /// syncs already waiting. A key backup brings many keys at once; they
  /// share it.
  void _recheckSoon(String roomId, String sessionId) {
    if (_disposed) return;
    final pending = _rechecks[roomId];
    if (pending != null) {
      pending.add(sessionId);
      return;
    }
    _rechecks[roomId] = {sessionId};
    _queue = _queue
        .then((_) {
          final sessions = _rechecks.remove(roomId) ?? const <String>{};
          return _recheck(roomId, sessions);
        })
        .catchError((Object e, StackTrace s) {
          Logs().w('[loaf] unread re-check failed', e, s);
        });
  }

  /// Reads [roomId]'s messages locked under [sessions] again, now that their
  /// keys came; the others can't have opened. A room being filled is
  /// skipped, since the fill replaces its tally anyway.
  Future<void> _recheck(String roomId, Set<String> sessions) async {
    if (_disposed || _filling.contains(roomId)) return;
    final tally = _tallies[roomId];
    final room = client.getRoomById(roomId);
    if (tally == null || room == null) return;
    var changed = false;
    try {
      for (final entry in tally.lockedUnder(sessions)) {
        final event = await _stored(room, entry.id);
        if (event == null) continue;
        final reread = await _entry(room, event);
        if (reread.locked) continue;
        // A fill that landed meanwhile replaced this tally; it counted the
        // message itself.
        if (_disposed ||
            _filling.contains(roomId) ||
            !identical(_tallies[roomId], tally)) {
          break;
        }
        if (tally.replace(reread)) changed = true;
      }
    } on Object catch (e) {
      Logs().v('[loaf] unread re-check for $roomId failed: $e');
    }
    if (changed && !_disposed) {
      _scheduleSave();
      onChange();
    }
  }

  /// The event as the server sent it: from the SDK's store, else asked of
  /// the server.
  Future<Event?> _stored(Room room, String eventId) async {
    final stored = await client.database.getEventById(eventId, room);
    if (stored != null) return stored;
    return Event.fromMatrixEvent(
      await client.getOneRoomEvent(room.id, eventId),
      room,
    );
  }

  void _scheduleFill(String roomId) {
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
          if (_refill.remove(roomId)) {
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
      _failed.remove(roomId);
      return;
    }
    final own = _ownReceipt(room);
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
          if (_isOwnJoin(event)) break pages;
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
      _failed.add(roomId); // The next sync tries again.
      return;
    }
    if (_disposed) return;
    if (client.getRoomById(roomId)?.membership != Membership.join) {
      // Left while the fetch was out: nothing to count.
      _failed.remove(roomId);
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
    final current = _ownReceipt(room);
    if (current != null) {
      _receipts[roomId] = (eventId: current.eventId, ts: current.ts);
    }
    _tallies[roomId] = tally;
    _failed.remove(roomId);
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
      // Signing out clears this folder; a late save mustn't bring it back.
      if (!await file.parent.exists()) return;
      // Written aside and renamed, so a crash mid-write leaves the old one.
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
    if (_isOwnJoin(event)) {
      // What came before you joined was never yours to read.
      final had = !tally.isEmpty;
      tally.clear();
      return had;
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

  /// Whether [event] is you joining the room. A change of your name or
  /// avatar is a join too, but with a join before it; that isn't one. With
  /// no previous state to tell, any join of yours is taken as arriving.
  bool _isOwnJoin(Event event) =>
      event.type == EventTypes.RoomMember &&
      event.stateKey == client.userID &&
      event.content['membership'] == 'join' &&
      event.prevContent?['membership'] != 'join';

  /// [event] as an unread entry: decrypted first where a key is here, so a
  /// mention in an encrypted room is seen.
  Future<TallyEntry> _entry(Room room, Event event) async {
    final shown = await _decrypted(event);
    final me = client.userID!;
    final locked = shown.type == EventTypes.Encrypted;
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
      locked: locked,
      session: locked ? event.content.tryGet<String>('session_id') : null,
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

  /// Your latest read receipt in [room]: the later of the unthreaded ones
  /// and those on the main timeline, which the SDK keeps apart. Receipts on
  /// real threads are ignored, since Loaf shows thread replies inline and
  /// reading a thread says nothing about the room.
  LatestReceiptStateData? _ownReceipt(Room room) {
    final state = room.receiptState;
    final global = state.global.latestOwnReceipt;
    final main = state.mainThread?.latestOwnReceipt;
    if (global == null || main == null) return global ?? main;
    return main.ts > global.ts ? main : global;
  }

  /// Whether the room's last event is a message from someone else that your
  /// receipt doesn't cover. [Room.hasNewMessages] looks at unthreaded
  /// receipts only.
  bool _hasNewMessages(Room room) {
    final last = room.lastEvent;
    if (last == null ||
        !countsAsMessage(last) ||
        last.senderId == client.userID) {
      return false;
    }
    final own = _ownReceipt(room);
    return own == null ||
        (own.eventId != last.eventId &&
            own.ts < last.originServerTs.millisecondsSinceEpoch);
  }

  /// Applies your current receipt in [room], changed or not.
  bool _readReceipt(Room room, RoomTally tally) {
    final own = _ownReceipt(room);
    return own != null && tally.readUpTo(own.eventId, own.ts);
  }

  void dispose() {
    _disposed = true;
    for (final known in _keySubs.values) {
      known.sub.cancel();
    }
    _keySubs.clear();
    if (_saveTimer != null) {
      _saveTimer!.cancel();
      _saveTimer = null;
      // A signed-out client's counts are gone with its session.
      if (client.isLogged()) unawaited(_save());
    }
  }
}
