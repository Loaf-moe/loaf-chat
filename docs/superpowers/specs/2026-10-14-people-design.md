# Loaf Chat — People

A person's name is drawn in six places and does nothing when touched. The
member list opens a card with verify on it; a voice occupant's row has a
menu of its own; a message author has neither. This spec gives every drawn
name one widget and one menu, marks people who arrive over the Discord
bridge, lets a tap on a name mention them, and separates taking someone out
of a call from taking them out of the channel.

It is not a phase of `docs/superpowers/plans/2026-09-26-sdk-wiring-roadmap.md`.
It builds on "Name colour means power level" and "The member list" in
`2026-09-20-loaf-native-design.md`, on "Verifying other people" in
`2026-09-27-e2ee-design.md`, and on the moderation state of
`2026-10-11-voice-design.md`.

Loaf is for one closed group of friends, nearly all of them admins. Taking
someone out of a call is for the one who left for work with the call still
open; muting is for the one whose microphone picks up the kitchen. The copy
and the menu say so: no "moderator", no ban, no confirmation for anything
that can be undone with one more tap.

## Scope

**In:**

- `PersonName`: a name in its role colour, with a Discord badge after it when
  the person is a bridge puppet. Timeline author, member list, the composer's
  `@` suggestions and its reply or edit target.
- One person menu, opened from any drawn name or avatar: their card on top
  (bigger avatar, name, role, id, status), then the actions that fit where it
  was opened.
- A tap on a timeline name puts `@Name` into the composer.
- Removing someone from a call, leaving them in the channel.
- Copy that reads as between friends.

**Out:**

| Deferred | Why |
|---|---|
| Ban | A closed group of friends has nobody to ban |
| Changing someone's power level | Rare; Element does it |
| Ignoring or blocking someone | The same |
| A name or avatar per space | Decided out, 2026-10-14 |
| Named power tiers (cinny's `in.cinny.room.power_level_tags`) | Admin and moderator are the two coloured tiers, and nearly everyone is admin |
| The badge in reply quotes and call tiles | An 11px quote has no room for it; bridge puppets never join a Matrix call |
| A card on hover | Tap and right-click cover it |
| Removal obeyed by other clients | As with muting: Loaf's own state event, which Loaf clients obey |

## Findings (checked 2026-10-14)

Sources: `matrix` 13.0.0 in the pub cache, this repository at `266f868`,
cinny at `~/dev/build/loaf-chat-cinny`.

**Matrix and the bridge**

- Matrix has power levels, not roles. `Member.role` maps 100 and above to
  admin and 50 and above to moderator (`lib/ui/model/models.dart`).
- The Discord bridge on loaf.moe is OOYE. Its puppets' user ids start with
  `@_ooye_`: the appservice's namespace, which does not change. Nothing on
  `m.room.member` says a member is a puppet.
- Nobody can leave a call for someone else. A call membership
  (`org.matrix.msc3401.call.member`) has the user's id as its state key, and
  a state key that begins with `@` may only be written by that user. On the
  media side, `livekit_client` 2.13.1 has no call that removes another
  participant: that is a server API, behind a grant the call service's
  token (`lib/matrix/call_access.dart`) does not carry.
- `moe.loaf.call.moderation` (`lib/matrix/call_silence.dart`) is the
  existing answer: a moderator writes under `_@user`, and that user's own
  client obeys. A device's membership carries `created_ts`, which the device
  writes and reads back (`lib/matrix/call_membership.dart`, `_created`).
- The SDK has `Room.kick`, `Room.ban`, `Room.unban`, `Room.setPower` and
  `Client.ignoreUser`. Only `kick` is called, from `MatrixRooms.kick`.

**This repository**

- `LoafTokens.nameColor(role)` (`lib/ui/members/role_colors.dart`) is the
  one source of a name's colour, called by hand at six sites: the timeline
  author and its reply quote (`message_group_tile.dart`), the member list,
  the composer's suggestion row and target chip, and the call tile through
  its `nameColor` argument.
- `showActionMenu` takes `leading` `PopupMenuEntry`s above its actions;
  `showActionSheet` takes a `header` builder (`lib/ui/widgets/action_menu.dart`).
  `VolumeMenuEntry` (`lib/ui/call/volume_slider.dart`) is a custom entry in
  the menu already.
- `showPersonCard` (`lib/ui/members/person_card.dart`) is the member list's
  tap: avatar, name, id, status, a trust line, and verify. `AppShell._openPerson`
  runs the verification it asks for.
- The voice occupant row's menu (`lib/ui/shell/channel_list.dart`,
  `_openMenu`) offers volume, mute or deafen for everyone, and
  "kick from <channel>", which calls `Rooms.kick`: a Matrix room kick.
