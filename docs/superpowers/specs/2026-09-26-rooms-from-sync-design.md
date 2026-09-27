# loaf native — rooms from sync (SDK phase 2)

Phase 2 of `docs/superpowers/plans/2026-09-26-sdk-wiring-roadmap.md`: the
rail, channel lists, Home sections, unreads and members come from the SDK's
sync instead of fixtures. It amends, and never contradicts,
`2026-09-20-loaf-native-design.md`, which stays the authority for the
information architecture.

## Scope

**In:**

- Spaces on the rail, their channels in categories, Home's sections, unread
  and mention counts, muted state, and room tags, all read from sync.
- Member lists, with each person's real power level, so names are coloured
  correctly.
- Who you are (`me`) in the user bar and the account section of settings.
- Invites in Home, with **accept and decline wired**. These are the phase's
  only writes.
- The first-sync face, the empty-account face, and the not-yet-wired
  conversation pane.

**Out, and when each arrives:**

| Deferred | Phase | Why |
|---|---|---|
| Mark read, mute, leave, join, tags, favourite reorder | 5 | Writes; hidden until wired (below) |
| Unjoined channels from `/hierarchy`, and auto-joining subspaces and suggested channels | 5 | A row tagged *join* is a dead end while joining is hidden |
| Adding a space, starting a DM | 5 | Writes |
| Messages in the conversation pane | 3 | The timeline phase |
| Presence and status of others, profile edits | 6 | `Presence.unknown` until then |
| Voice occupancy avatars | 7 | Reading MatrixRTC memberships needs a `VoIP` instance |
| Avatar images (`mxc`) | 6 / 9 | Initials on a colour until then |

**Mock mode is unchanged in every respect.** It stays the default backend.

## Honest controls on a half-wired backend

A control that flips local state and forgets it on relaunch is a lie about
your real account. So on the matrix backend, **any control whose action is
not wired is not shown.** It is not shown disabled, and it does not flip
local state. The backend declares what it supports, and the shell asks before
drawing each control. A menu left with no entries does not open at all.

In phase 2, the matrix backend supports accepting and declining invites, and
nothing else.

## The seam

- **`lib/ui/model/`** holds the plain models (`Member`, `Channel`, `Space`,
  `ChannelCategory`, `Invite`, `Message`, `Role`, `ChannelKind`, and so on),
  moved out of `lib/ui/mock/fixtures.dart`. `fixtures.dart` keeps the fake
  data and re-exports the models, so existing imports keep working.
- **`lib/ui/rooms/rooms.dart`** is the `Rooms` interface. It is a
  `Listenable` of plain-model snapshots:
  - what it holds: `synced`, `syncProgress`, `me`, `spaces`, `homeRooms`
    and `invites`, and `loadMembers(roomId)` to ask for a room's whole
    member list, which listeners hear about when it arrives
  - what the backend can do: `abilities`, a set of `RoomAbility` (mark
    read, mute, leave, join, tag, answer invites, add a space, start a DM,
    calls, messages, edit your profile)
  - the actions themselves: mark read, mute, join or leave, favourite and
    its position, low priority, accept, decline, add a space, and start a DM
- **A `Rooms` factory** reaches the shell through `SessionRoot` and
  `AppShell` (`rooms:`), the way `MatrixSession` takes its SSO browser: the
  shell makes the account's `Rooms` when it opens and disposes them when it
  closes. `main.dart` passes `() => MatrixRooms(client)` on the matrix
  backend. Left out, as in every existing test, the shell makes a
  `MockRooms`. `LoafSession` itself is unchanged, so its test stand-ins
  still implement it.
- **`MockRooms`** owns the fixture state and the overlays the shell keeps
  today: membership, muted, read, favourites, low priority, answered invites,
  and accepted rooms and spaces. It supports every action, with today's
  behaviour.
- **`lib/matrix/matrix_rooms.dart`** is `MatrixRooms`. It maps `client.rooms`
  into the models:
  - It rebuilds one derived snapshot on each `SyncStatus.finished` and
    notifies its listeners.
  - It reads the sync status's current value as well as subscribing, since
    the SDK's cached streams don't replay.
  - It keeps no other state: the SDK is the store.
- **`AppShell`** keeps navigation and the overlays that belong to the call
  and timeline mocks (your own call's occupants, missed-call unreads, DM
  activity bumps from sent messages). It layers them over `rooms` snapshots.
  Phases 3 and 7 replace those mocks, so moving these overlays now would be
  churn.

Only `lib/matrix/` and `lib/main.dart` import `package:matrix`, as before.

## Mapping

**The rail** holds joined spaces that are no joined space's child, sorted
alphabetically by name. The main spec gives the rail no order. A space's
colour is `spaceColorFor(name)`.

**A space's channel list**, per "Edges" in the main spec:

- Joined non-space direct children come first, in an unnamed category, in
  `spaceChildren` order.
- Each joined child subspace is a category named after it. It holds that
  subspace's joined non-space descendants, in child order, with deeper
  subspaces flattened in.
- A room under two subspaces appears in both.
- Children and subspaces you have not joined are left out until phase 5.

**Home rooms** are joined non-space rooms that are DMs, or that are no joined
space's or subspace's child. The existing pure `homeSections` and
`collapseDuplicates` then arrange them, unchanged.

**A channel from a room:**

