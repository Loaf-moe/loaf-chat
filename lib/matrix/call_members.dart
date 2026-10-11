/// Who is in a room's call, read from its MatrixRTC membership state the way
/// Element Call writes it: one event per device, emptied on leaving.
library;

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

/// The users with a membership in the room's own call that has not run out
/// by [now].
CallOccupancy callOccupancy(Iterable<MatrixEvent> events, DateTime now) {
  final joined = <String, int>{};
  final devices = <String, Set<String>>{};
  int? soonest;
  for (final event in events) {
    final content = event.content;
    if (content['application'] != 'm.call') continue;
    if (content['call_id'] != '') continue;
    final device = content['device_id'];
    if (device is! String) continue;
    final focus = content['focus_active'];
    if (focus is! Map || focus['type'] is! String) continue;
    final expires = content['expires'] ?? _defaultExpiry;
    if (expires is! num || expires <= 0) continue;
    final created = content['created_ts'];
    if (created != null && created is! num) continue;
    final start = created is num
        ? created.toInt()
        : event.originServerTs.millisecondsSinceEpoch;
    final end = start + expires.toInt();
    if (end <= now.millisecondsSinceEpoch) continue;
    final earlier = joined[event.senderId];
    if (earlier == null || start < earlier) joined[event.senderId] = start;
    (devices[event.senderId] ??= {}).add(device);
    if (soonest == null || end < soonest) soonest = end;
  }
  final userIds = joined.keys.toList()
    ..sort((a, b) {
      final order = joined[a]!.compareTo(joined[b]!);
      return order != 0 ? order : a.compareTo(b);
    });
  return (
    userIds: userIds,
    devices: devices,
    nextExpiry: soonest == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(soonest, isUtc: true),
  );
}