- The call tile's menu (`lib/ui/call/call_view.dart`) offers volume and pin.
- The composer inserts a mention in `_acceptSuggestion`
  (`lib/ui/channel/composer.dart`): the label into the text at the query,
  the `Mention` into `_picked`. Nothing outside the composer can add one.
  Reply and edit targets reach it through `Timeline.target`, which it
  listens to.
- `Rooms.createDirect([member])` returns the existing DM with exactly that
  person, or makes one.
- `AppShell` toasts "a moderator muted you" and its three siblings when
  `Calls.silenced` changes.
- Lucide carries no brand marks, and no SVG package is a dependency. Simple
  Icons publishes `discord.svg` under CC0: a 24×24 viewBox, one path with
  arcs. `rsvg-convert` is installed here, and `tool/icons/` already renders
  PNGs from SVGs beside it.

**cinny**

Its user menu offers message, copy user id, copy user link, invite, kick,
ban, block, and a power level editor. Message, copy user id and kick are
taken; the rest is in the table above.

## The bridge

`enum Bridge { discord }` in `lib/ui/model/models.dart`. `Member.bridge` is a
`Bridge?`, null for everyone who is not a puppet, and `copyWith` carries it.

Only the adapter sets it. `bridgeOf(String userId)` in `lib/matrix/bridges.dart`
returns `Bridge.discord` for an id that starts with `@_ooye_` and null
otherwise, and `MatrixRooms._member` calls it. The UI reads `member.bridge`
and never the id.

The mock fixtures hold one puppet, with a message in a channel, so the badge
is drawn in mock mode.

## The badge

`assets/icons/discord.png`, with `2.0x` and `3.0x` variants at 14, 28 and
42 pixels: Simple Icons' mark, white on transparent, rendered from
`tool/icons/discord.svg` with `rsvg-convert`. `assets/SOURCES.md` records
the source, the licence and the command.

It is drawn 14 square with `Image.asset(color: tokens.textMuted)`,
`LoafSpace.x1` after the name, with a tooltip and a semantics label of
"from Discord".

## `PersonName`

`lib/ui/members/person_name.dart`. `PersonName(member, {size, weight,
maxLines, overflow})` draws the name in `tokens.nameColor(member.role)` and
the badge after it when `member.bridge` is set. It takes the place of the
hand-rolled `Text` in the timeline author line, the member list row, the
composer's suggestion row (for a person; a channel keeps its own) and the
composer's reply or edit target. The reply quote, a `TextSpan` at 11px, and
the call tile's name chip keep calling `nameColor` and draw no badge.

## The person menu

`showPersonMenu` in `lib/ui/members/person_menu.dart` replaces
`showPersonCard`. On a computer it is `showActionMenu` at the pointer, with
the card as a leading entry; on a phone, `showActionSheet` with the card as
its header.

**The card** (`person_card.dart`, now the header alone): avatar at 64,
`PersonName` at 17, a role chip reading `admin` or `moderator` in the role's
colour (none for a member), the id in mono, the status line, and for someone
else the trust line as today.

**The actions**, in this order. The caller passes what it can honour; an
item whose callback is null is not drawn.