| Field | Source |
|---|---|
| `id` | `room.id` |
| `name` | `getLocalizedDisplayname()` |
| `kind` | `voice` when `m.room.create`'s `type` is `m.call` or `org.matrix.msc3417.call`. Otherwise, in Home, `direct` for `isDirectChat` and `room` for everything else. Otherwise `text` |
| `unread` / `mentions` | `notificationCount` / `highlightCount` |
| `muted` | `pushRuleState` is not `notify` |
| `private` | join rule `invite` or `knock` |
| `topic` | `room.topic` |
| `favourite`, `favouriteOrder` | the `m.favourite` tag and its `order` |
| `lowPriority` | the `m.lowpriority` tag |
| `lastActivity` | `latestEventReceivedTime` |
| `members` (DMs) | the other participants |

A space's badges come from `Space`'s existing getters. The Home badge keeps
its existing rule: DM unreads, room mentions, and invites.

**Invites** are rooms in the `invite` state:

- **Kind:** `space` when `isSpace`, `direct` when `isDirectChat` (which reads
  the invite's `is_direct`), and `room` otherwise.
- **Inviter:** the sender of your membership event.
- **Name, topic and member count:** from the invite's stripped state, and
  shown only when present.

**Accepting and declining** call `room.join()` and `room.leave()`:

- An in-flight set per room makes a double tap, or a stale preview, send
  one request.
- A failure shows a toast, and the preview stays up with its buttons, so the
  next step is retrying.
- A space accepted joins only the space room. Joining its subspaces and
  suggested channels is phase 5.

**Members.** The SDK keeps member events in memory only for rooms it has
loaded, so a snapshot carries whoever is there. When the shell shows a
member list it calls `loadMembers(roomId)`, once per room, which runs
`requestParticipants(cache: true)`: members on disk first, then the
server's list, kept in the SDK's own memory, then a fresh snapshot. A DM's
people come from the room summary's `m.heroes`, falling back to the
`m.direct` person, so duplicate DMs fold without loading members. Each
person becomes a `Member` with:

- their display name
- a colour hashed from the MXID, for the avatar fallback only
- `Presence.unknown`
- `powerLevel` from `getPowerLevelByUserId(...).level`

A room-v12 creator's owner level (2⁵³−1) buckets as admin.

**`me`** is `client.userID`, with the display name from `fetchOwnProfile()`
once it answers. Until then it shows the localpart.

**State the SDK does not keep in memory.** For rooms that are only listed,
the SDK holds just the "important" state events. `openClient` adds
`m.room.topic`, `m.room.join_rules` and `m.room.power_levels` to that set,
so topics, locks and name colours are there without opening a room.

## The shell on the real backend

**First sync** only happens after a fresh sign-in, because a relaunch
restores from the database. While `synced` is false:

- The rail shows only Home.
- The list and the conversation pane show a centred
  `CircularProgressIndicator.adaptive()`, which is the system activity
  indicator on macOS and iOS.
- Once the server's response is being processed, the SDK reports rooms
  handled out of the total (`SyncStatus.processing` with `progress`). The
  spinner then becomes a determinate bar, styled like the key-restore bar in
  `verify_steps.dart`.
- There is no text and no button, because the sync can't be stopped and it
  retries on its own. The user bar, and sign-out through it, stay reachable.

**An account with nothing in it** gets a plain "nothing here yet" face,
rather than the crash `_channel` hits today when no text channel is joined.

**After the first sync** the app stays where it opened, which is Home on a
fresh sign-in; the spaces arrive on the rail.

**Opening a room** shows the real header: name, topic, and a working
member-list toggle. The body says messages aren't wired up yet, and there is
no composer. A voice channel opens the same pane and never connects, on the
desktop too. DM call buttons are hidden, since calls are unsupported.

**Hidden while unsupported:**

- channel-action menu entries
- the rail's add-space "+"
- the new-DM "+"
- favourite drag-to-reorder
- settings controls that write to the account: the account section shows
  your name and Matrix ID as read-only facts, with no avatar badge,
  presence, status or save
- the status picker on your avatar
- the desktop update notice, which has no updater behind it yet

**Made honest while here:** settings' sign-out button signs out (it did
nothing), and the copy button beside a read-only row copies.

**Live changes.** If a sync removes the room you are reading, you fall back
the way leaving does today: to the space's first joined text channel, or to
the empty face. If a sync removes the space you are in, you go to Home.

## Testing

- **Rehearsal before planning.** Run `MatrixRooms` against `FakeMatrixApi`
  in a scratch copy. Where the fake's sync lacks spaces, subspaces, tags,
  invites or power levels, feed a hand-built sync through `MockClient`.
- **`test/matrix/matrix_rooms_test.dart`** uses `test()` and a real `Client`.
  It covers:
  - each mapping rule
  - `synced` and `syncProgress` across a sync
  - accept and decline: the right endpoint, one request per double tap, and
    a failure surfacing
- **`test/mock_rooms_test.dart`** covers the overlay logic now that it lives
  in `MockRooms`.
- **Widget tests over a fake `Rooms`** use plain models, with no SDK:
  - the spinner, then the bar
  - the empty face
  - unsupported controls being absent
  - the unwired conversation pane
  - falling back when a room or space vanishes

  The SDK is tested below the widget layer. Widgets are tested over plain
  models.
- **The existing 495 tests pass unchanged.** That is the proof that the
  refactor kept behaviour.
