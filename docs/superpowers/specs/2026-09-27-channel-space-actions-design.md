# loaf native — channel and space actions (SDK phase 5)

Phase 5 of `docs/superpowers/plans/2026-09-26-sdk-wiring-roadmap.md`: the
things you *do* to rooms and spaces reach the real account. Joining,
leaving, muting, favourites and low priority, finding and joining spaces,
creating a space, starting DMs without duplicates, and inviting people. It
amends, and never contradicts, `2026-09-20-loaf-native-design.md` and
`2026-09-26-rooms-from-sync-design.md` (the `Rooms` seam and the
honest-controls rule on a half-wired backend).

## Scope

**In:**

- Mute and unmute as a room push rule.
- Favourite, low priority and reordering favourites as room tags.
- Leaving a channel. Joining an unjoined channel from its row.
- Unjoined channels in a space, from `/hierarchy` (deferred from phase 2).
- The add-space panel on real data: join by address or matrix.to link,
  explore a server's public spaces, and create a space.
- Joining a space also joins its category subspaces and suggested channels
  (deferred from phase 2).
- A menu on the rail's space icons: *invite people* and *leave space*.
  Leaving a space leaves its channels too, after one confirm.
- *Invite people* in the channel action menu and the space menu: pick from
  people you share rooms with, or type an `@name:server`.
- New message: one person reuses your DM with them, and a group reuses a DM
  with exactly those people. Otherwise a new DM is made.

**Out, logged in the roadmap:**

| Deferred | Why |
|---|---|
| Space settings, roles and power levels | New UI the spec does not draw |
| Knocking on a knock-only room or space | Such rooms are hidden rather than offered |
| Inviting by email (3PID) | loaf.moe has no identity server |
| Rail order from `org.matrix.msc3230.space_order` | Already deferred from phase 2 |
| Removing a room from a space, or adding an existing one | Space administration, with settings |

## The seam

The `Rooms` actions become futures that throw when the server says no. That
is the shape `accept` and `decline` already have. `MockRooms` answers with
`SynchronousFuture`s, so the mock behaves exactly as before.

```dart
Future<void> setMuted(String roomId, bool muted);
Future<void> setJoined(String roomId, bool joined);
Future<void> setFavourite(String roomId, bool favourite);
Future<void> reorderFavourites(List<String> roomIds);
Future<void> setLowPriority(String roomId, bool lowPriority);
Future<void> joinSpace(Space space);
Future<void> leaveSpace(String spaceId);                         // new
Future<String> createSpace(String name, {required Member me});
Future<Channel> createDirect(List<Member> members);
Future<void> invite(String roomId, List<String> userIds);        // new
SpaceDirectory get directory;                                    // new
```

`RoomAbility` gains `invite`. `leaveSpace` sits under the existing `leave`.

Both backends need four kinds of refusal they can tell apart:

- `InviteRefused(Map<String, Object> failed)`: which user ids failed, so
  the panel can name them.
- `SpaceNotFound`.
- `PartlyDone(String what)`: a compound action stopped partway.
- A general failure: anything else.

These are plain classes in `lib/ui/rooms/rooms.dart`, so the UI never sees
an SDK exception.

**`SpaceDirectory`** is a small new interface in `lib/ui/spaces/`. The
add-space panel reads it instead of `mockDirectories` and
`mockSpaceAddresses`:

```dart
abstract interface class SpaceDirectory {
  /// A server's public spaces (`/publicRooms`, filtered to spaces).
  Future<List<SpacePreview>> publicSpaces(String server);

  /// An alias or matrix.to link, resolved and previewed. Throws
  /// [SpaceNotFound] when nothing is there.
  Future<SpacePreview> lookUp(String address);
}
```

`MockSpaceDirectory` answers from the existing fixtures. The panel gets a
loading row while a directory or a lookup is in flight, and "couldn't reach
<server>. try again?" when one fails.

**Tests that change.** The rule is "existing tests unchanged", with the
same exception phase 3 took. These three change mechanically, and no other
test changes:

- `mock_rooms_test.dart` adds `await`.
- `app_shell_rooms_test.dart`'s `_FakeRooms` takes the new signatures and
  members.
- `matrix_rooms_test.dart`'s check that pins "muting throws; abilities are
  these three" is updated.

## On screen

**Quick toggles** apply at once and snap back with a toast if the server
refuses. These are mute, favourite, low priority, reorder and leaving a
channel. Refused reactions already work this way.

- Mute turns the room's push rule to *don't notify*, and unmute to
  *notify*. Reading keeps its phase-2 rule: anything but *notify* is muted.
- Favourite removes low priority, and low priority removes favourite.

**Unjoined channels** in a joined space are drawn dimmed, as the mock
already draws them. Tapping one joins it and opens it. Children whose join
rule is `invite` or `knock` are not shown, since tapping them could not
work. A `restricted` child is shown when one of its allowed spaces is one
you are in.

**Joining a space** comes from a link, from explore, or from accepting a
space invite. It joins the space, then its category subspaces, then its
suggested channels. The later steps are best-effort: one that refuses is
skipped and shows dimmed, like any unjoined channel.

**The space menu** opens with right-click on desktop and long-press on
phones. It has two items:

- **invite people**;
- **leave space**. This confirms first: "leave bakers? you'll leave its
  6 channels too." The count is the joined rooms inside it, at any depth.
  Once confirmed, it runs with no cancel, since leaving can't be stopped
  halfway honestly. If some rooms refuse, a toast says "couldn't leave
  everything in bakers", and what is left stays on the rail, so leaving
  again finishes the job.

**Invite people** is a panel with two parts:

- a picker of people you share any room or space with, minus those already
  in the room;
- a field that takes an `@name:server`.

"invite" reads "inviting…" while it works. On success the panel closes
with a toast ("invited 2 people"). If any fail, it stays open, marks the
people who failed, and offers "try again". Retrying re-sends only those
people. A space invite invites to the space room only; people then pick
channels themselves.

**Create space** makes the space, then `#general`, then a voice channel
called `hangout`. The create button reads "creating…". Its failure has two
cases:

- The space itself was refused: the panel stays open with "couldn't create.
  try again?".
- The space exists but a channel failed: you land in the space anyway, and
  a toast names what is missing. The space is never quietly deleted.

**New message** waits on the server the same way ("starting…"). It stays
open with "couldn't start. try again?" if refused.

## Mapping and calls

**`lib/matrix/matrix_rooms.dart`** replaces its `_unwired` stubs, and its
abilities turn on `mute`, `leave`, `join`, `tag`, `addSpace`, `startDirect`
and `invite`.

| Action | Call |
|---|---|
| mute / unmute | `room.setPushRuleState(dontNotify / notify)` |
| favourite | `room.addTag(TagType.favourite, order:)`, then `removeTag(TagType.lowPriority)` |
| low priority | `room.addTag(TagType.lowPriority)`, then `removeTag(TagType.favourite)` |
| reorder favourites | `addTag` with orders `(i + 1) / (n + 1)`, only on rooms whose order changed |
| join a channel | `client.joinRoom(id, via:)`, with `via` taken from the parent's `m.space.child` |
| leave a channel | `room.leave()` |
| invite | `room.invite(userId)` for each, collecting failures |
| DM, one person | `client.startDirectChat(mxid)`, which reuses the existing DM |
| DM, a group | an existing direct room with exactly those members, else `client.createRoom(isDirect: true, invite:, preset: trustedPrivateChat)` |
| create space | `client.createSpace(name:, visibility: private)`, then each channel through `createRoom` with an `m.space.parent` and a `restricted` join rule on the space, then `m.space.child` on the space |
| voice channel | `createRoom` with `creation_content: {type: org.matrix.msc3417.call}` |

**`lib/matrix/matrix_hierarchy.dart`** (new) owns `/hierarchy`:

- It fetches each joined space's tree, following `next_batch` to the end,
  and caches it by space id.
- It refetches only when that space's `m.space.child` state changes in a
  sync, or when you join or leave a room in it.
- `MatrixRooms._space` adds the cache's unjoined children as
  `Channel(joined: false)`. Until the first fetch lands, a space shows its
  joined channels only, as it does today.
- A failed fetch keeps the last good tree and retries on the next child
  change or relaunch.

**`lib/matrix/matrix_space_directory.dart`** (new):

- `publicSpaces` calls `queryPublicRooms(server:, filter: {room_types: [m.space]})`.
- `lookUp` parses a `#alias:server` or a matrix.to link.
  - An alias is resolved with `getRoomIdByAlias`.
  - A room id comes with its link's `via` servers.
  - Then one `/hierarchy` page (`maxDepth: 1`) previews it: name, topic,
    member count, join rule and the first level of channels.

**Optimistic overlay.** `MatrixRooms` keeps a map of pending changes (room
id → field → wanted value), and mapping applies it on read. An entry clears
in one of two ways:

- a sync shows the wanted value; or
- the call fails. `MatrixRooms` then notifies with the refusal, and the
  shell toasts.

A pending leave hides the row. A pending join shows it joined.

**Compound actions** run their steps one after another and stop at the
first refusal that matters:

- **Leave space**: joined descendants, deepest first, then the space. Every
  step is attempted. Any refusals throw `PartlyDone`.
- **Join space**: the space's refusal throws. Later refusals are swallowed,
  as above.
- **Create space**: the space's refusal throws. A channel's refusal throws
  `PartlyDone` carrying the new space's id, so the shell can still open it.

## Testing

- **`test/matrix/`**: each call over `FakeMatrixApi`, with refusals and
  partial failures over `MockClient`. Also:
  - the hierarchy cache's fetch, paging, refetch-on-child-change and failure
    kept-last-good;
  - DM reuse for one person and for a group;
  - the overlay applying, and clearing on sync and on failure.
- **Widgets**:
  - the space menu on desktop (right-click) and phone (long-press);
  - the leave confirm and its partial-failure toast;
  - the invite panel's picker, typed id, busy state and per-person failure;
  - create and new-message busy and failed states;
  - the add-space panel's loading and failure rows.
- **By hand**:
  - Every flow in the running mock app.
  - Then a live pass on loaf.moe, with Chris's okay at each step: join and
    leave a channel, mute, favourite, reorder, explore and join a space,
    create a throwaway space and leave it, DM an existing contact (it
    should reuse), and invite a test account.
