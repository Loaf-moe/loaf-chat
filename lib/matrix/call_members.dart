/// Who is in a room's call, read from its MatrixRTC membership state the way
/// Element Call writes it: one event per device, emptied on leaving.
library;

import 'package:matrix/matrix.dart';

const callMemberType = 'org.matrix.msc3401.call.member';

/// How long a membership that names no expiry lasts, as matrix-js-sdk has it.
const _defaultExpiry = 4 * 60 * 60 * 1000;

/// The users with a membership in the room's own call that has not run out
/// by [now], whoever joined first coming first, and when the soonest of
/// those memberships runs out.
({List<String> userIds, DateTime? nextExpiry}) callOccupancy(
  Iterable<MatrixEvent> events,
  DateTime now,
) {
  final joined = <String, int>{};
  int? soonest;
  for (final event in events) {
    final content = event.content;
    if (content['application'] != 'm.call') continue;
    if (content['call_id'] != '') continue;
    if (content['device_id'] is! String) continue;
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
    if (soonest == null || end < soonest) soonest = end;
  }
  final userIds = joined.keys.toList()
    ..sort((a, b) {
      final order = joined[a]!.compareTo(joined[b]!);
      return order != 0 ? order : a.compareTo(b);
    });
  return (
    userIds: userIds,
    nextExpiry: soonest == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(soonest, isUtc: true),
  );
}
