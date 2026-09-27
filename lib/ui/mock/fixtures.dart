/// Fake data for the UI mockups, and for the mock backend that stays
/// behind the real one for tests, previews and the debug levers. The
/// models themselves live in `lib/ui/model/models.dart`.
library;

import 'package:flutter/material.dart';

import '../members/presence.dart';
import '../model/models.dart';

export '../model/models.dart';

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

// People on matrix.org, which runs with presence switched off: nothing about
// them ever arrives, so loaf draws no presence rather than "offline".
const _proofer = Member(
  '@proofer:matrix.org',
  'proofer',
  Color(0xFFCA8A04),
  presence: Presence.unknown,
);
const _lamination = Member(
  '@lamination:matrix.org',
  'lamination',
  Color(0xFF7C3AED),
  presence: Presence.unknown,
  powerLevel: 100,
);

const _openBakers = Space(
  id: 'open-bakers',
  name: 'Open Bakers',
  color: Color(0xFF2563EB),
  members: [_you, _proofer, _lamination],
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
