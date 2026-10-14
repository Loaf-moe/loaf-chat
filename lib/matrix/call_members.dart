/// Who is in a room's call, read from its MatrixRTC membership state the way
/// Element Call writes it: one event per device, emptied on leaving.
library;

import 'dart:math';

import 'package:matrix/matrix.dart';

const callMemberType = 'org.matrix.msc3401.call.member';

/// How long a membership that names no expiry lasts, as matrix-js-sdk has it.
const _defaultExpiry = 4 * 60 * 60 * 1000;

/// Who is in a call: [userIds] with whoever joined first coming first, the
/// [devices] each of them is in it on, and when the soonest of their
/// memberships runs out.
typedef CallOccupancy = ({
  List<String> userIds,
  Map<String, Set<String>> devices,
  DateTime? nextExpiry,
});

/// One device's membership of a call: whose, on which device, and from when
/// to when, in milliseconds since the epoch.
typedef _Membership = ({String userId, String device, int start, int end});

/// [event] as a membership of the room's own call. Null when it is not one:
/// emptied on leaving, another application's or call's, or malformed.
_Membership? _membership(MatrixEvent event) {
  if (event.content case {
    'application': 'm.call',
    'call_id': '',
    'device_id': final String device,
    'focus_active': {'type': String _},
  }) {
    final expires = event.content['expires'] ?? _defaultExpiry;
    final created =
        event.content['created_ts'] ??
        event.originServerTs.millisecondsSinceEpoch;
    if (expires is num && expires > 0 && created is num) {
      final start = created.toInt();
      return (
        userId: event.senderId,
        device: device,
        start: start,
        end: start + expires.toInt(),
      );
    }
  }
  return null;
}

/// The users with a membership in the room's own call that has not run out
/// by [now].
CallOccupancy callOccupancy(Iterable<MatrixEvent> events, DateTime now) {
  final live = [
    for (final event in events)
      if (_membership(event) case final membership?
          when membership.end > now.millisecondsSinceEpoch)
        membership,
  ];

  final arrived = <String, int>{};
  final devices = <String, Set<String>>{};
  for (final membership in live) {
    arrived.update(
      membership.userId,
      (earliest) => min(earliest, membership.start),
      ifAbsent: () => membership.start,
    );
    (devices[membership.userId] ??= {}).add(membership.device);
  }
  final inOrder = arrived.entries.toList()
    ..sort((a, b) {
      final order = a.value.compareTo(b.value);
      return order != 0 ? order : a.key.compareTo(b.key);
    });

  return (
    userIds: [for (final entry in inOrder) entry.key],
    devices: devices,
    nextExpiry: live.isEmpty
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            live.map((membership) => membership.end).reduce(min),
            isUtc: true,
          ),
  );
}
