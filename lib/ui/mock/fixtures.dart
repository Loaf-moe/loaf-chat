/// Plain models and fake data for the UI mockups.
///
/// These are the shape the widgets render. Nothing here talks to the network
/// or to matrix-dart-sdk; when the SDK is wired in it fills these same
/// constructors, so the widget tree does not change.
library;

import 'package:flutter/material.dart';

// ── Models ─────────────────────────────────────────────────────────────────

enum ChannelKind { text, voice }

/// What a member may do in a room, bucketed from their Matrix power level.
/// Drives name colour everywhere — see "Name colour" in the design spec.
enum Role { admin, moderator, member }

class Member {
  const Member(
    this.id,
    this.name,
    this.color, {
    this.online = true,
    this.powerLevel = 0,
  });

  final String id;
  final String name;

  /// Avatar fallback background only — never a name colour. Matrix has no
  /// user-chosen colour; real clients derive this from a hash of the MXID,
  /// and these hardcoded values stand in for that.
  final Color color;

  final bool online;

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
}

class Reaction {
  const Reaction(this.emoji, this.count, {this.mine = false});

  final String emoji;
  final int count;
  final bool mine;
}

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

  Message copyWith({List<Reaction>? reactions}) => Message(
    id: id,
    author: author,
    sentAt: sentAt,
    body: body,
    reactions: reactions ?? this.reactions,
    edited: edited,
    replyTo: replyTo,
    imageAspect: imageAspect,
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

  Channel copyWith({bool? joined}) => Channel(
    id: id,
    name: name,
    kind: kind,
    unread: unread,
    mentions: mentions,
    private: private,
    topic: topic,
    occupants: occupants,
    joined: joined ?? this.joined,
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

  /// This space as it looks after joining the channels in [ids] — the mock's
  /// stand-in for membership arriving over sync.
  Space withJoined(Set<String> ids) => Space(
    id: id,
    name: name,
    color: color,
    members: members,
    unread: unread,
    mentions: mentions,
    categories: [
      for (final category in categories)
        ChannelCategory(category.name, [
          for (final channel in category.channels)
            ids.contains(channel.id) ? channel.copyWith(joined: true) : channel,
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
    } else if (group.isNotEmpty) {
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
const _mika = Member('@mika', 'Mika Rye', Color(0xFF4E9E76));
const _sam = Member('@sam', 'Sam Poolish', Color(0xFF3B82F6));
const _jun = Member('@jun', 'Jun Levain', Color(0xFFD97B2A), powerLevel: 50);
const _ada = Member('@ada', 'Ada Crumb', Color(0xFF8B5CF6), online: false);

// Only in member lists, never in the timeline — enough people that the
// offline half of a list has something to show.
const _rosa = Member('@rosa', 'Rosa Brioche', Color(0xFFDB2777), online: false);
const _theo = Member('@theo', 'Theo Crust', Color(0xFF0891B2));
const _pim = Member('@pim', 'Pim Focaccia', Color(0xFF65A30D), online: false);

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
