/// Taking back what you have already read. A room read on another device
/// arrives here as a sync with its counts at zero; iOS still has whatever
/// notifications it showed, so they are withdrawn.
library;

import 'dart:async';

import '../ui/rooms/rooms.dart';

class PushSweeper {
  PushSweeper({required this.rooms, required this.withdraw}) {
    rooms.addListener(_sweep);
    _sweep();
  }

  final Rooms rooms;

  /// [IosPush.withdraw] in the app; a recorder in tests.
  final Future<void> Function(String roomId, {DateTime? before}) withdraw;

  DateTime? _swept;

  void dispose() => rooms.removeListener(_sweep);

  void _sweep() {
    final settled = rooms.settledBefore;
    // Null until two syncs have landed, and unchanged means nothing new has
    // been counted since the last sweep.
    if (settled == null || settled == _swept) return;
    _swept = settled;
    for (final channel in [
      ...rooms.homeRooms,
      ...rooms.spaces.expand((space) => space.allChannels),
    ]) {
      if (!channel.joined || channel.unread != 0 || channel.mentions != 0) {
        continue;
      }
      // Bounded by [settled]: a notification for a message that arrived
      // after the server counted is not covered by these zeroes, and must
      // not be taken away. The native side does nothing for a room with
      // nothing delivered.
      unawaited(withdraw(channel.id, before: settled));
    }
  }
}
