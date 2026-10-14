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
import '../ui/model/message_route.dart';
import '../ui/model/models.dart';
import 'push_rules.dart';
import 'unread_rules.dart';

class MatrixArrivals {
  MatrixArrivals(this.client, {DateTime Function()? now})
    : _startedAt = _launch((now ?? DateTime.now)(), client) {
    _sub = client.onTimelineEvent.stream.listen(_on);
    // Settling waits on members, so syncs are settled in turn.
    _synced = client.onSync.stream.listen((_) => _chain(_settle));
  }

  final Client client;

  /// Messages sent before this are the backlog a launch catches up on.
  final DateTime _startedAt;

  /// [now] by this device's clock, or the newest message already here
  /// by the servers' clocks, whichever is later: a clock behind would
  /// otherwise read the whole catch-up as new.
  static DateTime _launch(DateTime now, Client client) {
    var latest = now;
    for (final room in client.rooms) {
      final sent = room.lastEvent?.originServerTs;
      if (sent != null && sent.isAfter(latest)) latest = sent;
    }
    return latest;
  }

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

  /// Rooms whose members have been asked for this session, by room id,
  /// with the room object asked: a room left and rejoined is a new one,
  /// which the SDK builds afresh.
  final _loaded = <String, (Room, Future<void>)>{};
  late final _rules = PushRules(client);

  /// Messages still sealed when judged, by room and session, with whether
  /// the sealed verdict notified; the oldest let go past [_keptSealed] a
  /// room. Their key may still come.
  final _sealed = <String, Map<String, List<(Event, bool)>>>{};
  static const _keptSealed = 200;
  final _keySubs = <String, (Room, StreamSubscription<String>)>{};
  final _retractions = StreamController<MessageRoute>.broadcast();

  /// Messages deleted this session, by id, the oldest let go past
  /// [_keptRedacted]: a deletion in the same sync as its message must
  /// not leave the message to notify with what was deleted.
  final _redacted = <String>{};
  static const _keptRedacted = 500;

  Stream<Arrival> get stream => _arrivals.stream;

  /// Messages noticed while sealed whose text, once read, does not
  /// notify: their notice is to be taken back.
  Stream<MessageRoute> get retractions => _retractions.stream;

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
    if (event.type == EventTypes.Redaction) {
      final id = event.redacts;
      if (id != null) {
        _redacted.add(id);
        if (_redacted.length > _keptRedacted) _redacted.remove(_redacted.first);
      }
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
      // Both could have changed while the members loaded.
      if (event.redacted || _redacted.contains(event.eventId)) continue;
      if (client.getRoomById(event.room.id)?.membership != Membership.join) {
        continue;
      }
      final notifies = _rules.notifies(event);
      if (event.type == EventTypes.Encrypted) _keep(event, noticed: notifies);
      if (!notifies) continue;
      _arrivals.add(_arrival(event));
    }
  }

  /// Keeps [event] for its key, and listens for the room's keys once per
  /// room object: a rejoined room is a new one, with keys of its own.
  void _keep(Event event, {required bool noticed}) {
    final session = event.content.tryGet<String>('session_id');
    if (session == null) return;
    final room = event.room;
    final known = _keySubs[room.id];
    if (known == null || !identical(known.$1, room)) {
      unawaited(known?.$2.cancel());
      _sealed.remove(room.id);
      _keySubs[room.id] = (
        room,
        room.onSessionKeyReceived.stream.listen(
          (session) => _chain(() => _unseal(room, session)),
        ),
      );
    }
    final byRoom = _sealed.putIfAbsent(room.id, () => {});
    (byRoom[session] ??= []).add((event, noticed));
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
  }

  /// Judges the messages sealed under [session] again, now that its key
  /// is here: those that open are read as what they say. One noticed
  /// while sealed whose text does not notify has its notice taken back.
  Future<void> _unseal(Room room, String session) async {
    final events = _sealed[room.id]?.remove(session);
    if (events == null) return;
    final encryption = client.encryption;
    if (encryption == null) return;
    for (final (event, noticed) in events) {
      final open = await encryption.decryptRoomEvent(event);
      if (_disposed) return;
      if (open.type == EventTypes.Encrypted) {
        _keep(event, noticed: noticed);
        continue;
      }
      var notifies =
          client.getRoomById(room.id)?.membership == Membership.join &&
          !_redacted.contains(event.eventId) &&
          countsAsMessage(open);
      if (notifies) {
        await _members(room);
        if (_disposed) return;
        notifies = _rules.notifies(open);
      }
      if (notifies) {
        _arrivals.add(_arrival(open));
      } else if (noticed) {
        _retractions.add(MessageRoute(room.id, event.eventId));
      }
    }
  }

  /// Loads what the rules read of [room]'s members, once. With the room's
  /// count in its summary, that is your own member event alone, for your
  /// name: memory, then the store. Without a count, or with your event in
  /// neither, the whole list, which the evaluator can count and which
  /// never misstates your membership the way a lone state answer can. A
  /// load the server refuses is logged, and asked for again with the
  /// next message.
  Future<void> _members(Room room) {
    final known = _loaded[room.id];
    if (known != null && identical(known.$1, room)) return known.$2;
    final loading = _load(room).then<void>(
      (_) {},
      onError: (Object e) {
        if (identical(_loaded[room.id]?.$1, room)) _loaded.remove(room.id);
        Logs().w('[loaf] members of ${room.id} not loaded', e);
      },
    );
    _loaded[room.id] = (room, loading);
    return loading;
  }

  Future<void> _load(Room room) async {
    final me = client.userID!;
    if (room.summary.mJoinedMemberCount != null) {
      if (room.getState(EventTypes.RoomMember, me) != null) return;
      final mine = await client.database.getUser(me, room);
      if (mine != null) {
        room.setState(mine);
        return;
      }
    }
    if (!room.participantListComplete) {
      await room.requestParticipants([Membership.join], true, true);
    }
  }

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
      sentAt: event.originServerTs,
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
    for (final (_, sub) in _keySubs.values) {
      unawaited(sub.cancel());
    }
    _keySubs.clear();
    _sealed.clear();
    _pending.clear();
    unawaited(_arrivals.close());
    unawaited(_retractions.close());
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
