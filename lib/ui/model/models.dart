/// The plain models the widgets render. Nothing here talks to the network
/// or to matrix-dart-sdk: the mock fills these constructors from fixtures,
/// and `lib/matrix/` fills them from the SDK, so the widget tree is the same
/// either way.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../members/presence.dart';

// ── Models ─────────────────────────────────────────────────────────────────

/// A direct chat is a Matrix room flagged in `m.direct`; a room is one you
/// have joined that belongs to no space you are in. Both live in the Home
/// pseudo-space rather than in any space's channel list.
enum ChannelKind { text, voice, direct, room }

/// What a member may do in a room, bucketed from their Matrix power level.
/// Drives name colour everywhere — see "Name colour" in the design spec.
enum Role { admin, moderator, member }

/// Where someone's or something's picture lives. Opaque to the UI: only
/// the backend that made it can turn it into an image.
@immutable
class AvatarRef {
  const AvatarRef(this.value);

  final String value;

  static AvatarRef? maybe(String? v) =>
      v == null || v.isEmpty ? null : AvatarRef(v);

  @override
  bool operator ==(Object other) => other is AvatarRef && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

class Member {
  const Member(
    this.id,
    this.name,
    this.color, {
    this.presence = Presence.online,
    this.statusMessage,
    this.powerLevel = 0,
    this.avatar,
  });

  final String id;
  final String name;

  /// Null draws the initials.
  final AvatarRef? avatar;

  /// Avatar fallback background only — never a name colour. Matrix has no
  /// user-chosen colour; real clients derive this from a hash of the MXID,
  /// and these hardcoded values stand in for that.
  final Color color;

  final Presence presence;

  /// Matrix `status_msg`: free text, no expiry.
  final String? statusMessage;

  bool get online => presence.around;

  /// Matrix `m.room.power_levels` value for this user.
  final int powerLevel;

  /// Matrix's own conventional thresholds: 100 is admin, 50 is moderator.
  Role get role => switch (powerLevel) {
    >= 100 => Role.admin,
    >= 50 => Role.moderator,
    _ => Role.member,
  };

  /// '?' for a name with nothing in it, which a server will happily send.
  String get initials {
    final parts = _words(name);
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.characters.first.toUpperCase();
    return (parts.first.characters.first + parts.last.characters.first)
        .toUpperCase();
  }

  Member copyWith({
    String? name,
    Presence? presence,
    String? statusMessage,
    AvatarRef? avatar,
  }) => Member(
    id,
    name ?? this.name,
    color,
    avatar: avatar ?? this.avatar,
    presence: presence ?? this.presence,
    // Empty clears it; null keeps it.
    statusMessage: statusMessage == null
        ? this.statusMessage
        : (statusMessage.isEmpty ? null : statusMessage),
    powerLevel: powerLevel,
  );
}

class Reaction {
  const Reaction(this.emoji, this.count, {this.mine = false});

  final String emoji;
  final int count;
  final bool mine;
}

/// The two looks a call's system line takes in a DM timeline.
enum CallLine { ended, missed }

/// Where a message you wrote is on its way to the server. Everyone else's
/// messages, and yours once the server has them, are [sent].
enum MessageStatus { sent, sending, failed }

class Message {
  const Message({
    required this.id,
    required this.author,
    required this.sentAt,
    required this.body,
    this.reactions = const [],
    this.edited = false,
    this.replyTo,
    this.imageAspect,
    this.callLine,
    this.status = MessageStatus.sent,
    this.locked = false,
    this.stub = false,
  });

  /// A reply's quote of a message that is not loaded, or no longer there:
  /// who wrote it, where that is known, and nothing of what it said.
  Message.stub({required this.id, required this.author})
    : sentAt = DateTime.utc(1970),
      body = '',
      reactions = const [],
      edited = false,
      replyTo = null,
      imageAspect = null,
      callLine = null,
      status = MessageStatus.sent,
      locked = false,
      stub = true;

  final String id;
  final Member author;
  final DateTime sentAt;
  final String body;
  final List<Reaction> reactions;
  final bool edited;

  /// The message this one replies to, if any.
  final Message? replyTo;

  /// Set when the message is an image; the mockups draw a placeholder of this
  /// aspect ratio rather than loading anything.
  final double? imageAspect;

  /// Set when this is a line a call left behind rather than something
  /// anyone said; [body] is then its label, such as "call · 12m".
  final CallLine? callLine;

  final MessageStatus status;

  /// Encrypted, and this device cannot read it yet. [body] is empty.
  final bool locked;

  /// See [Message.stub].
  final bool stub;

