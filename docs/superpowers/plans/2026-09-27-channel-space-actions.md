# Channel and Space Actions Implementation Plan (SDK phase 5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The things you do to rooms and spaces reach the real account:
- mute;
- favourite, low priority and reorder;
- join and leave a channel;
- unjoined channels in spaces;
- finding, joining, leaving and creating spaces;
- DMs without duplicates;
- inviting people.

**Architecture:**
- **The seam:** the `Rooms` actions become futures that throw plain loaf refusal types. `MockRooms` answers with `SynchronousFuture`s, so the mock behaves as before. A new `SpaceDirectory` interface replaces the add-space panel's direct use of fixtures.
- **`MatrixRooms`** implements the actions with an optimistic overlay that mapping applies on read. It gets two helpers:
  - `MatrixHierarchy` (`/hierarchy`, cached per space);
  - `MatrixSpaceDirectory` (`/publicRooms` and alias lookup).
- **The shell** gains a space menu on the rail and an invite panel. Its create and new-message panels also get busy and failed states.

**Tech Stack:** Flutter 3.47.5 via `mise exec -- flutter`; `matrix` 13.0.0.
- Real-SDK tests run offline over the existing harness in `test/matrix/matrix_rooms_test.dart`: a `FakeMatrixApi` subclass (`_Api`), plus `client.handleSync(...)` to deliver state.
- Widget tests pump `AppShell` over the mock, or over a hand-set fake `Rooms`.

**Spec:** `docs/superpowers/specs/2026-09-27-channel-space-actions-design.md`. Read it first. It sits under:
- `2026-09-26-rooms-from-sync-design.md` (the `Rooms` seam, and honest controls);
- `2026-09-20-loaf-native-design.md`.

Roadmap: `docs/superpowers/plans/2026-09-26-sdk-wiring-roadmap.md`.

**Not rehearsed.** Unlike phases 3 and 4, this plan gives interfaces, test names and key code rather than verbatim edits, to keep it lean. Implementers read the files named in each task before editing. If the code disagrees with this plan, stop and say so rather than improvising.

## Global Constraints

- **The import rule:**
  - Only files under `lib/matrix/` (and `lib/main.dart`) import `package:matrix`.
  - `lib/ui/` never imports `lib/matrix/`.
  - The SDK exports its own `Timeline`, `Presence` and `Role`. Hide them where both are imported (`hide Presence, Timeline`).
- **The SDK is the store.** `MatrixRooms` keeps its derived snapshot plus two small maps:
  - the pending overlay (Task 3);
  - the hierarchy cache (Task 4).

  Nothing else.
- **Existing tests pass unchanged,** except for these mechanical edits, each named in its task:
  - Task 1: `test/mock_rooms_test.dart` adds `await` where it calls `createSpace` and `createDirect`.
  - Task 1: `test/app_shell_rooms_test.dart`'s `_FakeRooms` takes the new signatures and members, all still throwing `_unwired()`.
  - Tasks 3 and 5: `test/matrix/matrix_rooms_test.dart`'s abilities assertion, and its "setMuted throws" expectation, change to the new abilities. The rest of that test stays.

  Never edit an existing test to make it pass otherwise.
- **Honest controls:**
  - A control the backend cannot carry out is not drawn: gate every new control on `RoomAbility`.
  - A step that cannot be stopped offers no cancel. Once leave-space or create is confirmed, no cancel is drawn.
  - No dead ends: every failure offers "try again", or leaves you somewhere real.
- **Copy and layout:**
  - Copy is lowercase and warm.
  - Split by `isDesktop` from `lib/ui/platform.dart`: right-click on desktop, long-press on phones.
  - No hardcoded text metrics.
