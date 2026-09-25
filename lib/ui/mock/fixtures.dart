/// Plain models and fake data for the UI mockups.
///
/// These are the shape the widgets render. Nothing here talks to the network
/// or to matrix-dart-sdk; when the SDK is wired in it fills these same
/// constructors, so the widget tree does not change.
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

class Member {
  const Member(
    this.id,
    this.name,
    this.color, {
    this.presence = Presence.online,
    this.statusMessage,
    this.powerLevel = 0,
  });

  final String id;
  final String name;

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

  String get initials {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length == 1) return parts.first.characters.first.toUpperCase();
    return (parts.first.characters.first + parts.last.characters.first)
        .toUpperCase();
  }

  Member copyWith({Presence? presence, String? statusMessage}) => Member(
    id,
    name,
    color,
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
  });

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
  });

  final String id;
  final String name;
  final ChannelKind kind;
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
    this.unread = 0,
    this.mentions = 0,
  });

  final String id;
  final String name;
  final Color color;
  final List<ChannelCategory> categories;
  final List<Member> members;
  final int unread;
  final int mentions;

  String get initials => name
      .trim()
      .split(RegExp(r'\s+'))
      .take(2)
      .map((w) => w.characters.first)
      .join()
      .toUpperCase();

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
    members: members,
    unread: this.unread,
    mentions: mentions,
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

// ── Fixture data ───────────────────────────────────────────────────────────

const _you = Member('@faore', 'faore', Color(0xFFD62828), powerLevel: 100);
const _mika = Member(
  '@mika',
  'Mika Rye',
  Color(0xFF4E9E76),
  statusMessage: 'proofing overnight',
);
const _sam = Member(
  '@sam',
  'Sam Poolish',
  Color(0xFF3B82F6),
  presence: Presence.dnd,
  statusMessage: 'deep in a sourdough experiment',
);
const _jun = Member(
  '@jun',
  'Jun Levain',
  Color(0xFFD97B2A),
  presence: Presence.idle,
  powerLevel: 50,
);
const _ada = Member(
  '@ada',
  'Ada Crumb',
  Color(0xFF8B5CF6),
  presence: Presence.offline,
);

// Only in member lists, never in the timeline — enough people that the
// offline half of a list has something to show.
const _rosa = Member(
  '@rosa',
  'Rosa Brioche',
  Color(0xFFDB2777),
  presence: Presence.offline,
);
const _theo = Member('@theo', 'Theo Crust', Color(0xFF0891B2));
const _pim = Member(
  '@pim',
  'Pim Focaccia',
  Color(0xFF65A30D),
  presence: Presence.offline,
);

const mockMembers = [_you, _mika, _sam, _jun, _ada];
const currentUser = _you;

