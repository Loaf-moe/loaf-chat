/// The new messages that should notify you, read off the SDK's sync. Only
/// messages from others, sent after this shell opened, of a kind the
/// timeline shows, that your push rules say notify: the rules see
/// decrypted content where a key was here, so a mention in an encrypted
/// room counts. They run with the room's members loaded, so a direct
/// message is known as one and your name is known: a room nobody has
/// opened this session holds no members in memory until asked. A message
/// still sealed is judged again once its key arrives, and comes again as
/// what it says.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import '../ui/model/arrival.dart';
import '../ui/model/models.dart';
import 'unread_rules.dart';

class MatrixArrivals {
  MatrixArrivals(this.client, {DateTime Function()? now})
    : _startedAt = (now ?? DateTime.now)() {
    _sub = client.onTimelineEvent.stream.listen(_on);
    // Settling waits on members, so syncs are settled in turn.
    _synced = client.onSync.stream.listen((_) => _chain(_settle));
  }

  final Client client;

  /// Messages sent before this are the backlog a launch catches up on.
  final DateTime _startedAt;
  late final StreamSubscription<Event> _sub;
  late final StreamSubscription<SyncUpdate> _synced;

  /// Messages that passed every test but one: they wait for the end of
  /// their sync, when the room's state is whole. See [_settle].
  final _pending = <Event>[];

  /// When your latest join event, seen this session, was sent, by room. Not
  /// read from the room's state: the SDK keeps a partial room's own member
  /// event out of it.
  final _joinedAt = <String, DateTime>{};
  final _arrivals = StreamController<Arrival>.broadcast();
  var _settling = Future<void>.value();
  var _disposed = false;

  /// Rooms whose members have been asked for this session, by room.
  final _loaded = <String, Future<void>>{};

  /// Messages still sealed when judged, by room and session, the oldest
  /// let go past [_keptSealed] a room. Their key may still come.
  final _sealed = <String, Map<String, List<Event>>>{};
  static const _keptSealed = 50;
  final _keySubs = <String, StreamSubscription<String>>{};

  Stream<Arrival> get stream => _arrivals.stream;

  /// Done when every message of the syncs so far has its verdict.
  @visibleForTesting
  Future<void> get settled => _settling;

  /// Queues [step] behind the verdicts under way. A step that throws is
  /// reported as the bug it is, and the chain goes on: the next sync is
  /// still judged.
  void _chain(Future<void> Function() step) {
    _settling = _settling
        .then((_) => step())
        .catchError(
          (Object e, StackTrace s) => Zone.current.handleUncaughtError(e, s),
        );
  }

  void _on(Event event) {
    // The SDK sets `prevBatch` only after a sync is handled, so it is still
    // null for the events of a sign-in's first sync, which are all history.
    if (client.prevBatch == null) return;
    // Ask the client, not the event: a room left in this sync is dropped from
    // the client's list before its leave-section events are emitted, and
    // those events keep the evicted Room, which still says join.
    if (client.getRoomById(event.room.id)?.membership != Membership.join) {
      return;
    }
    // Only a real arrival dates your start in the room: a name or avatar
    // change is a join too, and would wrongly cut off messages before it.
    if (isOwnJoin(event, client.userID)) {
      _joinedAt[event.room.id] = event.originServerTs;
    }
    if (event.senderId == client.userID) return;
    if (event.originServerTs.isBefore(_startedAt)) return;
    if (!countsAsMessage(event)) return;
    _pending.add(event);
  }

  /// A room joined after launch delivers messages sent before you joined,
  /// but after launch: they are its history. Your join event dates the start
  /// of what is yours, but it comes in the timeline after that history, so
  /// the verdict waits for the end of the sync. A room whose join this
  /// session never saw has nothing to compare, and is let through. Then
  /// the push rules, with the room's members at hand.
  Future<void> _settle() async {
    final events = List.of(_pending);
    _pending.clear();
    for (final event in events) {
      final joined = _joinedAt[event.room.id];
      if (joined != null && event.originServerTs.isBefore(joined)) continue;
      await _members(event.room);
      if (_disposed) return;
      if (event.type == EventTypes.Encrypted) _keep(event);
      if (!client.pushruleEvaluator.match(event).notify) continue;
      _arrivals.add(_arrival(event));
    }
  }

