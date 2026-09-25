/// Rules for direct messages that keep Home to one conversation per person.
///
/// Matrix does not stop two 1:1 rooms with the same person existing —
/// another client, or both people starting a DM at once, is enough — so
/// loaf folds duplicates together and never makes new ones itself. Pure,
/// so the rules are testable apart from any widget.
library;

import '../mock/fixtures.dart';

bool _oneToOne(Channel c) =>
    c.kind == ChannelKind.direct && c.members.length == 1;

DateTime _when(Channel c) =>
    c.lastActivity ?? DateTime.fromMillisecondsSinceEpoch(0);

/// A person's 1:1 rooms, newest first. Group DMs they are in do not count.
List<Channel> existingWith(Member person, Iterable<Channel> rooms) => [
  for (final room in rooms)
    if (_oneToOne(room) && room.members.single.id == person.id) room,
]..sort((a, b) => _when(b).compareTo(_when(a)));

/// One row per person for 1:1 DMs: the newest room stands for them, carries
/// the others in [Channel.earlier], and counts every one's unreads so an
/// old conversation can't go quietly unread. Everything else passes
/// through in place.
List<Channel> collapseDuplicates(List<Channel> rooms) {
  final byPerson = <String, List<Channel>>{};
  for (final room in rooms) {
    if (_oneToOne(room)) {
      (byPerson[room.members.single.id] ??= []).add(room);
    }
  }
  final emitted = <String>{};
  return [
    for (final room in rooms)
      if (!_oneToOne(room))
        room
      else if (emitted.add(room.members.single.id))
        _fold(
          existingWith(room.members.single, byPerson[room.members.single.id]!),
        ),
  ];
}

Channel _fold(List<Channel> newestFirst) {
  final newest = newestFirst.first;
  final older = newestFirst.skip(1).toList();
  return newest.copyWith(
    unread: newestFirst.fold<int>(0, (sum, r) => sum + r.unread),
    mentions: newestFirst.fold<int>(0, (sum, r) => sum + r.mentions),
    earlier: older,
  );
}

/// What the new-message picker's button will do for the people picked.
sealed class StartMessage {
  const StartMessage();

  /// The button's words.
  String get label;
}

/// A conversation with exactly these people already exists: open it.
class OpenExisting extends StartMessage {
  const OpenExisting(this.room);

  final Channel room;

  @override
  String get label => room.members.length == 1 ? 'open' : 'open ${room.name}';
}

/// Nothing to reuse: invite these people to a new DM.
class CreateDirect extends StartMessage {
  const CreateDirect(this.members);

  final List<Member> members;

  @override
  String get label => members.length == 1 ? 'message' : 'start group';
}

/// Reuse wins over creating whenever it can: the newest 1:1 room with one
/// person, or a group DM with exactly the people picked. Null when nobody
/// is picked.
StartMessage? startMessage(List<Member> picked, Iterable<Channel> rooms) {
  if (picked.isEmpty) return null;
  if (picked.length == 1) {
    final existing = existingWith(picked.single, rooms);
    return existing.isEmpty
        ? CreateDirect(picked)
        : OpenExisting(existing.first);
  }
  final wanted = {for (final m in picked) m.id};
  final group =
      rooms
          .where(
            (r) =>
                r.kind == ChannelKind.direct &&
                r.members.length == wanted.length &&
                r.members.every((m) => wanted.contains(m.id)),
          )
          .toList()
        ..sort((a, b) => _when(b).compareTo(_when(a)));
  return group.isEmpty ? CreateDirect(picked) : OpenExisting(group.first);
}

/// "active today", "active yesterday", "active 3 days ago".
String activeLabel(DateTime when, DateTime now) {
  DateTime day(DateTime d) => DateTime(d.year, d.month, d.day);
  final days = day(now).difference(day(when)).inDays;
  return switch (days) {
    <= 0 => 'active today',
    1 => 'active yesterday',
    _ => 'active $days days ago',
  };
}
