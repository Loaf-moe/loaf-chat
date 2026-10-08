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
  }

  final Client client;

  /// Messages sent before this are the backlog a launch catches up on.
  final DateTime _startedAt;
  late final StreamSubscription<Event> _sub;
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
    if (event.senderId == client.userID) return;
    if (event.originServerTs.isBefore(_startedAt)) return;
    if (!countsAsMessage(event)) return;
    if (!client.pushruleEvaluator.match(event).notify) return;
    _arrivals.add(Arrival(roomId: event.room.id, eventId: event.eventId));
  }

  void dispose() {
    unawaited(_sub.cancel());
    unawaited(_arrivals.close());
  }
}