- `lib/matrix/` tests use `test()`, not `testWidgets()`.
- **Format only the files you touched, by path.** Never run `dart format test/session_root_test.dart`.
- **Running things:** commands must work in Nushell. Run Flutter through mise: `mise exec -- flutter analyze`, `mise exec -- flutter test`. Run the suite in the foreground, one run at a time. Before Task 1 it prints `+739: All tests passed!`.
- **Known flakes:** `matrix_timeline_test` "mapping a taken-back reaction is gone", `matrix_session_test` "signing in again after signing out works", and `matrix_rooms_test` "a DM invite is a DM invite". If only these fail, rerun once.
- **Branch and commits:** work on the branch `phase5/channel-space-actions`. Commit only when the controller says to. Messages are conventional and end with exactly `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **A room listed by two joined spaces.** Leaving one space must not leave a room the other space still lists. Pinned in Task 5: "leaving a space keeps rooms another joined space lists".
2. **Mute tapped twice before the first answer.** The overlay holds the latest wish. A refusal of the first call must not undo the second tap's wanted value. Pinned in Task 3: "a refused call only rolls back its own wish".
3. **A typed invite that isn't a Matrix id** (`bob`, `@bob`, `bob:loaf.moe`). It is never sent. "invite" stays dim until every typed id parses as `@local:server`. Pinned in Task 7: "a malformed id can't be invited".
4. **Signing out with a leave, create, join or invite in flight.** Nothing throws or notifies after `dispose`. Pinned in Task 5: "disposing mid-leave notifies nothing".
5. **A matrix.to link carrying `?via=` for a room id with no alias.** The lookup and the join use those servers. Pinned in Task 5: "a matrix.to room-id link looks up and joins via its servers".

## File Map

| File | Task | Responsibility |
|---|---|---|
| `lib/ui/rooms/rooms.dart` | 1 | async actions, `leaveSpace`, `invite`, `directory`, `RoomAbility.invite`, refusal types |
| `lib/ui/spaces/space_directory.dart` (new) | 1 | the `SpaceDirectory` interface |
| `lib/ui/mock/mock_rooms.dart`, `lib/ui/mock/mock_space_directory.dart` (new) | 1 | the mock's async answers, and its directory from fixtures |
| `lib/ui/spaces/add_space.dart` | 2, 8 | reads a `SpaceDirectory`: loading and failure rows; create's busy and failed states |
| `lib/matrix/matrix_rooms.dart` | 1, 3, 4, 5, 6 | the overlay, toggles, join and leave, spaces, DMs, invites |
| `lib/matrix/matrix_hierarchy.dart` (new) | 4 | the `/hierarchy` cache |
| `lib/matrix/matrix_space_directory.dart` (new) | 5 | `/publicRooms` and alias lookup |
| `lib/ui/shell/app_shell.dart` | 1, 3, 7, 8 | awaits actions, toasts refusals; space menu; invite panel; busy states |
| `lib/ui/shell/spaces_rail.dart`, `lib/ui/shell/space_actions.dart` (new) | 7 | the rail's space menu and the leave-space confirm |
| `lib/ui/shell/channel_actions.dart` | 7 | the `invite` action |
| `lib/ui/members/invite_panel.dart` (new) | 7 | invite people |
| `lib/ui/home/new_message_picker.dart` | 8 | "starting…" and "couldn't start" |
| the roadmap | 9 | what was deferred and found |

## Notes for whoever executes this

- **Harness for `test/matrix/`:**
  - Extend the existing `_Api` in `test/matrix/matrix_rooms_test.dart` with the endpoints each task needs. Keep the `answered`, `hold` and `refuse` style.
  - Put new matrix tests in new `group(...)`s in that same file. `matrix_hierarchy_test.dart` and `matrix_space_directory_test.dart` may be new files; copy `_client` and `_settle` into them.
  - Deliver state with `client.handleSync(SyncUpdate.fromJson(...))`, as the existing tests do.
- **Dispatching subagents (sonnet or cheaper only):** give implementers:
  - the Global Constraints, verbatim;
  - their task;
  - the spec path;
  - the paths to format;
  - the before test count.

  Each task gets a fresh reviewer. The final whole-branch review also runs on sonnet.

---

### Task 1: The async seam, the directory interface, and the mock

**Files:**
- Modify: `lib/ui/rooms/rooms.dart`, `lib/ui/mock/mock_rooms.dart`, `lib/matrix/matrix_rooms.dart` (stubs only), `lib/ui/shell/app_shell.dart`
- Create: `lib/ui/spaces/space_directory.dart`, `lib/ui/mock/mock_space_directory.dart`
- Test: `test/mock_rooms_test.dart` (mechanical `await`s, then new tests), `test/app_shell_rooms_test.dart` (the fake's signatures only)

**Interfaces (Produces), used by every later task:**

```dart
// lib/ui/rooms/rooms.dart
enum RoomAbility { ..., invite }  // add after startDirect, doc: "Inviting people to a room or space."

/// The server turned down some of an invite. [failed] maps each user id
/// that did not go through to why, in the server's words.
class InviteRefused implements Exception {
  const InviteRefused(this.failed);
  final Map<String, String> failed;
}

/// Nothing is at that address.
class SpaceNotFound implements Exception {
  const SpaceNotFound();
}

/// A compound action stopped partway. [spaceId] is set when a space was
/// made and still stands; [missing] names what did not happen, in the
/// UI's words ("#general", "hangout", "3 channels").
class PartlyDone implements Exception {
  const PartlyDone({this.spaceId, this.missing = const []});
  final String? spaceId;
  final List<String> missing;
}