  Message copyWith({List<Reaction>? reactions, String? body, bool? edited}) =>
      Message(
        id: id,
        author: author,
        sentAt: sentAt,
        body: body ?? this.body,
        reactions: reactions ?? this.reactions,
        edited: edited ?? this.edited,
        replyTo: replyTo,
        imageAspect: imageAspect,
        callLine: callLine,
        status: status,
        locked: locked,
        stub: stub,
      );
}

class Channel {
  const Channel({
    required this.id,
    required this.name,
    this.kind = ChannelKind.text,
    this.unread = 0,
    this.mentions = 0,
    this.private = false,
    this.topic,
    this.occupants = const [],
    this.joined = true,
    this.muted = false,
    this.members = const [],
    this.favourite = false,
    this.favouriteOrder,
    this.lowPriority = false,
    this.lastActivity,
    this.earlier = const [],
    this.waitingFor = const [],
    this.avatar,
  });

  final String id;
  final String name;
  final ChannelKind kind;

  /// Null draws the initials.
  final AvatarRef? avatar;
  final int unread;
  final int mentions;
  final bool private;
  final String? topic;

  /// Who is currently in a voice channel. Live from MatrixRTC membership
  /// state, so it is populated without joining the call.
  final List<Member> occupants;

  /// False for a channel the space offers but you are not in yet. Only
  /// channels you could join in one tap (public, or restricted to the
  /// space's members) are ever listed — see "Joining a space" in the spec.
  final bool joined;

  /// Mentions still reach you; nothing else does. A single toggle with no
  /// expiry, mapping to a mentions-only push rule.
  final bool muted;

  /// For a direct chat: everyone in it except you. One person is a 1:1
  /// DM, more is a group DM.
  final List<Member> members;

  /// The `m.favourite` room tag, and its `order` (0–1, lowest first).
  final bool favourite;
  final double? favouriteOrder;

  /// The `m.lowpriority` room tag.
  final bool lowPriority;

  /// The newest event, which is what orders DMs.
  final DateTime? lastActivity;

  /// Older 1:1 rooms with the same person, folded into this row so Home
  /// shows each person once. Matrix allows duplicates; loaf hides them.
  final List<Channel> earlier;

  /// Invited to a DM you started, and not in it yet.
  final List<Member> waitingFor;

  IconData get icon => switch (kind) {
    ChannelKind.voice => LucideIcons.volume2,
    ChannelKind.direct => LucideIcons.atSign,
    ChannelKind.room => LucideIcons.messagesSquare,
    _ when private => LucideIcons.lock,
    _ => LucideIcons.hash,
  };

  Channel copyWith({
    bool? joined,
    bool? muted,
    int? unread,
    int? mentions,
    List<Member>? occupants,
    bool? favourite,
    double? favouriteOrder,
    bool? lowPriority,
    DateTime? lastActivity,
    List<Channel>? earlier,
  }) => Channel(
    id: id,
    name: name,
    avatar: avatar,
    kind: kind,
    unread: unread ?? this.unread,
    mentions: mentions ?? this.mentions,
    private: private,
    topic: topic,
    occupants: occupants ?? this.occupants,
    joined: joined ?? this.joined,
    muted: muted ?? this.muted,
    members: members,
    favourite: favourite ?? this.favourite,
    favouriteOrder: favouriteOrder ?? this.favouriteOrder,
    lowPriority: lowPriority ?? this.lowPriority,
    lastActivity: lastActivity ?? this.lastActivity,
    earlier: earlier ?? this.earlier,
    waitingFor: waitingFor,
  );
}

/// A collapsible group in the channel list. Matrix subspaces map onto these.
class ChannelCategory {
  const ChannelCategory(this.name, this.channels);

  final String name;
  final List<Channel> channels;
}

class Space {
  const Space({
    required this.id,
    required this.name,
    required this.color,
    this.categories = const [],
    this.members = const [],
    this.avatar,
  });

  final String id;
  final String name;
  final Color color;

  /// Null draws the initials.
  final AvatarRef? avatar;
  final List<ChannelCategory> categories;
  final List<Member> members;

  /// Mentions waiting across the channels you are in. What the rail's
  /// badge shows first, since a mention is addressed to you.
  int get mentions =>
      allChannels.where((c) => c.joined).fold(0, (sum, c) => sum + c.mentions);

  /// Unread messages across the channels you are in and have not muted.
  int get unread => allChannels
      .where((c) => c.joined && !c.muted)
      .fold(0, (sum, c) => sum + c.unread);

  /// '?' for a name with nothing in it, which a server will happily send.
  String get initials {
    final parts = _words(name);
    if (parts.isEmpty) return '?';
    return parts.take(2).map((w) => w.characters.first).join().toUpperCase();
  }

  Iterable<Channel> get allChannels => categories.expand((c) => c.channels);

