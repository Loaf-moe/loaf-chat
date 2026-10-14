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
- The upload itself, not the thumbnail, on the card and on a speaking call
  tile, fetched ahead for everyone in your rooms, so a GIF avatar plays.

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
- A room the SDK has only partly loaded keeps just `importantStateEvents`
  in memory (`client.dart`, `Room.partial`): member state is not among
  them, so `getParticipants` sees nobody until `requestParticipants` has
  read the store or the server.
- `showMenu`, `showDialog` and `showModalBottomSheet` capture
  `InheritedTheme`s from the opening context into the route
  (`popup_menu.dart`, `dialog.dart`, `bottom_sheet.dart` in Flutter
  3.47.5). A plain `InheritedWidget` is not carried.
- Every avatar was `MxcThumbnail`: a server thumbnail at 64, 128 or 320,
  always still, decoded at its native size.

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

**The card** (`person_card.dart`, now the header alone), top to bottom:

- A banner 88 high in `member.color` at 35% alpha. In a menu its top
  corners match the menu's; in a sheet all four are rounded, since the
  sheet pads its header.
- The avatar at 128, overlapping the banner's bottom edge, in a 3px ring of
  the card's colour, with a 20px presence dot at its bottom right (none
  when presence is unknown). It is the upload itself, drawn over the
  thumbnail, so a GIF plays.
- `PersonName` at 20 in Lora, the display serif, in the role's colour, the
  badge after it.
- A role pill reading `admin` or `moderator` in the role's colour; none for
  a member.
- The id in mono, then the status line.
- For someone else, where a verifier is at hand: one trust line (shield and
  lead) with a muted note under it, and for an unverified person while this
  session cannot vouch, "verify this session first, so it can vouch for
  them." A puppet gets no trust line.

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
| kick from space | not you; a space is open; `RoomAbility.kick`; drawn destructive; asks first, then kicks with a spinner |

No headings between groups. "message" opens `createDirect([member])`.

**Where it opens from**

| Place | Computer | Phone |
|---|---|---|
| Timeline name | left-click mentions; right-click opens the menu | tap mentions; long press opens the sheet |
| Timeline avatar | left- or right-click opens the menu | tap or long press opens the sheet |
| Member list row | left- or right-click opens the menu | tap opens the sheet |
| Call tile, voice occupant row | as today; the menu gains the card | as today; the sheet gains the card |

A tap on your own name in the timeline does nothing.

**Kick from space** (decided 2026-10-14). A Matrix space is a room; a kick is
per room and the server cascades nothing. `Rooms.kickFromSpace` kicks them
from every joined room under the space they are in, deepest first, then
the space, leaving out any room another joined top-level space also lists,
the walk `leaveSpace` makes. Each room's member state is loaded first,
since a partly loaded room holds none. Every kick is attempted; the rooms
that refused come back as `PartlyDone`, and the shell toasts "couldn't
kick X from everything in Y". `confirmKickFromSpace` asks, then runs the
kick inside the dialog: the button becomes a spinner, cancel is disabled
and the dialog cannot be dismissed until it is done.

## Original avatars

`AvatarImages.original(ref)` is the picture as uploaded, every frame. On
the Matrix side `MxcImage(client, mxc, {size})` serves both: a size fetches
the server thumbnail as before, none fetches `getDownloadUri`. Same bearer
token, same file store keyed by uri, same refusal of anything not
`image/`. An original decodes no wider than 512 through
`decodeWithFallback`, which also gives Windows its WIC fallback; the
widest it is ever drawn is 128 logical.

`LoafAvatar.original` draws it over the thumbnail, gapless, fading in once
decoded; a failed original leaves the thumbnail. The card and the speaking
call tile ask for it; rows never do.

**Warming.** `MatrixAvatarImages.warm(ref)` queues an original once per
mxc. `MatrixRooms` calls it for every member it builds and for you. One
serial queue: the first fetch waits five seconds so the sync lands first;
later asks fetch at once; each fetch is bounded by sixty seconds on a timer
of its own; a failure or timeout is skipped; disposing the rooms cancels
the timers and stops the drain. A relaunch costs one store read per
avatar.

`AvatarImagesScope` is an `InheritedTheme`, so a menu, dialog or sheet
captures it with the themes. The hand-carrying helper is gone.

## Calls

The call tile draws the original while `speaking && !faded`, the gate the
speaking ring uses, and never while ringing. A GIF moves with their voice.
When they stop, the layer goes and the GIF snaps to the thumbnail's frame:
Flutter cannot pause a GIF.

## Mentioning from a name