// On Rooms:
Future<void> setMuted(String roomId, bool muted);
Future<void> setJoined(String roomId, bool joined);
Future<void> setFavourite(String roomId, bool favourite);
Future<void> reorderFavourites(List<String> roomIds);
Future<void> setLowPriority(String roomId, bool lowPriority);
Future<void> joinSpace(Space space);
/// Leaves the space and every joined room inside it that no other joined
/// space lists. Throws [PartlyDone] if any refused.
Future<void> leaveSpace(String spaceId);
/// Returns the new space's id. Throws [PartlyDone] (with its id) when the
/// space stands but a channel is missing.
Future<String> createSpace(String name, {required Member me});
/// Returns the DM, which is already in [homeRooms]: an existing one with
/// exactly these people, or a new one.
Future<Channel> createDirect(List<Member> members);
/// Throws [InviteRefused] naming who did not go through.
Future<void> invite(String roomId, List<String> userIds);
SpaceDirectory get directory;
```

```dart
// lib/ui/spaces/space_directory.dart
abstract interface class SpaceDirectory {
  /// A server's public spaces (`/publicRooms`, filtered to spaces).
  Future<List<SpacePreview>> publicSpaces(String server);

  /// An alias or matrix.to link, resolved and previewed. Throws
  /// [SpaceNotFound] when nothing is there.
  Future<SpacePreview> lookUp(String address);
}
```

- [ ] **Step 1: Apply the mechanical test edits.**
  - In `test/mock_rooms_test.dart`, make the `createSpace` test and the `createDirect` test `async` and `await` the call. Change nothing else.
  - In `test/app_shell_rooms_test.dart`'s `_FakeRooms`, change the signatures to the new ones, still `=> _unwired()`. Add `leaveSpace` and `invite` the same way. Add `SpaceDirectory get directory => _unwired();`.
- [ ] **Step 2: Write the failing new mock tests** in `test/mock_rooms_test.dart`:
  - `'leaving a space takes its channels with it'`: `await rooms.leaveSpace(mockSpaces.first.id)`. The space is gone from `rooms.spaces`, and none of its channels are in `rooms.homeRooms`.
  - `'an invite answers at once'`: `await rooms.invite('admins', ['@x:loaf.moe'])` completes without throwing.
  - `'the mock directory lists fixtures'`: `await rooms.directory.publicSpaces('loaf.moe')` equals `mockDirectories['loaf.moe']`. `rooms.directory.lookUp('#nowhere:loaf.moe')` throws `SpaceNotFound`.
- [ ] **Step 3: Run them and see them fail.**
  `mise exec -- flutter test test/mock_rooms_test.dart`. Expected: compile errors for `leaveSpace`, `invite` and `directory`.
- [ ] **Step 4: Change the interface and the mock.**
  - Every action in `MockRooms` returns `SynchronousFuture` after its `_change`.
  - `leaveSpace` removes the space from `_acceptedSpaces` or marks `_membership[id] = false`, whichever way `Space.withSession` reads membership for fixture spaces. Read how the rail filters spaces first. It also marks each of the space's channels left.
  - `invite` returns `SynchronousFuture(null)`.
  - `directory` is a `MockSpaceDirectory`.
  - `MockSpaceDirectory` returns `SynchronousFuture`s over `mockDirectories` and `mockSpaceAddresses`.
    - An address it doesn't know throws `SpaceNotFound` synchronously, via `Future.error`, which a test can await.
    - Resolve addresses with the same parsing `lib/ui/spaces/space_address.dart` already offers. Read it.
  - Add `RoomAbility.invite` to nothing yet. Mock abilities are `RoomAbility.values`, so the mock gets it automatically.
- [ ] **Step 5: Stub the matrix side.** In `MatrixRooms`:
  - each old `_unwired` becomes `Future.error(UnsupportedError(...))`;
  - add `leaveSpace`, `invite` and `directory` the same way (`directory` throws `UnsupportedError` synchronously);
  - leave the abilities as they are.

  The existing `expect(() => rooms.setMuted(...), throwsUnsupportedError)` must still pass. If it doesn't because the error is now asynchronous, keep `setMuted` throwing synchronously (`=> throw UnsupportedError`) until Task 3.
- [ ] **Step 6: Make the shell await.** In `app_shell.dart`, `_applyChannelAction`, `_addSpace` and `_newMessage` now call futures:
  - Quick toggles fire and forget, but catch errors: `unawaited(_rooms.setMuted(id, true).catchError(_refused))`. `_refused` toasts through `showToast(context, "couldn't do that. try again?")`, if mounted.
  - `_addSpace`'s create and `_newMessage`'s DM `await` the future before `setState(_open(...))`.

  Keep the mock's same-frame behaviour: every existing `app_shell_test`, `add_space_test` and `new_dm_test` must pass unchanged. Awaiting a `SynchronousFuture` inside an `async` method still resumes on a microtask, so pump-based tests keep working. If one breaks, use `.then` on the future instead of `await`.
- [ ] **Step 7: Verify.**
  - `mise exec -- flutter analyze` is clean.
  - `mise exec -- flutter test` passes at 739 + 3 = `+742`.
  - Format: `mise exec -- dart format lib/ui/rooms/rooms.dart lib/ui/spaces/space_directory.dart lib/ui/mock/mock_rooms.dart lib/ui/mock/mock_space_directory.dart lib/matrix/matrix_rooms.dart lib/ui/shell/app_shell.dart test/mock_rooms_test.dart test/app_shell_rooms_test.dart`
- [ ] **Step 8: Commit** `refactor(rooms): actions are futures, and spaces are found through a directory`.

### Task 2: The add-space panel reads a directory

**Files:**
- Modify: `lib/ui/spaces/add_space.dart`, `lib/ui/shell/app_shell.dart` (passes `_rooms.directory`)
- Test: `test/add_space_test.dart` (new tests appended; the existing tests are unchanged)

**Interfaces:**
- Consumes: `SpaceDirectory` from Task 1.
- Produces: `showAddSpace(context, joined:, directory:)`. `AddSpacePanel({required joined, required SpaceDirectory directory})` replaces the `directories` and `addresses` parameters. No existing test constructs `AddSpacePanel` directly, and `add_space_test` drives it through `AppShell`.

- [ ] **Step 1: Write the failing tests** in `test/add_space_test.dart`. Pump `AddSpacePanel` directly inside a `MaterialApp` over a hand-written `_SlowDirectory implements SpaceDirectory`, whose futures are `Completer`s the test completes:
  - `'explore shows a loading row until the directory answers'`: a `CircularProgressIndicator` (or the panel's existing loading idiom, if one exists) until completed, then the entries.
  - `"explore says so when a server can't be reached"`: complete with an error. The text `"couldn't reach loaf.moe. try again?"` shows. Tapping it asks again: the directory's call count is 2.
  - `'a link is looked up once typing stops'`: typing the address then waiting 400 ms calls `lookUp` once. Use a 300 ms debounce, so a phone keyboard doesn't fire a lookup per letter.
  - `"a link that can't be reached says so, apart from not found"`: an error that isn't `SpaceNotFound` shows `"couldn't reach that server. try again?"`. `SpaceNotFound` keeps the existing `'no space at that address'`.
- [ ] **Step 2: Run them and see them fail.** `mise exec -- flutter test test/add_space_test.dart`.
- [ ] **Step 3: Implement.**
  - The panel keeps `Future`-driven state per step:
    - explore: a `Map<String, AsyncSnapshot<List<SpacePreview>>>` keyed by server;
    - link: the latest lookup's snapshot, tagged with the address it was for, so a stale answer is dropped.
  - Filter search results locally, as now.
  - With the mock's `SynchronousFuture`s, results must appear with no extra frame. Use `.then`, which runs synchronously for them, and `setState` only when mounted and not currently building. Or fold the synchronous case in at request time.

  Every existing `add_space_test` case must pass unchanged. Run it after each change.
- [ ] **Step 4: Verify.**
  - `analyze` is clean.
  - The whole suite passes at `+746`.
  - Format `lib/ui/spaces/add_space.dart lib/ui/shell/app_shell.dart test/add_space_test.dart`.
- [ ] **Step 5: Commit** `feat(spaces): the add-space panel asks a directory, and says when it can't`.