final mockSpaces = <Space>[
  Space(
    id: 'starter',
    name: 'The Starter Pack',
    color: const Color(0xFFD97B2A),
    unread: 12,
    mentions: 3,
    members: const [_you, _mika, _sam, _jun, _ada, _rosa, _theo, _pim],
    categories: [
      ChannelCategory('general', [
        const Channel(
          id: 'general',
          name: 'general',
          unread: 4,
          topic: 'the everything channel. be nice, bring snacks.',
        ),
        const Channel(
          id: 'announcements',
          name: 'announcements',
          joined: false,
        ),
        const Channel(id: 'kitchen', name: 'kitchen', unread: 8, mentions: 3),
        const Channel(id: 'recipes', name: 'recipes'),
        const Channel(id: 'planning', name: 'planning', private: true),
      ]),
      ChannelCategory('voice', [
        Channel(
          id: 'hangout',
          name: 'the hangout',
          kind: ChannelKind.voice,
          occupants: const [_mika, _sam, _jun],
        ),
        const Channel(
          id: 'focus',
          name: 'quiet baking',
          kind: ChannelKind.voice,
        ),
        const Channel(
          id: 'late',
          name: 'late night vc',
          kind: ChannelKind.voice,
          joined: false,
        ),
      ]),
      // A Matrix subspace, rendered as a category.
      ChannelCategory('game night', [
        const Channel(id: 'codenames', name: 'codenames'),
        const Channel(id: 'chess', name: 'chess', unread: 2),
        Channel(
          id: 'game-voice',
          name: 'game night vc',
          kind: ChannelKind.voice,
          occupants: const [_ada],
        ),
        const Channel(id: 'poker', name: 'poker', joined: false),
      ]),
    ],
  ),
  Space(
    id: 'ryedevs',
    name: 'Rye Devs',
    color: const Color(0xFF3B82F6),
    unread: 2,
    members: const [_you, _sam, _theo],
    categories: [
      ChannelCategory('dev', [
        const Channel(id: 'loaf-native', name: 'loaf-native', unread: 2),
        const Channel(id: 'infra', name: 'infra'),
        Channel(
          id: 'pairing',
          name: 'pairing',
          kind: ChannelKind.voice,
          occupants: const [_sam],
        ),
      ]),
    ],
  ),
  Space(
    id: 'bookclub',
    name: 'Book Club',
    color: const Color(0xFF8B5CF6),
    mentions: 1,
    members: const [_ada, _you, _mika, _rosa],
    categories: [
      ChannelCategory('reading', [
        const Channel(id: 'current', name: 'current-read', mentions: 1),
        const Channel(id: 'tangents', name: 'tangents'),
      ]),
    ],
  ),
];

// The server's own bot, which answers `!admin` commands in the admin room.
const _tuwunel = Member(
  '@tuwunel',
  'tuwunel',
  Color(0xFF64748B),
  powerLevel: 100,
);

DateTime _ago({int days = 0, int hours = 0}) =>
    DateTime.now().subtract(Duration(days: days, hours: hours));

/// Everything that lives in Home: DMs, and joined rooms that belong to no
/// space. Home's sections are worked out from these by `homeSections`.
final mockHomeRooms = <Channel>[
  Channel(
    id: 'dm-mika',
    name: 'Mika Rye',
    kind: ChannelKind.direct,
    members: const [_mika],
    unread: 1,
    favourite: true,
    favouriteOrder: 0.5,
    lastActivity: _ago(hours: 2),
  ),
  Channel(
    id: 'dm-crew',
    name: 'weekend crew',
    kind: ChannelKind.direct,
    members: const [_mika, _jun, _sam],
    lastActivity: _ago(days: 2),
  ),
  Channel(
    id: 'dm-sam',
    name: 'Sam Poolish',
    kind: ChannelKind.direct,
    members: const [_sam],
    lastActivity: _ago(days: 3),
  ),
  // An older 1:1 with Sam that another client made: a duplicate, which Home
  // folds into Sam's one row.
  Channel(
    id: 'dm-sam-old',
    name: 'Sam Poolish',
    kind: ChannelKind.direct,
    members: const [_sam],
    unread: 2,
    lastActivity: _ago(days: 40),
  ),
  Channel(
    id: 'dm-ada',
    name: 'Ada Crumb',
    kind: ChannelKind.direct,
    members: const [_ada],
    lastActivity: _ago(days: 5),
  ),
  // tuwunel's admin room: an ordinary room in no space, where commands to
  // the server bot are sent as messages.
  const Channel(
    id: 'admins',
    name: 'admins',
    kind: ChannelKind.room,
    topic: 'loaf.moe server admin. commands start with !admin',
    members: [_you, _tuwunel],
  ),
  const Channel(
    id: 'fermentation',
    name: 'fermentation nerds',
    kind: ChannelKind.room,
    topic: 'koji, kombucha, kimchi, and whatever that jar is',
    members: [_you, _mika, _theo, _pim],
    unread: 3,
  ),
  const Channel(
    id: 'breadtalk',
    name: 'bread talk (public)',
    kind: ChannelKind.room,
    topic: 'the big public bread room on matrix.org',
    members: [_you, _rosa, _theo, _pim, _ada],
    unread: 12,
    lowPriority: true,
  ),
];

