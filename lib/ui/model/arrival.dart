import 'package:flutter/foundation.dart';

/// A new message that should notify you: which room, and which event.
@immutable
class Arrival {
  const Arrival({required this.roomId, required this.eventId});

  final String roomId;
  final String eventId;

  @override
  bool operator ==(Object other) =>
      other is Arrival && other.roomId == roomId && other.eventId == eventId;

  @override
  int get hashCode => Object.hash(roomId, eventId);

  @override
  String toString() => 'Arrival($roomId, $eventId)';
}