### Task 3: Real toggles with an optimistic overlay

**Files:**
- Modify: `lib/matrix/matrix_rooms.dart`
- Test: `test/matrix/matrix_rooms_test.dart` (new group `'toggles'`; the abilities assertion is updated)

**Interfaces:**
- Consumes: Task 1's signatures.
- Produces: abilities now include `mute`, `tag`, `join` and `leave`. Later tasks add `addSpace`, `startDirect` and `invite`.

**Design:**

```dart
/// What a row should show while its change is on its way. A field is
/// cleared when a sync shows it, or when its call fails.
class _Wish {
  bool? muted;
  bool? favourite;
  double? favouriteOrder;
  bool? lowPriority;
  bool? joined;
  bool get isEmpty => muted == null && favourite == null &&
      favouriteOrder == null && lowPriority == null && joined == null;
}
final _wishes = <String, _Wish>{};
```

- `_channel` applies a wish with `copyWith`.
- In `_rebuild`:
  - A room with `joined == false` is dropped from `_home` and from its space.
  - A `joined == true` wish on a room not yet joined is drawn joined. Task 4 draws unjoined hierarchy children; until then, join from Home is the only case.
  - At the start of the method, clear every field whose server value now equals the wish, then drop empty wishes.
- Each call follows the same pattern:

