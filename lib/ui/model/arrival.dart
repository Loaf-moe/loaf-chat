import 'package:flutter/foundation.dart';

import 'models.dart';

/// What a message is, as far as a notification says: its text, a
/// picture, a file, or something not yet decrypted.
enum ArrivalKind { text, picture, file, encrypted }

/// A new message that should notify you: which room and event, and what a
/// notification needs to say about it. The same message is the same
/// arrival, whatever was read off it.
@immutable
class Arrival {
  const Arrival({
    required this.roomId,
    required this.eventId,
    this.senderId = '',
    this.senderName = '',
    this.senderAvatar,
    this.kind = ArrivalKind.text,
    this.text = '',
  });

  final String roomId;
  final String eventId;
  final String senderId;

  /// Their display name in the room; empty when there is none.
  final String senderName;
  final AvatarRef? senderAvatar;
  final ArrivalKind kind;

  /// The message as plain text, reply quote left out. Only for
  /// [ArrivalKind.text].
  final String text;

  @override
  bool operator ==(Object other) =>
      other is Arrival && other.roomId == roomId && other.eventId == eventId;

  @override
  int get hashCode => Object.hash(roomId, eventId);

  @override
  String toString() => 'Arrival($roomId, $eventId)';
}
