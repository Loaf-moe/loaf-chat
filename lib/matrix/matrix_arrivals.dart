/// The new messages that should notify you, read off the SDK's sync. Only
/// messages from others, sent after this shell opened, of a kind the
/// timeline shows, that your push rules say notify: the rules see
/// decrypted content where a key was here, so a mention in an encrypted
/// room counts.
library;

import 'dart:async';

import 'package:matrix/matrix.dart';

import '../ui/model/arrival.dart';
import 'unread_rules.dart';

class MatrixArrivals {
  MatrixArrivals(this.client, {DateTime Function()? now})
    : _startedAt = (now ?? DateTime.now)() {
    _sub = client.onTimelineEvent.stream.listen(_on);
    _synced = client.onSync.stream.listen((_) => _settle());
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

  Stream<Arrival> get stream => _arrivals.stream;

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
    if (event.type == EventTypes.RoomMember &&
        event.stateKey == client.userID &&
        event.content['membership'] == 'join') {
      _joinedAt[event.room.id] = event.originServerTs;
    }
    if (event.senderId == client.userID) return;
    if (event.originServerTs.isBefore(_startedAt)) return;
    if (!countsAsMessage(event)) return;
    if (!client.pushruleEvaluator.match(event).notify) return;
    _pending.add(event);
  }

  /// A room joined after launch delivers messages sent before you joined,
  /// but after launch: they are its history. Your join event dates the start
  /// of what is yours, but it comes in the timeline after that history, so
  /// the verdict waits for the end of the sync. A room whose join this
  /// session never saw has nothing to compare, and is let through.
  void _settle() {
    final events = List.of(_pending);
    _pending.clear();
    for (final event in events) {
      final joined = _joinedAt[event.room.id];
      if (joined != null && event.originServerTs.isBefore(joined)) continue;
      _arrivals.add(Arrival(roomId: event.room.id, eventId: event.eventId));
    }
  }

  void dispose() {
    unawaited(_sub.cancel());
    unawaited(_synced.cancel());
    _pending.clear();
    unawaited(_arrivals.close());
  }
}