```dart
/// Each (room, field)'s latest wish, so a failed older call doesn't undo
/// a newer one.
final _generation = <(String, String), int>{};

Future<void> _wished(
  String roomId,
  String field, // 'muted', 'favourite', ...
  void Function(_Wish) set,
  void Function(_Wish) unset,
  Future<void> Function() call,
) async {
  set(_wishes.putIfAbsent(roomId, _Wish.new));
  final key = (roomId, field);
  final mine = _generation[key] = (_generation[key] ?? 0) + 1;
  _rebuild();
  try {
    await call();
  } catch (_) {
    if (_generation[key] == mine) {
      final wish = _wishes[roomId];
      if (wish != null) {
        unset(wish);
        if (wish.isEmpty) _wishes.remove(roomId);
      }
    }
    if (!_disposed) _rebuild();
    rethrow;
  }
}
```

Favourite and low priority are two fields each call touches. Give each one its own `_wished`, or pass both fields' keys. That is the implementer's choice, but Review Focus 2 must hold for both.

| Action | Wish | Call |
|---|---|---|
| mute | `muted` | `room.setPushRuleState(muted ? PushRuleState.dontNotify : PushRuleState.notify)` |
| favourite on | `favourite: true, lowPriority: false` | `addTag(TagType.favourite, order: <after the last favourite's order, or 0.5>)`, then `removeTag(TagType.lowPriority)` if present |
| favourite off | `favourite: false` | `removeTag(TagType.favourite)` |
| low priority on | the reverse | `addTag(TagType.lowPriority)`, then `removeTag(TagType.favourite)` if present |
| reorder | `favouriteOrder` for each room whose position changed | `addTag(TagType.favourite, order: (i + 1) / (n + 1))`, sequentially, only for changed rooms |
| leave | `joined: false` | `room.leave()` |
| join | `joined: true` | `client.joinRoom(roomId, via: <Task 4 fills this; [] for now>)` |

`setJoined(id, true)` for a room with no `Room` object yet (an unjoined hierarchy child) is valid: join by id.

- [ ] **Step 1: Write the failing tests** (group `'toggles'`). Extend `_Api` to answer `PUT .../pushrules/...`, `PUT/DELETE .../tags/...`, `/join` and `/leave`, recording each path in `answered` and honouring `hold` and `refuse`:
  - `'muting shows at once and sends the push rule'`
  - `'a refused mute snaps back and throws'`
  - `'a refused call only rolls back its own wish'`: hold the first mute, mute off, then refuse the first. The row reads unmuted.
  - `'favouriting a low-priority room clears low priority'`
  - `'reordering sends only the rooms that moved'`
  - `'leaving hides the row at once, and a refusal brings it back'`
  - `"a wish clears when sync agrees"`: after a `handleSync` with the new push rule and tags, `_wishes` is empty. Check through behaviour: a later server change, such as an unmute from another device, is drawn.
  - Update the abilities assertion to add `mute`, `tag`, `join` and `leave`. Replace `expect(() => rooms.setMuted(...), throwsUnsupportedError)` with `expect(rooms.createSpace('x', me: rooms.me), throwsUnsupportedError)`. That is the named mechanical edit.
- [ ] **Step 2: Run them and see them fail.** `mise exec -- flutter test test/matrix/matrix_rooms_test.dart`.
- [ ] **Step 3: Implement** the overlay and the calls above.
- [ ] **Step 4: Verify.**
  - `analyze` is clean.
  - The suite passes at `+753`.
  - Format `lib/matrix/matrix_rooms.dart test/matrix/matrix_rooms_test.dart`.
- [ ] **Step 5: Commit** `feat(matrix): mute, tags, join and leave reach the server, and show at once`.

### Task 4: Unjoined channels from `/hierarchy`