/// The Home pseudo-space itself. Its one category is unsorted: the shell
/// regroups the rooms into sections with this session's tags applied.
final mockHome = Space(
  id: 'home',
  name: 'Home',
  color: const Color(0xFF003049),
  members: const [_you, _mika, _sam, _ada, _jun],
  categories: [ChannelCategory('home', mockHomeRooms)],
);

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

const _sourdough = Space(
  id: 'sourdough',
  name: 'Sourdough Society',
  color: Color(0xFF65A30D),
  members: [_theo, _you, _pim, _rosa],
  categories: [
    ChannelCategory('welcome', [
      Channel(
        id: 'sourdough-welcome',
        name: 'welcome',
        topic: 'say hi, share your starter\'s name',
      ),
      Channel(id: 'crumb-shots', name: 'crumb-shots'),
    ]),
  ],
);

final mockInvites = <Invite>[
  Invite(
    id: 'invite-rosa',
    kind: InviteKind.direct,
    name: 'Rosa Brioche',
    inviter: _rosa,
    color: _rosa.color,
    room: Channel(
      id: 'dm-rosa',
      name: 'Rosa Brioche',
      kind: ChannelKind.direct,
      members: const [_rosa],
      lastActivity: _ago(hours: 1),
    ),
  ),
  Invite(
    id: 'invite-sourdough',
    kind: InviteKind.space,
    name: 'Sourdough Society',
    inviter: _theo,
    color: Color(0xFF65A30D),
    topic: 'starters, schedules, and crumb shots',
    memberCount: 128,
    space: _sourdough,
  ),
];

/// A little history per DM and room, with a past call or two among the
/// messages.
List<Message> mockHomeTimeline(String id) {
  final now = DateTime.now();
  DateTime at(int daysAgo, int hour, int minute) =>
      DateTime(now.year, now.month, now.day - daysAgo, hour, minute);

  return switch (id) {
    'dm-mika' => [
      Message(
        id: '$id-1',
        author: _mika,
        sentAt: at(1, 21, 40),
        body: 'are you up? doughlores is doing something weird',
      ),
      Message(
        id: '$id-2',
        author: _you,
        sentAt: at(1, 21, 44),
        body: 'calling you',
      ),
      Message(
        id: '$id-3',
        author: _mika,
        sentAt: at(1, 22, 3),
        body: 'call · 18m',
        callLine: CallLine.ended,
      ),
      Message(
        id: '$id-4',
        author: _mika,
        sentAt: at(0, 8, 12),
        body: 'she lives!! thank you',
      ),
    ],
    'dm-crew' => [
      Message(
        id: '$id-1',
        author: _jun,
        sentAt: at(2, 18, 0),
        body: 'bake-along saturday? i have too much flour',
      ),
      Message(
        id: '$id-2',
        author: _sam,
        sentAt: at(2, 18, 20),
        body: "i'm in, starting the levain friday night",
      ),
      Message(id: '$id-3', author: _mika, sentAt: at(2, 18, 21), body: 'same'),
    ],
    'dm-sam' => [
      Message(
        id: '$id-1',
        author: _sam,
        sentAt: at(3, 14, 2),
        body: 'missed call',
        callLine: CallLine.missed,
      ),
      Message(
        id: '$id-2',
        author: _sam,
        sentAt: at(3, 14, 5),
        body: 'sorry, hands in dough. later?',
      ),
    ],
    'admins' => [
      Message(
        id: '$id-1',
        author: _you,
        sentAt: at(1, 22, 10),
        body: '!admin server uptime',
      ),
      Message(
        id: '$id-2',
        author: _tuwunel,
        sentAt: at(1, 22, 10),
        body: 'Server has been running for 12 days, 4 hours and 31 minutes.',
      ),
      Message(
        id: '$id-3',
        author: _you,
        sentAt: at(0, 9, 2),
        body: '!admin users list-users',
      ),
      Message(
        id: '$id-4',
        author: _tuwunel,
        sentAt: at(0, 9, 2),
        body:
            'Found 8 local user account(s): @faore, @mika, @sam, @jun, '
            '@ada, @rosa, @theo, @pim',
      ),
    ],
    'fermentation' => [
      Message(
        id: '$id-1',
        author: _theo,
        sentAt: at(0, 7, 40),
        body: 'the koji is fuzzy in the good way this time',
      ),
      Message(
        id: '$id-2',
        author: _pim,
        sentAt: at(0, 8, 5),
        body: 'pics or it is the bad fuzzy',
      ),
    ],
    'breadtalk' => [
      Message(
        id: '$id-1',
        author: _rosa,
        sentAt: at(0, 6, 30),
        body: 'hydration debate round 400: go',
      ),
    ],
    'dm-rosa' => [
      Message(
        id: '$id-1',
        author: _rosa,
        sentAt: at(0, 11, 0),
        body: 'hi! saw your crumb shot in the starter pack, had to say hello',
      ),
    ],
    'dm-sam-old' => [
      Message(
        id: '$id-1',
        author: _sam,
        sentAt: at(40, 19, 12),
        body: 'did you ever try the rye sour from that book?',
      ),
      Message(
        id: '$id-2',
        author: _sam,
        sentAt: at(40, 19, 13),
        body: 'the one with the ridiculous cover',
      ),
    ],
    'dm-ada' => [
      Message(
        id: '$id-1',
        author: _ada,
        sentAt: at(5, 11, 0),
        body: 'lending you my banneton, collect whenever',
      ),
    ],
    // A DM you just started has no history yet.
    _ => const [],
  };
}