  /// This space with this session's changes layered over the fixtures — the
  /// mock's stand-in for membership, read markers and push rules arriving
  /// over sync. [membership] maps channel ids to joined (true) or left
  /// (false); [muted] likewise; channels in [read] have nothing unread.
  ///
  /// A left invite-only channel is dropped entirely: only channels you could
  /// join in one tap are ever listed.
  ///
  /// [occupants] replaces who is in a call, for the call you are in; [unread]
  /// adds to a channel's count, for the missed calls a DM has picked up.
  Space withSession({
    Map<String, bool> membership = const {},
    Map<String, bool> muted = const {},
    Set<String> read = const {},
    Map<String, List<Member>> occupants = const {},
    Map<String, int> unread = const {},
  }) => Space(
    id: id,
    name: name,
    color: color,
    avatar: avatar,
    members: members,
    categories: [
      for (final category in categories)
        ChannelCategory(category.name, [
          for (final channel in category.channels)
            if (!(channel.private && membership[channel.id] == false))
              channel.copyWith(
                joined: membership[channel.id],
                muted: muted[channel.id],
                // Reading clears what the fixture had; anything that lands
                // afterwards, such as a missed call, counts again.
                unread:
                    (read.contains(channel.id) ? 0 : channel.unread) +
                    (unread[channel.id] ?? 0),
                mentions: read.contains(channel.id) ? 0 : null,
                occupants: occupants[channel.id],
              ),
        ]),
    ],
  );
}

// ── Timeline grouping ──────────────────────────────────────────────────────

sealed class TimelineEntry {
  const TimelineEntry();
}

/// A "Today" / "Yesterday" / date heading.
class DaySeparator extends TimelineEntry {
  const DaySeparator(this.day);

  final DateTime day;
}

/// Consecutive messages from one author, close together in time. Only the
/// first carries an avatar and a header.
class MessageGroup extends TimelineEntry {
  const MessageGroup(this.messages);

  final List<Message> messages;

  Member get author => messages.first.author;
  DateTime get sentAt => messages.first.sentAt;
}

/// A line a call left behind. Always its own entry, never part of a group.
class CallEntry extends TimelineEntry {
  const CallEntry(this.message);

  final Message message;
}

/// How long a gap breaks a run of messages from the same author.
const groupingWindow = Duration(minutes: 5);

/// Collapses a chronological message list into day separators and author
/// groups — the thing that makes a timeline read as a conversation rather
/// than a log. Messages must already be in ascending time order.
List<TimelineEntry> groupTimeline(List<Message> messages) {
  final entries = <TimelineEntry>[];
  var group = <Message>[];
  DateTime? currentDay;

  void flush() {
    if (group.isNotEmpty) {
      entries.add(MessageGroup(group));
      group = [];
    }
  }

  for (final message in messages) {
    final day = DateUtils.dateOnly(message.sentAt);
    if (currentDay == null || day != currentDay) {
      flush();
      entries.add(DaySeparator(day));
      currentDay = day;
    }
    if (message.callLine != null) {
      flush();
      entries.add(CallEntry(message));
      continue;
    }
    if (group.isNotEmpty) {
      final previous = group.last;
      final sameAuthor = previous.author.id == message.author.id;
      final closeEnough =
          message.sentAt.difference(previous.sentAt) <= groupingWindow;
      // A reply always starts its own group: it carries context of its own
      // and reads wrong tucked under an unrelated message.
      if (!sameAuthor || !closeEnough || message.replyTo != null) flush();
    }
    group.add(message);
  }
  flush();
  return entries;
}

enum InviteKind { direct, room, space }

/// Someone asking you in. Not a room yet: until you accept, you see only
/// what the invite itself carries.
class Invite {
  const Invite({
    required this.id,
    required this.kind,
    required this.name,
    required this.inviter,
    required this.color,
    this.topic,
    this.memberCount,
    this.room,
    this.space,
  });

  final String id;
  final InviteKind kind;
  final String name;
  final Member inviter;

  /// Avatar fallback, as for spaces.
  final Color color;

  /// Only when the server's room preview offers them.
  final String? topic;
  final int? memberCount;

  /// What accepting a DM or room invite joins.
  final Channel? room;

  /// What accepting a space invite adds to the rail.
  final Space? space;

  /// The line under the invite's name. A DM invite's name already is the
  /// person, so it says what they want rather than naming them twice.
  String get summary => kind == InviteKind.direct
      ? 'wants to chat'
      : '${inviter.name} invited you';
}

/// A space seen from outside: what `/hierarchy` and `/publicRooms` tell you
/// before you join. [space] is what joining brings in.
class SpacePreview {
  const SpacePreview({
    required this.alias,
    required this.space,
    this.topic,
    this.memberCount = 0,
    this.inviteOnly = false,
  });

  final String alias;
  final Space space;
  final String? topic;
  final int memberCount;

  /// Join rule `invite`: nothing to do from here but ask someone inside.
  final bool inviteOnly;

  String get server => alias.split(':').last;
}

/// A name's words, none of them empty.
List<String> _words(String name) => [
  for (final word in name.trim().split(RegExp(r'\s+')))
    if (word.isNotEmpty) word,
];
