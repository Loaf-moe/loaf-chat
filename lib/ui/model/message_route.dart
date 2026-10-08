/// Where a notification leads: one message in one room. Not called
/// `Route`, which Flutter's widgets library already exports.
library;

import 'package:flutter/foundation.dart';

@immutable
class MessageRoute {
  const MessageRoute(this.roomId, this.eventId);

  final String roomId;
  final String eventId;

  @override
  bool operator ==(Object other) =>
      other is MessageRoute &&
      other.roomId == roomId &&
      other.eventId == eventId;

  @override
  int get hashCode => Object.hash(roomId, eventId);

  @override
  String toString() => 'MessageRoute($roomId, $eventId)';
}