/// A day's worth of conversation in #general, built to exercise the timeline:
/// grouped runs, a reply, an image, reactions, a long message and a short one.
List<Message> mockTimeline() {
  final now = DateTime.now();
  DateTime at(int daysAgo, int hour, int minute) =>
      DateTime(now.year, now.month, now.day - daysAgo, hour, minute);

  final starter = Message(
    id: 'm1',
    author: _mika,
    sentAt: at(1, 19, 2),
    body:
        'my starter finally doubled in four hours. four! it took three weeks '
        'of feeding it twice a day and honestly i was about to give up on it '
        'last weekend.',
    reactions: const [Reaction('🎉', 4, mine: true), Reaction('🍞', 2)],
  );

  return [
    starter,
    Message(
      id: 'm2',
      author: _mika,
      sentAt: at(1, 19, 3),
      body: 'naming her Doughlores',
      reactions: const [Reaction('😂', 6)],
    ),
    Message(
      id: 'm3',
      author: _sam,
      sentAt: at(1, 19, 11),
      body: 'incredible name. what flour did you settle on in the end?',
    ),
    Message(
      id: 'm4',
      author: _mika,
      sentAt: at(1, 19, 14),
      body: 'half rye half bread flour, 1:1:1 by weight',
    ),
    Message(
      id: 'm5',
      author: _jun,
      sentAt: at(0, 9, 30),
      body: 'morning. the oven is fixed 🔧',
    ),
    Message(
      id: 'm6',
      author: _jun,
      sentAt: at(0, 9, 31),
      body:
          'turned out the thermostat was reading 40 degrees low the whole '
          'time, which explains a lot about january',
      reactions: const [Reaction('💀', 3)],
    ),
    Message(
      id: 'm7',
      author: _sam,
      sentAt: at(0, 10, 2),
      body:
          'so every loaf since new year was underbaked on purpose by a '
          'broken sensor. beautiful.',
      replyTo: Message(
        id: 'm6',
        author: _jun,
        sentAt: at(0, 9, 31),
        body: 'turned out the thermostat was reading 40 degrees low',
      ),
    ),
    Message(
      id: 'm8',
      author: _ada,
      sentAt: at(0, 10, 15),
      body: 'first bake on the fixed oven',
      imageAspect: 4 / 3,
      reactions: const [
        Reaction('😍', 7, mine: true),
        Reaction('🔥', 3),
        Reaction('🥖', 1),
      ],
    ),
    Message(
      id: 'm9',
      author: _you,
      sentAt: at(0, 10, 18),
      body: 'ok that crumb is unreasonable',
      edited: true,
    ),
  ];
}