**Files:**
- Create: `lib/matrix/matrix_hierarchy.dart`
- Modify: `lib/matrix/matrix_rooms.dart` (`_space`, `setJoined`'s `via`)
- Test: `test/matrix/matrix_hierarchy_test.dart` (new), plus one test in `matrix_rooms_test.dart`

**Interfaces:**

```dart
/// Each joined space's tree from `/hierarchy`, fetched whole (every page)
/// and kept until the space's children change.
class MatrixHierarchy {
  MatrixHierarchy(this.client, {required this.onChange});
  final Client client;
  final VoidCallback onChange;

  /// The space's children the server told us of, or null before the first
  /// fetch lands. Starts a fetch when there is none and none is running.
  List<SpaceRoomsChunk$2>? children(String spaceId);

  /// Drops [spaceId]'s tree, so the next [children] fetches again.
  void invalidate(String spaceId);

  /// Servers to join [roomId] through: the `via` of the `m.space.child`
  /// that lists it.
  List<String> via(String roomId);

  void dispose();
}
```

Check the exact response type name in `~/.pub-cache/hosted/pub.dev/matrix-13.0.0/lib/matrix_api_lite/generated/model.dart` (search `class GetSpaceHierarchyResponse`) before writing it.

**Rules:**
- **Fetching:** `client.getSpaceHierarchy(spaceId, from: nextBatch)` in a loop until `nextBatch == null`.
- **When a fetch fails,** keep the last good tree, and don't retry until the next invalidate.
- **Invalidating:** `MatrixRooms` invalidates a space when a sync's `rooms.join[spaceId].state` or `timeline` carries an `m.space.child` event, or when you join or leave a room it lists.
- **Which children to draw:** in `_space`, a child with no joined `Room` becomes `Channel(id:, name: chunk.name ?? chunk.canonicalAlias ?? 'unnamed', joined: false, kind: voice-or-text by chunk.roomType, topic: chunk.topic)`, subject to its join rule:
  - `invite` and `knock` are skipped;
  - `restricted` is kept only if some `allowed_room_ids` entry is a joined room. Read it from the chunk's `m.space.child`/`m.room.join_rules`. If the chunk only exposes `joinRule`, keep restricted children whose parent space you are in. That is the common case, and the spec's rule.

  Subspace children become categories, as joined ones do now. Unjoined children of an unjoined subspace are shown too: the hierarchy lists them all.
- **Joining a channel:** `setJoined(id, true)` passes `via: _hierarchy.via(id)`.

- [ ] **Step 1: Write the failing tests.** The `_Api` answers `GET /_matrix/client/v1/rooms/<id>/hierarchy` from a map the test fills, with paging by `from`:
  - `'an unjoined child shows as an unjoined channel'`
  - `'invite-only and knock children are not shown'`
  - `'a hierarchy on two pages is read whole'`
  - `'a failed fetch keeps the last tree'`
  - `'a new child in a sync fetches again'`
  - `'joining a listed channel goes through its via servers'`: the `/join` request's query has `server_name=` for each via.
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify.**
  - `analyze` is clean.
  - The suite passes at `+759`.
  - Format the touched files.
- [ ] **Step 5: Commit** `feat(matrix): a space shows the channels you haven't joined`.

### Task 5: Spaces: join, leave, create, and the directory

**Files:**
- Create: `lib/matrix/matrix_space_directory.dart`
- Modify: `lib/matrix/matrix_rooms.dart`
- Test: `test/matrix/matrix_space_directory_test.dart` (new), and a group `'spaces'` in `matrix_rooms_test.dart`

**Behaviour:**
- **`joinSpace(space)`:**
  - `client.joinRoom(space.id, via: <servers from the preview; the alias's server, or the link's via>)`. A refusal throws.
  - Then `invalidate` and fetch its hierarchy.
  - Then join, best-effort and in order, each child that is a subspace, then each child marked `suggested`. Swallow their refusals.
  - To carry the via servers, add `final List<String> via;` (default `const []`) to `SpacePreview` in `lib/ui/model/models.dart`, and use `JoinSpace(space, via:)`. If that's awkward, `joinSpace` asks `directory` for the last preview it served for that id. Pick one and note it in the commit.
- **`leaveSpace(id)`:**
  - Collect the joined descendants, deepest first, excluding any room that another joined top-level space also lists, at any depth.
  - Wish `joined: false` on all of them and the space.
  - Leave each one in turn. Always attempt every leave.
  - If any refuse, throw `PartlyDone(missing: [names that stayed])`.
- **`createSpace(name, me:)`:**
  - `client.createSpace(name: name, visibility: Visibility.private, waitForSync: true)`. A refusal throws.
  - Then for `general` (text) and `hangout` (voice: `creationContent: {'type': 'org.matrix.msc3417.call'}`), call `client.createRoom(name:, preset: CreateRoomPreset.privateChat, initialState: [m.space.parent → space, m.room.join_rules restricted allow room_membership of space])`.
  - Then `space.setSpaceChild(roomId)`.
  - Either channel failing throws `PartlyDone(spaceId: id, missing: ['#general' / 'hangout'])`.
  - Return the space id.
  - Check `createRoom`'s parameter names in `api.dart` first.
- **`MatrixSpaceDirectory`:**
  - `publicSpaces(server)`: `client.queryPublicRooms(server: server, filter: PublicRoomQueryFilter(roomTypes: ['m.space']))`, mapped to `SpacePreview(alias: canonicalAlias ?? roomId, space: Space(id, name, color: spaceColorFor(name)), topic, memberCount: numJoinedMembers, inviteOnly: joinRule == 'invite')`.
  - `lookUp(address)`: parse with `lib/ui/spaces/space_address.dart`'s parser.
    - An alias is resolved with `getRoomIdByAlias` (its `servers` become `via`).
    - A room id takes the link's `via`.
    - Then `getSpaceHierarchy(id, maxDepth: 1, limit: 50)`. Its first chunk is the space, and the rest are its first-level channels, which go into the preview's `Space.categories`.
    - `M_NOT_FOUND` throws `SpaceNotFound`.
- **Abilities:** `addSpace` joins the set.

- [ ] **Step 1: Write the failing tests:**
  - `'joining a space joins its subspaces and suggested channels'`
  - `'a refused suggested channel is skipped, not thrown'`
  - `'leaving a space leaves its rooms deepest first, then the space'`
  - `'leaving a space keeps rooms another joined space lists'`
  - `'a partly refused leave throws PartlyDone naming what stayed'`
  - `'disposing mid-leave notifies nothing'`
  - `'creating a space makes #general and hangout under it'`
  - `'a refused channel still returns the space, as PartlyDone'`
  - In `matrix_space_directory_test.dart`: `'public spaces are filtered to spaces'`, `'an alias looks up and previews'`, `'a matrix.to room-id link looks up and joins via its servers'`, `'nothing there is SpaceNotFound'`.
  - Add `addSpace` to the abilities assertion.
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify.**
  - `analyze` is clean.
  - The suite passes at `+771`.
  - Format the touched files.
- [ ] **Step 5: Commit** `feat(matrix): join, leave, create and find spaces for real`.

### Task 6: DMs without duplicates, and invites

**Files:**
- Modify: `lib/matrix/matrix_rooms.dart`
- Test: group `'people'` in `matrix_rooms_test.dart`

**Behaviour:**
- **`createDirect([one])`:** `await client.startDirectChat(one.id)` reuses the existing DM, and waits for sync by default. Then `_rebuild()` and return the matching `_home` channel.
- **`createDirect(several)`:**
  - First look for a joined direct room whose other members, joined or invited, equal the set exactly. Return it if found.
  - Otherwise `client.createRoom(isDirect: true, invite: ids, preset: CreateRoomPreset.trustedPrivateChat)`, then `client.waitForRoomInSync(id, join: true)`.
  - Then `room.addToDirectChat(ids.first)` if the SDK doesn't already. Check `createRoom`'s `isDirect` handling in `client.dart` before adding it twice.
- **`invite(roomId, ids)`:** `room.invite(id)` for each, collecting `MatrixException.errorMessage` per failed id. Throw `InviteRefused(failed)` if any failed.
- **Abilities:** `startDirect` and `invite` join the set.

- [ ] **Step 1: Write the failing tests:**
  - `'a DM with someone you already talk to opens that DM'`: no `/createRoom` request.
  - `'a group DM with exactly those people is reused'`
  - `'a group DM with different people is new'`
  - `'an invite names who did not go through'`
  - Add `startDirect` and `invite` to the abilities assertion.
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify.**
  - `analyze` is clean.
  - The suite passes at `+775`.
  - Format the touched files.
- [ ] **Step 5: Commit** `feat(matrix): DMs reuse what you have, and invites say who didn't go`.

### Task 7: The space menu, leave-space, and invite people

**Files:**
- Create: `lib/ui/shell/space_actions.dart`, `lib/ui/members/invite_panel.dart`
- Modify: `lib/ui/shell/spaces_rail.dart`, `lib/ui/shell/channel_actions.dart`, `lib/ui/shell/channel_list.dart` (if it builds the allowed set), `lib/ui/shell/app_shell.dart`
- Test: `test/space_actions_test.dart` (new), `test/invite_panel_test.dart` (new)

**Interfaces:**
- `enum SpaceAction { invite, leave }`
- `Future<SpaceAction?> showSpaceActions(BuildContext, Space, {required Set<SpaceAction> allowed})`: a menu at the pointer on desktop and an action sheet on phones, using the same `showActionSheet` and `ActionItem` helpers `channel_actions.dart` uses.
- `Future<bool> confirmLeaveSpace(BuildContext, Space, {required int rooms})`: the text is `'leave ${space.name}?'`, with the body `"you'll leave its $rooms channels too."`. When `rooms == 0` the body is `"you can join again from explore if it's public."`. The buttons are `cancel` and `leave`, before anything is sent.
- `SpacesRail` gains `ValueChanged<String>? onSpaceActions`. `_SpaceItem` wires `onSecondaryTap` when `isDesktop` and `onLongPress` otherwise. When the callback is null, there is no gesture.
- `ChannelAction.invite` goes in `actionsFor` after mute, labelled `'Invite people'`, with the icon `LucideIcons.userPlus`. It is offered for every joined channel except DMs with one other person.
- `Future<void> showInvitePanel(BuildContext, {required String roomName, required List<Member> people, required Future<void> Function(List<String> ids) onInvite})`, an `AdaptivePanel`:
  - It has a search field over `people`, with a checkbox per person, and an `@name:server` field that adds chips.
  - A typed id only counts when it matches `^@[^:\s]+:[^\s]+$`.
  - "invite" is dim until at least one person is chosen, and reads "inviting…" while `onInvite` runs, with no cancel drawn.
  - On success it pops, and the shell toasts `"invited 1 person"` or `"invited N people"`.
  - On `InviteRefused`, the panel stays open. People who went through are removed. Failed ones are marked with `"didn't go through"`. The button reads "try again" and resends only them.
  - Any other error: `"couldn't reach the server. try again?"`.
- **The shell:**
  - `people` is everyone across spaces and Home rooms except you and those already in the room. The new-message code already gathers this: extract a `_knownPeople()` helper.
  - Leaving a space: confirm, then `unawaited(_rooms.leaveSpace(id).catchError(...))`, moving you to Home at once. `PartlyDone` toasts `"couldn't leave everything in ${space.name}"`.
  - Gate the menu items on `RoomAbility.invite` and `RoomAbility.leave`. With neither, pass `onSpaceActions: null`.

- [ ] **Step 1: Write the failing widget tests** (use the mock `AppShell` for shell flows):
  - `'right-clicking a space on a computer opens its menu'` (`_desktop` variant, `tester.tap(..., buttons: kSecondaryButton)`)
  - `'long-pressing a space on a phone opens its menu'`
  - `'leaving a space asks first, then takes it off the rail'`
  - `'cancelling the leave keeps the space'`
  - `'a channel offers invite people'`
  - `'invite is dim until someone is chosen'`
  - `"a malformed id can't be invited"`: `bob`, `@bob` and `bob:loaf.moe` add no chip.
  - `'inviting shows inviting and no cancel'` (over a `Completer`)
  - `"a partly refused invite marks who didn't go and retries only them"`
  - `'a fake rooms without invite or leave draws no space menu'`: this uses `app_shell_rooms_test`'s pattern, in a new file.
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify.**
  - `analyze` is clean.
  - The suite passes at `+785`.
  - Format the touched files.
- [ ] **Step 5: Commit** `feat(shell): a space menu to invite and leave, and an invite panel`.

### Task 8: Busy and failed states for create and new message

**Files:**
- Modify: `lib/ui/spaces/add_space.dart`, `lib/ui/home/new_message_picker.dart`, `lib/ui/shell/app_shell.dart`
- Test: new cases in `test/add_space_test.dart` and `test/new_dm_test.dart`, pumping the panels directly with a slow callback

**Interfaces:**
- **Create:** `AddSpacePanel` gains `Future<String> Function(String name)? onCreate`. When given, "create" calls it in place, rather than popping `CreateSpace`:
  - It reads "creating…" with no cancel.
  - On success it pops `OpenSpace(id)`.
  - On `PartlyDone(spaceId:)` it pops `OpenSpace(spaceId)` with the missing list, carried as a new `OpenSpace(id, missing:)` field. The shell toasts `"made it, but ${missing.join(' and ')} didn't happen"`.
  - Otherwise it shows `"couldn't create. try again?"` and stays.

  `showAddSpace` passes the shell's `_rooms.createSpace`.
- **New message:** `showNewMessagePicker` gains `Future<Channel> Function(List<Member>)? onStart`. When given, starting calls it in place: it reads "starting…", pops `OpenExisting(room)` on success, and shows `"couldn't start. try again?"` on failure.
- Existing tests that expect `CreateSpace` or `CreateDirect` results must still pass. They go through `AppShell`, whose flows still end in the same place, so the results remain in the sealed classes for callers that pass no callback.

- [ ] **Step 1: Write the failing tests:**
  - `'create reads creating and has no cancel while it works'`
  - `"a refused create stays open and says so"`
  - `'a space made without its channels still opens, and says what is missing'`
  - `'starting a DM waits, and a refusal stays open'`
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify.**
  - `analyze` is clean.
  - The suite passes at `+789`.
  - Format the touched files.
- [ ] **Step 5: Commit** `feat(shell): creating a space or starting a DM waits for the server honestly`.

### Task 9: Walk it, and log what's left

- [ ] **Step 1:** Update the roadmap:
  - Mark row 5 with this plan's name.
  - Strike the phase 2 deferral about unjoined channels.
  - Add a "Deferred from phase 5" section with the spec's out-of-scope table, plus anything found in the walk.
- [ ] **Step 2 (controller, not a subagent):** walk every flow in the running mock app (`mise exec -- flutter run -d macos --dart-define=LOAF_BACKEND=mock`, one instance). Covers:
  - the space menu;
  - leave;
  - invite;
  - create;
  - explore;
  - link;
  - new message;
  - mute;
  - favourite and reorder.
- [ ] **Step 3 (controller, with Chris):** a live pass on loaf.moe. Each step needs Chris's okay:
  - join and leave a channel;
  - mute;
  - favourite and reorder;
  - explore and join a space;
  - create a throwaway space and leave it;
  - DM an existing contact (it should reuse);
  - invite the `hermes` service account.
- [ ] **Step 4:** the whole-branch review, then `superpowers:finishing-a-development-branch`.