| Item | Drawn when |
|---|---|
| mention | not you; opened where a composer is open |
| message | not you; not a puppet |
| verify | not you; not a puppet; unverified; this session is verified |
| volume (a slider) | opened from a call; not you |
| mute for everyone / unmute for everyone | opened from a call; `RoomAbility.silence` |
| deafen for everyone / undeafen for everyone | opened from a call; `RoomAbility.silence` |
| remove from call | opened from a call; `RoomAbility.silence` |
| copy user id | always |
| edit profile | you; opens settings on the account section |
| kick from space | not you; `RoomAbility.kick`; drawn destructive; asks `confirmKick` first |

No headings between groups. "message" opens `createDirect([member])`.

**Where it opens from**

| Place | Computer | Phone |
|---|---|---|
| Timeline name | left-click mentions; right-click opens the menu | tap mentions; long press opens the sheet |
| Timeline avatar | left- or right-click opens the menu | tap or long press opens the sheet |
| Member list row | left- or right-click opens the menu | tap opens the sheet |
| Call tile, voice occupant row | as today; the menu gains the card | as today; the sheet gains the card |

A tap on your own name in the timeline does nothing.

## Mentioning from a name

`Timeline` gains `ValueListenable<Member?> get mentionRequest` and
`TimelineController.mention(Member)`. The composer listens as it does for
`target`: on a request it puts the member's label at the cursor through the
same path as an accepted suggestion (a trailing space, the `Mention` into
`_picked`), takes the focus, and the controller clears the request. With no
composer open the request has no listener, and the name's tap is not
offered.

## Removing someone from a call

`moe.loaf.call.moderation` gains `hung_up_at`, milliseconds since the epoch,
beside `muted` and `deafened`. `callSilenceContent` writes the three
together, so one write never loses another; `callHangups(events)` reads
them back as a map from user id to time.

`MatrixCalls`, on every change of that state while in a call, compares its
own `hung_up_at` with the membership's `created` time. A newer `hung_up_at`
leaves the call by the hang-up path. An older one is a removal from an
earlier visit and is ignored, so joining again after being removed works
with no further write.

`Rooms.hangUp(roomId, userId)` writes it, gated by `RoomAbility.silence`.
The voice occupant row's "kick from <channel>" becomes "remove from call",
not drawn destructive, and calls it. "kick from space" lives in the person
menu alone.

## Copy

| Was | Is |
|---|---|
| a moderator muted you | someone muted you for everyone |
| a moderator deafened you | someone deafened you |
| a moderator unmuted you / undeafened you | you can talk again |
| — | someone hung up for you |

Menu labels stay lowercase.

## Testing

- **`bridgeOf`**: `@_ooye_a:loaf.moe` is Discord; `@ooye:loaf.moe`,
  `@x_ooye_:loaf.moe` and `@_ooye:loaf.moe` are null.
- **`MatrixRooms`**: a member whose id is a puppet's carries the bridge.
- **`PersonName`**: the colour per role; the badge drawn for a puppet and
  not otherwise; the tooltip; `copyWith` keeping the bridge.
- **The timeline and the member list**: a puppet's name carries the badge.
- **The menu**: the card's fields; each item's rule from the table, you and
  not you; a puppet hiding message and verify; "message" opening the DM.
- **Mentioning**: a tap puts `@Name ` at the cursor and the sent message
  carries the mention; a tap on your own name does nothing; a request with
  no composer is not offered.
- **Removal**: `callHangups` parsing; `MatrixCalls` leaving on a newer
  `hung_up_at`, staying on an older one, and joining again afterwards;
  `callSilenceContent` keeping `hung_up_at` through a mute.
- **The occupant row**: its labels; no kick on it; kick in the person menu
  with `RoomAbility.kick`.

**By hand on loaf.moe:** a puppet's message and member row; the menu from
each place in the table; mentioning from a name; removing someone from a
call and watching them stay in the channel and rejoin.

## Order

1. The bridge and the badge, with `PersonName`.
2. The person menu.
3. Mentioning from a name.
4. Removing someone from a call, and the copy.