/// The channel the mockups open on.
final mockActiveChannel = mockSpaces.first.categories.first.channels.first;

/// The voice channel the connected-call bar reports, when connected.
final mockConnectedChannel = mockSpaces.first.categories[1].channels.first;

// ── Space directory ────────────────────────────────────────────────────────

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

const _pizza = Space(
  id: 'pizza',
  name: 'Pizza Night',
  color: Color(0xFFDC2626),
  members: [_rosa, _theo, _you],
  categories: [
    ChannelCategory('', [
      Channel(id: 'pizza-general', name: 'general'),
      Channel(id: 'pizza-dough', name: 'dough-balls'),
      Channel(id: 'pizza-oven', name: 'oven-talk', kind: ChannelKind.voice),
    ]),
  ],
);

const _glutenFree = Space(
  id: 'gf-crew',
  name: 'Gluten-Free Crew',
  color: Color(0xFF0D9488),
  members: [_pim, _ada, _you],
  categories: [
    ChannelCategory('', [
      Channel(id: 'gf-general', name: 'general'),
      Channel(id: 'gf-flours', name: 'flour-blends'),
    ]),
  ],
);

const _openBakers = Space(
  id: 'open-bakers',
  name: 'Open Bakers',
  color: Color(0xFF2563EB),
  members: [_you],
  categories: [
    ChannelCategory('', [
      Channel(id: 'open-general', name: 'general'),
      Channel(id: 'open-help', name: 'help'),
    ]),
  ],
);

const _staff = Space(
  id: 'staff',
  name: 'loaf.moe staff',
  color: Color(0xFF64748B),
);

/// Each server's public space directory, as `/publicRooms` filtered to
/// `m.space` would return it.
final mockDirectories = <String, List<SpacePreview>>{
  'loaf.moe': [
    const SpacePreview(
      alias: '#sourdough:loaf.moe',
      space: _sourdough,
      topic: 'starters, schedules, and crumb shots',
      memberCount: 128,
    ),
    SpacePreview(
      alias: '#starterpack:loaf.moe',
      space: mockSpaces.first,
      topic: 'the everything space. be nice, bring snacks.',
      memberCount: 8,
    ),
    const SpacePreview(
      alias: '#pizza:loaf.moe',
      space: _pizza,
      topic: 'friday dough, saturday pies',
      memberCount: 23,
    ),
    const SpacePreview(
      alias: '#glutenfree:loaf.moe',
      space: _glutenFree,
      topic: 'yes it can be good. no, really.',
      memberCount: 41,
    ),
  ],
  'matrix.org': [
    const SpacePreview(
      alias: '#bakers:matrix.org',
      space: _openBakers,
      topic: 'the big open bread space on matrix',
      memberCount: 2140,
    ),
  ],
};

/// Every address the mock can resolve: the directories, plus a space that
/// is listed nowhere and joinable only by invite.
Map<String, SpacePreview> get mockSpaceAddresses => {
  for (final entries in mockDirectories.values)
    for (final entry in entries) entry.alias: entry,
  '#staff:loaf.moe': const SpacePreview(
    alias: '#staff:loaf.moe',
    space: _staff,
    topic: 'people who keep the ovens on',
    memberCount: 3,
    inviteOnly: true,
  ),
};

/// History for channels in spaces joined this session. A space you have
/// just made has none.
List<Message> mockSpaceTimeline(String channelId) {
  final now = DateTime.now();
  return switch (channelId) {
    'pizza-general' => [
      Message(
        id: '$channelId-1',
        author: _rosa,
        sentAt: now.subtract(const Duration(hours: 3)),
        body: 'who is bringing the good tomatoes this week',
      ),
      Message(
        id: '$channelId-2',
        author: _theo,
        sentAt: now.subtract(const Duration(hours: 2)),
        body: 'me, and a regrettable amount of basil',
      ),
    ],
    _ => const [],
  };
}