  /// Keeps [event] for its key, and listens for the room's keys once.
  void _keep(Event event) {
    final session = event.content.tryGet<String>('session_id');
    if (session == null) return;
    final room = event.room;
    final byRoom = _sealed.putIfAbsent(room.id, () => {});
    (byRoom[session] ??= []).add(event);
    var kept = 0;
    for (final events in byRoom.values) {
      kept += events.length;
    }
    while (kept > _keptSealed) {
      final oldest = byRoom.entries.first;
      oldest.value.removeAt(0);
      if (oldest.value.isEmpty) byRoom.remove(oldest.key);
      kept--;
    }
    _keySubs[room.id] ??= room.onSessionKeyReceived.stream.listen(
      (session) => _chain(() => _unseal(room, session)),
    );
  }

  /// Judges the messages sealed under [session] again, now that its key
  /// is here: those that open are read as what they say.
  Future<void> _unseal(Room room, String session) async {
    final events = _sealed[room.id]?.remove(session);
    if (events == null) return;
    final encryption = client.encryption;
    if (encryption == null) return;
    for (final event in events) {
      final open = await encryption.decryptRoomEvent(event);
      if (_disposed) return;
      if (open.type == EventTypes.Encrypted) {
        _keep(event);
        continue;
      }
      if (client.getRoomById(room.id)?.membership != Membership.join) continue;
      if (!countsAsMessage(open)) continue;
      await _members(room);
      if (_disposed) return;
      if (!client.pushruleEvaluator.match(open).notify) continue;
      _arrivals.add(_arrival(open));
    }
  }

  /// Loads [room]'s members once: the SDK's store first, the server only
  /// when the list is still short of the room's count. The whole list,
  /// however long: the SDK puts a message's sender in memory by itself,
  /// so a part of the list can read as a two-person room. A load the
  /// server refuses is logged, and asked for again with the next message.
  Future<void> _members(Room room) => _loaded[room.id] ??=
      (room.participantListComplete
              ? Future<void>.value()
              : room.requestParticipants([Membership.join], true, true))
          .then<void>(
            (_) {},
            onError: (Object e) {
              _loaded.remove(room.id);
              Logs().w('[loaf] members of ${room.id} not loaded', e);
            },
          );

  /// What a notification will say about [event]: read now, while the
  /// sender's member event and the decrypted content are at hand.
  Arrival _arrival(Event event) {
    final sender = event.senderFromMemoryOrFallback;
    final kind = arrivalKind(event);
    return Arrival(
      roomId: event.room.id,
      eventId: event.eventId,
      senderId: event.senderId,
      senderName: sender.calcDisplayname(),
      senderAvatar: AvatarRef.maybe(sender.avatarUrl?.toString()),
      kind: kind,
      text: kind == ArrivalKind.text
          ? event.calcLocalizedBodyFallback(
              const MatrixDefaultLocalizations(),
              hideReply: true,
              hideEdit: true,
              plaintextBody: true,
              removeMarkdown: true,
            )
          : '',
    );
  }

  void dispose() {
    _disposed = true;
    unawaited(_sub.cancel());
    unawaited(_synced.cancel());
    for (final sub in _keySubs.values) {
      unawaited(sub.cancel());
    }
    _keySubs.clear();
    _sealed.clear();
    _pending.clear();
    unawaited(_arrivals.close());
  }
}

/// A picture, a file, words, or a message this device has no key for.
ArrivalKind arrivalKind(Event event) {
  if (event.type == EventTypes.Encrypted) return ArrivalKind.encrypted;
  if (event.type == EventTypes.Sticker) return ArrivalKind.picture;
  return switch (event.messageType) {
    MessageTypes.Image => ArrivalKind.picture,
    MessageTypes.File ||
    MessageTypes.Video ||
    MessageTypes.Audio => ArrivalKind.file,
    _ => ArrivalKind.text,
  };
}