`Timeline` carries `MentionRequest? get mentionRequest` and
`mention(Member)`, both from `ComposerAiming`, so every backend has them.
A request is a new object each time; the composer tells one from the next
by identity, as it does reply and edit targets. It notes the request
standing when it opens, and again when its timeline changes, so a request
from before it existed is never inserted. A new one goes in at the cursor,
over any selection, with a trailing space, the `Mention` kept for sending,
and the field takes focus: the same `_insertMention` an accepted suggestion
uses.

The timeline name's click or tap asks for one only while the timeline is
writable. The person menu's "mention" is offered by the shell when the open
channel is not a voice channel and its timeline is writable, and closes the
member drawer on a phone so the composer shows.

## Removing someone from a call

`moe.loaf.call.moderation` gains `hung_up: true` beside `muted` and
`deafened`. `callHangUpContent(current)` writes the flag with the silence
they are under, so a hang-up never lifts a mute; `callSilenceContent`
writes without it, so the next mute or lift ends the hang-up. The time is
the event's `origin_server_ts` (`callHangUps`), and a membership's
`created` is the server's time too once echoed: both sides compare one
clock.

`MatrixCalls`, on every sync while in a call, ends the call as
`CallPhase.hungUp` when the flag about you is newer than your membership.
An older flag is a removal from an earlier visit and is ignored, so joining
again stays, with no further write. The end state reads "someone hung up
for you" and offers "join again", which is `retry`. The shell toasts the
same line, since you may be reading elsewhere.

`Rooms.hangUp(roomId, userId)` writes it, gated by `RoomAbility.silence`.
The voice occupant row's item is "remove from call", not drawn
destructive, never on your own row. `Rooms.kick`, `Channel.kickBelow` and
the row's "kick from <channel>" are gone; kick from space lives in the
person menu alone.

## Copy

| Was | Is |
|---|---|
| a moderator muted you | someone muted you for everyone |
| a moderator deafened you | someone deafened you |
| a moderator unmuted you / undeafened you | you can talk again |
| — | someone hung up for you |
| Muted by a moderator / Deafened by a moderator (tile tooltip) | Muted for everyone / Deafened for everyone |
| muted by a moderator (row, read aloud) | muted for everyone |

Menu labels stay lowercase.

## Testing

- **`bridgeOf`**: `@_ooye_a:loaf.moe` is Discord; `@ooye:loaf.moe`,
  `@x_ooye_:loaf.moe` and `@_ooye:loaf.moe` are null.
- **`MatrixRooms`**: a member whose id is a puppet's carries the bridge.
- **`PersonName`**: the colour per role; the badge drawn for a puppet and
  not otherwise; the tooltip; `copyWith` keeping the bridge.
- **The timeline and the member list**: a puppet's name carries the badge.
- **The menu**: the card's fields, serif name, banner colour and presence
  dot; each item's rule from the table, you and not you; a puppet hiding
  message and verify; copy user id copying; "message" opening the DM;
  kick asking first, showing a spinner while it runs, and toasting a
  half-done kick.
- **Kick from space**: the rooms they are in then the space; rooms another
  space lists spared; a refused room in `PartlyDone` with the rest done.
- **Original avatars**: fetched from the download uri with the token;
  cached apart from the thumbnail; a failure caches nothing; decoded no
  wider than 512; two layers in `LoafAvatar`, a failing original leaving
  the thumbnail, none resolved when not asked.
- **Warming**: once per ref; past a failure; non-mxc ignored; nothing after
  dispose; waits its delay; a hung download given up on; a member's avatar
  seen on the download path.
- **The call tile**: plays while they speak; rests while quiet, faded or
  reconnecting.
- **Mentioning**: a request is new each time and heard; the composer puts
  it at the cursor, mid-text, in an empty field, twice for the same person,
  and sends it as a pill; a request from before the composer opened is not
  taken; a click or tap on the name asks, a right-click still opens the
  menu; the tile has no `onMention` until the device can write; the menu's
  item is offered iff given and calls back once the menu is gone; from the
  member list it fills the composer; never for yourself.
- **Removal**: `callHangUpContent` keeping the standing silence;
  `callHangUps` reading the flag with the server's time and nothing without
  it; `MatrixCalls` ending the call on a newer flag, ignoring an older one,
  staying after joining again, keeping the mute the flag came with, and
  `retry` joining again; `hangUp` writing the flag with the silence they
  are under; the end state's words and button; the shell's toast.
- **The occupant row**: "remove from call" offered where the app can, not
  without, not on your own row, under the volume; one tap asks the backend
  with no question; a refusal toasts; the row reads "muted for everyone".

**By hand on loaf.moe:** a puppet's message and member row; the menu from
each place in the table; mentioning from a name; removing someone from a
call and watching them stay in the channel and rejoin.

## Order

1. The bridge and the badge, with `PersonName`. Landed.
2. The person menu, then the card's look, original avatars, warming, and
   the call tile. Landed.
3. Mentioning from a name. Landed.
4. Removing someone from a call, and the copy. Landed.
