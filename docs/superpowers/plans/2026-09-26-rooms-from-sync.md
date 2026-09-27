# Rooms from Sync Implementation Plan (SDK phase 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The rail, channel lists, Home's sections, unreads and member lists come from the SDK's sync instead of fixtures; invites can be accepted and declined for real; and on the real backend the shell draws only the controls that are wired.

**Architecture:** The plain models move out of the fixtures into `lib/ui/model/models.dart`. A `Rooms` interface (`lib/ui/rooms/rooms.dart`) gives the shell plain-model snapshots — spaces, Home's rooms, invites, you — plus the set of `RoomAbility` the backend has. `MockRooms` takes over the fixture overlays `AppShell` kept (membership, mutes, reading, tags, invites) and can do everything; `MatrixRooms` (`lib/matrix/`) maps `client.rooms` after every sync and can only answer invites. `AppShell` takes a `Rooms` factory (default `MockRooms`), keeps only navigation and the call/timeline mocks' overlays, and asks `abilities` before drawing each control. With no conversation to show it shows a first-sync spinner (then a progress bar) or "nothing here yet". `main.dart` passes `() => MatrixRooms(client)` on the matrix backend.

**Tech Stack:** Flutter 3.47.5 via `mise exec -- flutter`; `matrix` 13.0.0. Tests use the SDK's `FakeMatrixApi` (subclassed to answer joins and leaves) and `client.handleSync(...)` to inject spaces, tags, push rules and invites; widget tests use a plain-model fake `Rooms`.

**Spec:** `docs/superpowers/specs/2026-09-26-rooms-from-sync-design.md` (this phase's decisions — read it first), under `docs/superpowers/specs/2026-09-20-loaf-native-design.md` ("Information architecture", "Stack", "Name colour means power level"). Roadmap: `docs/superpowers/plans/2026-09-26-sdk-wiring-roadmap.md`.

**Rehearsed.** Every task below was run on a scratch copy of `40c2cf7` on 2026-09-26, task by task, with `flutter analyze` clean and the suite green at every checkpoint: **495 → 495 → 505 → 505 → 521 → 530 → 538 → 538**. The 495 existing tests pass unchanged throughout. The edits in this plan were extracted mechanically from the rehearsal and re-applied to a fresh copy, which came out byte-identical after `dart format`. `flutter build macos --debug --dart-define=LOAF_BACKEND=matrix` succeeds. If a step here disagrees with what you see, the code moved since: stop and say so rather than improvising.

## Global Constraints

- Only files under `lib/matrix/` (and `lib/main.dart`, which picks the backend) import `package:matrix`. `lib/ui/` never imports `lib/matrix/`. Where a file imports both `package:matrix` and loaf's models, hide the SDK's clashing names (`hide Presence`, `hide Role`).
- The SDK is the store. `MatrixRooms` keeps one derived snapshot, rebuilt from `client.rooms` on every `onSync`, and nothing else.
- The 495 tests that exist today must pass **unchanged**. Never edit an existing test to make it pass; add new tests beside them.
- On the real backend a control the backend cannot carry out is **not drawn** — not disabled, not faked with local state. A menu left empty does not open. No dead ends: every face without a conversation keeps a way to the drawer (and so to sign out) on a phone.
- Copy is lowercase and warm. Split by `isDesktop` from `lib/ui/platform.dart`, never by input device. Spinners are `CircularProgressIndicator.adaptive()` (the system's own on Apple platforms).
- `lib/matrix/` tests use `test()`, not `testWidgets()`: real sqlite and the fake server's timers fight the widget tester's fake clock.
- **Format only the files you touched, by path.** `dart format lib test` rewraps an unrelated, unformatted existing test (`test/session_root_test.dart`). Each task's verify step lists the paths.
- Shell examples must work in Nushell. Run Flutter through mise: `mise exec -- flutter analyze`, `mise exec -- flutter test`.
- Each task ends at a checkpoint with a suggested conventional commit. **Commit only when Chris has said to for this run.** Every commit ends with the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`, exactly that, whichever model you are.
- Chris's loaf.moe account is SSO-only (Kanidm). Anything touching his real account beyond signing in and reading is asked about first.

## Review Focus

1. **An invite answered twice, or late.** A double tap, or a preview left open while another device answers, must send at most one request and never hang. `whenComplete(() => map.remove(id))` returns the future itself and deadlocks — the rehearsal hit exactly this. Pinned in Task 4 ("accepting an invite asks the server once, however many taps", "a refused accept throws, and the invite stays") and Task 6 ("while an answer is on its way, neither button answers").
2. **State the SDK does not keep in memory.** For rooms that are only listed, the SDK keeps just its "important" state: topics, join rules, power levels and members are missing unless asked for. Pinned in Task 4 ("a channel carries its counts, topic and lock", "members carry their power level, and no presence yet"), which fail without `importantStateEvents` and `loadMembers`.
3. **A member list fetched on every build.** The shell asks for members as it builds; a fetch that rebuilds must not fetch again. Pinned in Task 4 ("a member list is asked for once, however often it is wanted").
4. **A room or space vanishing while you look at it** (left or kicked from another client). The shell must fall back — the next channel, or Home — never throw. Pinned in Task 6 ("a room that vanishes falls back to the next", "a space that vanishes falls back to Home").
5. **Duplicate DMs that do not fold** because their person comes from member state that is not loaded. A DM's people come from `m.heroes`, else the `m.direct` person. Pinned in Task 4 ("two DMs with one person name the same person, so they fold").

## File Map

| File | Task | Responsibility |
|---|---|---|
| `lib/ui/model/models.dart` (new), `lib/ui/mock/fixtures.dart` | 1 | the plain models, moved; fixtures re-export them |
| `lib/ui/rooms/rooms.dart` (new) | 2 | the `Rooms` interface and `RoomAbility` |
| `lib/ui/mock/mock_rooms.dart` (new) | 2 | fixture rooms with this session's changes layered over them |
| `lib/ui/shell/app_shell.dart` | 3, 5, 6 | reads a `Rooms`; asks its abilities; faces and fallbacks |
| `lib/matrix/matrix_rooms.dart` (new), `lib/matrix/client_factory.dart` | 4 | rooms mapped from sync; invites answered; the state kept in memory |
| `lib/ui/shell/channel_actions.dart`, `channel_list.dart`, `spaces_rail.dart`, `user_bar.dart`, `lib/ui/channel/channel_view.dart`, `lib/ui/settings/settings_page.dart`, `account_section.dart` | 5 | only what is wired is drawn |
| `lib/ui/shell/shell_faces.dart` (new), `lib/ui/home/invite_preview.dart` | 6 | the first-sync and empty faces; an answer on its way |
| `lib/ui/auth/session_root.dart`, `lib/main.dart` | 7 | the matrix backend's rooms reach the shell |

## Notes for whoever executes this

- **Edits are exact.** Each "replace … with …" block is a verbatim `old_string` → `new_string` for the Edit tool, whitespace included; each old block occurs exactly once in its file at that point in the plan. Apply them in order — later edits in a file assume the earlier ones.
- **Test counts** are the whole suite's, printed as `+N: All tests passed!`. Before Task 1 it is 495.
- **Dispatching subagents:** cheap models transcribe these edits well; review each task with a fresh reviewer; the whole branch gets a final review on opus. Give implementers the Global Constraints verbatim, the exact trailer, the paths to format, and the before/after counts.

---

### Task 1: The models move out of the fixtures

A pure move, done by script so nothing is retyped: the model classes (`ChannelKind`, `Role`, `Member`, `Reaction`, `CallLine`, `Message`, `Channel`, `ChannelCategory`, `Space`, the timeline grouping, `InviteKind`, `Invite`, `SpacePreview`) go to `lib/ui/model/models.dart`. `fixtures.dart` keeps only the fake data and re-exports the models, so every existing `import '../mock/fixtures.dart'` still sees them. No new tests: the 495 existing ones are the proof.

**Files:**
- Create: `lib/ui/model/models.dart`
- Modify: `lib/ui/mock/fixtures.dart`

**Interfaces:**
- Produces: `package:loaf_native/ui/model/models.dart` exporting every model above, unchanged. Later tasks import it directly; `fixtures.dart` re-exports it.

- [ ] **Step 1: Save the move script** to the scratchpad (not the repo) as `split_models.py`. The line numbers are for `40c2cf7`, and the asserts stop it if the file has moved.

```python
# Moves the plain models out of lib/ui/mock/fixtures.dart into
# lib/ui/model/models.dart. Line ranges are for commit 40c2cf7.
import pathlib, sys
src = pathlib.Path('lib/ui/mock/fixtures.dart')
lines = src.read_text().split('\n')
def rng(a, b): return lines[a-1:b]
assert lines[12].startswith('// ── Models'), lines[11]
assert lines[396] == '}' and 'return entries;' in lines[395], lines[394:397]
assert lines[628] == 'enum InviteKind { direct, room, space }', lines[628]
assert lines[668] == '}' and 'invited you' in lines[667], lines[666:669]
assert lines[962].startswith('/// A space seen from outside'), lines[962]
assert lines[982] == '}' and lines[984].startswith('const _pizza'), lines[982:985]
header = '''/// The plain models the widgets render. Nothing here talks to the network
/// or to matrix-dart-sdk: the mock fills these constructors from fixtures,
/// and `lib/matrix/` fills them from the SDK, so the widget tree is the same
/// either way.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../members/presence.dart';
'''.split('\n')
model = header + rng(13, 397) + [''] + rng(629, 669) + [''] + rng(963, 983) + ['']
rest = lines[:12] + lines[397:628] + lines[669:962] + lines[983:]
# fixtures keeps its own imports and re-exports the models, so every
# existing `import '../mock/fixtures.dart'` still sees them.
rest = ['/// Fake data for the UI mockups, and for the mock backend that stays',
        '/// behind the real one for tests, previews and the debug levers. The',
        '/// models themselves live in `lib/ui/model/models.dart`.'] + rest[5:]
rest.remove("import 'package:lucide_icons_flutter/lucide_icons.dart';")
out = []
for l in rest:
    out.append(l)
    if l == "import '../members/presence.dart';":
        out.append("import '../model/models.dart';")
        out.append('')
        out.append("export '../model/models.dart';")
pathlib.Path('lib/ui/model').mkdir(exist_ok=True)
pathlib.Path('lib/ui/model/models.dart').write_text('\n'.join(model))
src.write_text('\n'.join(out))
```

- [ ] **Step 2: Run it from the repo root**

```bash
python3 <scratchpad>/split_models.py
```

Expected: no output. `lib/ui/model/models.dart` exists and `lib/ui/mock/fixtures.dart` opens with the new doc comment and `export '../model/models.dart';`.

- [ ] **Format what you touched, by path, then analyze and run everything**

```bash
mise exec -- dart format lib/ui/model/models.dart lib/ui/mock/fixtures.dart
```

```bash
mise exec -- flutter analyze
```

```bash
mise exec -- flutter test
```

Expected: `No issues found!` and `+495: All tests passed!`.

- [ ] **Checkpoint: commit (only if Chris has said to commit this run)**

```bash
git add lib/ui/model/models.dart lib/ui/mock/fixtures.dart
```

```bash
git commit -m "refactor(model): the plain models leave the fixtures" -m "The SDK is about to fill these constructors, so they are no longer fixtures. fixtures.dart re-exports them, so nothing that imports it changes." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: The `Rooms` seam and `MockRooms`

The interface the shell will read, and the mock that plays it. `MockRooms` holds what `AppShell` layers over the fixtures today — membership, mutes, what has been read, favourites and their order, low priority, answered invites, accepted rooms and spaces — with the same rules (Task 3 moves the shell onto it). Nothing uses them yet.

**Files:**
- Create: `lib/ui/rooms/rooms.dart`, `lib/ui/mock/mock_rooms.dart`
- Test: `test/mock_rooms_test.dart`

**Interfaces:**
- Consumes: the models from Task 1; `spaceColorFor(String)` from `lib/ui/spaces/add_space.dart`; `currentUser`, `mockSpaces`, `mockHomeRooms`, `mockInvites` from the fixtures.
- Produces:
  - `enum RoomAbility { markRead, mute, leave, join, tag, answerInvites, addSpace, startDirect, calls, messages, editProfile }`
  - `abstract interface class Rooms implements Listenable` with `Set<RoomAbility> abilities`, `bool synced`, `double? syncProgress`, `Member me`, `List<Space> spaces`, `List<Channel> homeRooms`, `List<Invite> invites`, `void loadMembers(String roomId)`, `void markRead(String)`, `void setMuted(String, bool)`, `void setJoined(String, bool)`, `void setFavourite(String, bool)`, `void reorderFavourites(List<String>)`, `void setLowPriority(String, bool)`, `Future<void> accept(Invite)`, `Future<void> decline(Invite)`, `void joinSpace(Space)`, `String createSpace(String name, {required Member me})`, `Channel createDirect(List<Member>)`, `void dispose()`.
  - `class MockRooms extends ChangeNotifier implements Rooms` — every ability; `accept`/`decline` return a `SynchronousFuture`, so a caller that awaits carries on in the same frame.

- [ ] **Step 1: Write the failing test** — `test/mock_rooms_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/mock/fixtures.dart';
import 'package:loaf_native/ui/mock/mock_rooms.dart';
import 'package:loaf_native/ui/rooms/rooms.dart';

Channel _home(MockRooms rooms, String id) =>
    rooms.homeRooms.firstWhere((c) => c.id == id);

Channel _channel(MockRooms rooms, String id) =>
    rooms.spaces.expand((s) => s.allChannels).firstWhere((c) => c.id == id);

void main() {
  late MockRooms rooms;
  var heard = 0;

  setUp(() {
    rooms = MockRooms();
    heard = 0;
    rooms.addListener(() => heard++);
  });
  tearDown(() => rooms.dispose());

  test('can do everything, and is synced from the start', () {
    expect(rooms.abilities, RoomAbility.values.toSet());
    expect(rooms.synced, isTrue);
    expect(rooms.syncProgress, isNull);
    expect(rooms.me, currentUser);
  });

  test('marking read clears a room\'s counts, once', () {
    expect(_home(rooms, 'fermentation').unread, greaterThan(0));
    rooms
      ..markRead('fermentation')
      ..markRead('fermentation');
    expect(_home(rooms, 'fermentation').unread, 0);
    expect(heard, 1);
  });

  test('marking a space channel read recounts the space', () {
    final space = rooms.spaces.first;
    final unread = space.allChannels.firstWhere((c) => c.unread > 0);
    rooms.markRead(unread.id);
    expect(_channel(rooms, unread.id).unread, 0);
    expect(_channel(rooms, unread.id).mentions, 0);
  });

  test('a left Home room is gone; a left channel stays, to rejoin', () {
    final channel = rooms.spaces.first.allChannels.firstWhere(
      (c) => !c.private,
    );
    rooms
      ..setJoined('admins', false)
      ..setJoined(channel.id, false);
    expect(rooms.homeRooms.map((c) => c.id), isNot(contains('admins')));
    expect(_channel(rooms, channel.id).joined, isFalse);
  });

  test('a new favourite goes last, and reordering is kept', () {
    rooms.setFavourite('admins', true);
    final favourites = rooms.homeRooms.where((c) => c.favourite).toList()
      ..sort((a, b) => a.favouriteOrder!.compareTo(b.favouriteOrder!));
    expect(favourites.last.id, 'admins');
    rooms.reorderFavourites(['admins', 'dm-mika']);
    expect(_home(rooms, 'admins').favouriteOrder, 0);
  });

  test('muting and low priority reach Home rooms', () {
    rooms
      ..setMuted('admins', true)
      ..setLowPriority('admins', true);
    expect(_home(rooms, 'admins').muted, isTrue);
    expect(_home(rooms, 'admins').lowPriority, isTrue);
  });

  test('accepting a DM invite brings it into Home at once', () {
    final invite = rooms.invites.firstWhere((i) => i.room != null);
    var done = false;
    rooms.accept(invite).then((_) => done = true);
    // A SynchronousFuture: the shell carries on in the same frame.
    expect(done, isTrue);
    expect(rooms.invites, isNot(contains(invite)));
    expect(rooms.homeRooms.map((c) => c.id), contains(invite.room!.id));
  });

  test('joining a space you were invited to answers the invite', () {
    final invite = rooms.invites.firstWhere((i) => i.space != null);
    rooms.joinSpace(invite.space!);
    expect(rooms.invites, isNot(contains(invite)));
    expect(rooms.spaces.map((s) => s.id), contains(invite.space!.id));
  });

  test('a made space has #general and a voice channel', () {
    final id = rooms.createSpace('Crumb Club', me: currentUser);
    final space = rooms.spaces.firstWhere((s) => s.id == id);
    expect(space.allChannels.map((c) => c.name), ['general', 'hangout']);
  });

  test('a started DM is in Home, waiting on its people', () {
    final ada = rooms.homeRooms
        .firstWhere((c) => c.id == 'dm-ada')
        .members
        .single;
    final dm = rooms.createDirect([ada]);
    expect(_home(rooms, dm.id).waitingFor, [ada]);
  });
}
```

- [ ] **Step 2: Run it to see it fail**

```bash
mise exec -- flutter test test/mock_rooms_test.dart
```

Expected: FAIL — `mock_rooms.dart` and `rooms.dart` do not exist.

- [ ] **Step 3: Create `lib/ui/rooms/rooms.dart`**

```dart
/// The account's rooms, as the shell draws them: the rail's spaces, each
/// space's channels, Home's rooms and your invites. [MockRooms] plays them
/// from fixtures; `MatrixRooms` maps them from the SDK's sync.
library;

import 'package:flutter/foundation.dart';

import '../model/models.dart';

/// What a backend can do to your rooms yet. The shell draws no control for
/// anything missing: a control that only pretends would lie about your real
/// account, which is still there on relaunch.
enum RoomAbility {
  /// Mark as read, and reading by opening.
  markRead,
  mute,
  leave,

  /// Joining an unjoined channel from its row.
  join,

  /// Favourite and low priority, and reordering favourites.
  tag,

  /// Accepting and declining an invite.
  answerInvites,
  addSpace,
  startDirect,

  /// Voice channels and DM calls.
  calls,

  /// Reading a conversation and writing in it.
  messages,

  /// Your presence, status message and profile.
  editProfile,
}

abstract interface class Rooms implements Listenable {
  Set<RoomAbility> get abilities;

  /// False until the first sync has landed. A relaunch restores from the
  /// database, so only a fresh sign-in waits on this.
  bool get synced;

  /// How far through handling the first sync's rooms, 0 to 1; null while
  /// still waiting on the server, which says nothing about how long.
  double? get syncProgress;

  /// You, as the rooms know you.
  Member get me;

  /// The rail, in order.
  List<Space> get spaces;

  /// Everything that lives in Home, before `homeSections` sorts it.
  List<Channel> get homeRooms;

  List<Invite> get invites;

  /// Asks for a room's full member list, where the backend loaded only
  /// some of it. Listeners hear when it arrives.
  void loadMembers(String roomId);

  void markRead(String roomId);
  void setMuted(String roomId, bool muted);
  void setJoined(String roomId, bool joined);
  void setFavourite(String roomId, bool favourite);

  /// Favourites in this order, first to last.
  void reorderFavourites(List<String> roomIds);
  void setLowPriority(String roomId, bool lowPriority);

  /// Throws when the server says no; the invite then stays.
  Future<void> accept(Invite invite);
  Future<void> decline(Invite invite);

  void joinSpace(Space space);

  /// Returns the new space's id.
  String createSpace(String name, {required Member me});

  /// Returns the new DM, which is already in [homeRooms].
  Channel createDirect(List<Member> members);

  void dispose();
}
```

- [ ] **Step 4: Create `lib/ui/mock/mock_rooms.dart`**

```dart
/// [Rooms] played from fixtures, with this session's changes layered over
/// them — the mock's stand-in for membership, read markers, push rules and
/// room tags arriving over sync. Every action works, and none outlives the
/// app.
library;

import 'package:flutter/foundation.dart';

import '../rooms/rooms.dart';
import '../spaces/add_space.dart' show spaceColorFor;
import 'fixtures.dart';

class MockRooms extends ChangeNotifier implements Rooms {
  // This session's changes, layered over the fixtures by Space.withSession.
  final _membership = <String, bool>{};
  final _muted = <String, bool>{};
  final _read = <String>{};

  // Home's room tags, as this session has them. Favourites are a list so
  // their order is the list's; m.favourite's `order` is its position.
  final _favourites = [
    for (final room in [
      ...mockHomeRooms,
    ]..sort((a, b) => (a.favouriteOrder ?? 1).compareTo(b.favouriteOrder ?? 1)))
      if (room.favourite) room.id,
  ];
  final _lowPriority = <String, bool>{};

  /// When a room joined or made this session last saw activity.
  final _activity = <String, DateTime>{};

  // Invites answered this session, and what accepting them brought in.
  final _answeredInvites = <String>{};
  final _acceptedRooms = <Channel>[];
  final _acceptedSpaces = <Space>[];

  var _made = 0;
  var _started = 0;

  @override
  Set<RoomAbility> get abilities => RoomAbility.values.toSet();

  @override
  bool get synced => true;

  @override
  double? get syncProgress => null;

  @override
  Member get me => currentUser;

  /// With this session's reading applied, so badges recount. A left
  /// invite-only channel is dropped: only channels you could join in one
  /// tap are ever listed.
  @override
  List<Space> get spaces => [
    for (final space in [...mockSpaces, ..._acceptedSpaces])
      space.withSession(membership: _membership, muted: _muted, read: _read),
  ];

  /// Home's rooms with this session's tags, mutes and reading applied.
  /// Rooms you have left are gone: Home has no "join" pills, only what you
  /// are in.
  @override
  List<Channel> get homeRooms => [
    for (final room in [...mockHomeRooms, ..._acceptedRooms])
      if (_membership[room.id] != false)
        room.copyWith(
          favourite: _favourites.contains(room.id),
          favouriteOrder: _favourites.contains(room.id)
              ? _favourites.indexOf(room.id) / _favourites.length
              : null,
          lowPriority: _lowPriority[room.id],
          lastActivity: _activity[room.id],
          muted: _muted[room.id],
          // Read state is applied per room here, before duplicates fold
          // together, so an older room's unreads still count on the row.
          unread: _read.contains(room.id) ? 0 : room.unread,
          mentions: _read.contains(room.id) ? 0 : room.mentions,
        ),
  ];

  @override
  List<Invite> get invites => [
    for (final invite in mockInvites)
      if (!_answeredInvites.contains(invite.id)) invite,
  ];

  /// The fixtures carry their members whole.
  @override
  void loadMembers(String roomId) {}

  void _change(VoidCallback change) {
    change();
    notifyListeners();
  }

  @override
  void markRead(String roomId) {
    if (_read.contains(roomId)) return;
    _change(() => _read.add(roomId));
  }

  @override
  void setMuted(String roomId, bool muted) =>
      _change(() => _muted[roomId] = muted);

  @override
  void setJoined(String roomId, bool joined) =>
      _change(() => _membership[roomId] = joined);

  /// A new favourite goes last.
  @override
  void setFavourite(String roomId, bool favourite) => _change(() {
    _favourites.remove(roomId);
    if (favourite) _favourites.add(roomId);
  });

  @override
  void reorderFavourites(List<String> roomIds) => _change(
    () => _favourites
      ..clear()
      ..addAll(roomIds),
  );

  @override
  void setLowPriority(String roomId, bool lowPriority) =>
      _change(() => _lowPriority[roomId] = lowPriority);

  /// A DM or room joins Home, newest; a space joins the rail. Answered at
  /// once, so callers carry on in the same frame.
  @override
  Future<void> accept(Invite invite) {
    _change(() {
      _answeredInvites.add(invite.id);
      final room = invite.room;
      final space = invite.space;
      if (room != null) {
        _acceptedRooms.add(room);
        _activity[room.id] = DateTime.now();
      } else if (space != null) {
        _acceptedSpaces.add(space);
      }
    });
    return SynchronousFuture(null);
  }

  @override
  Future<void> decline(Invite invite) {
    _change(() => _answeredInvites.add(invite.id));
    return SynchronousFuture(null);
  }

  /// Joining a space you were invited to answers the invite.
  @override
  void joinSpace(Space space) => _change(() {
    _acceptedSpaces.add(space);
    for (final invite in mockInvites) {
      if (invite.space?.id == space.id) _answeredInvites.add(invite.id);
    }
  });

  /// The mock's space creation: the space room, then #general and a voice
  /// channel as its children, both restricted to its members.
  @override
  String createSpace(String name, {required Member me}) {
    final id = 'made-${_made++}';
    _change(
      () => _acceptedSpaces.add(
        Space(
          id: id,
          name: name,
          color: spaceColorFor(name),
          members: [me],
          categories: [
            ChannelCategory('', [
              Channel(id: '$id-general', name: 'general'),
              Channel(
                id: '$id-hangout',
                name: 'hangout',
                kind: ChannelKind.voice,
              ),
            ]),
          ],
        ),
      ),
    );
    return id;
  }

  /// The mock's createRoom: is_direct, trusted_private_chat, the people
  /// invited, and the room added to m.direct.
  @override
  Channel createDirect(List<Member> members) {
    final room = Channel(
      id: 'dm-new-${_started++}',
      name: members.length == 1
          ? members.single.name
          : members.map((m) => m.name.split(' ').first).join(', '),
      kind: ChannelKind.direct,
      members: members,
      waitingFor: members,
    );
    _change(() {
      _acceptedRooms.add(room);
      _activity[room.id] = DateTime.now();
    });
    return room;
  }
}
```

- [ ] **Step 5: Run the test to see it pass**

```bash
mise exec -- flutter test test/mock_rooms_test.dart
```

Expected: `+10: All tests passed!`

- [ ] **Format what you touched, by path, then analyze and run everything**

```bash
mise exec -- dart format lib/ui/rooms/rooms.dart lib/ui/mock/mock_rooms.dart test/mock_rooms_test.dart
```

```bash
mise exec -- flutter analyze
```

```bash
mise exec -- flutter test
```

Expected: `No issues found!` and `+505: All tests passed!`.

- [ ] **Checkpoint: commit (only if Chris has said to commit this run)**

```bash
git add lib/ui/rooms/rooms.dart lib/ui/mock/mock_rooms.dart test/mock_rooms_test.dart
```

```bash
git commit -m "feat(rooms): a Rooms seam, and the mock behind it" -m "The shell will read its rooms through Rooms, as the sign-in screen reads a Homeserver. MockRooms takes the fixture overlays the shell keeps today, with the same rules, and can do everything." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: The shell reads its rooms

`AppShell` takes an optional `Rooms Function()? rooms` factory (default `MockRooms`), makes its rooms once in state, listens to them, and disposes them. Its fixture overlays go; `_spaces`, `_invites` and `_homeRooms` read the rooms, and every action calls them. It keeps navigation and the two overlays that belong to the call and timeline mocks — missed-call unreads and DM activity bumps — layered over the snapshots with the existing `Space.withSession`. Mock behaviour is identical: the existing tests pass unchanged, and there are no new ones.

Note for reviewers: `_open` marks the opened room read *inside* `setState`, and `MockRooms.markRead` notifies, which calls the shell's `setState` again — nested `setState` is fine. `initState` marks the first room read *before* adding the listener, since nothing is built yet to hear it. `markRead` returns early when already read, so opening a read room does not notify.

**Files:**
- Modify: `lib/ui/shell/app_shell.dart`

**Interfaces:**
- Consumes: `Rooms`, `MockRooms` (Task 2).
- Produces: `AppShell({Key? key, LoafSession? session, Rooms Function()? rooms})`. The shell owns and disposes what the factory returns.

- [ ] **Step 1: Apply the edits, in order**

**Edit 1** — `lib/ui/shell/app_shell.dart`: replace

```dart
import '../mock/fixtures.dart';
```

with

```dart
import '../mock/fixtures.dart';
import '../mock/mock_rooms.dart';
```

**Edit 2** — `lib/ui/shell/app_shell.dart`: replace

```dart
import '../platform.dart';
```

with

```dart
import '../platform.dart';
import '../rooms/rooms.dart';
```

**Edit 3** — `lib/ui/shell/app_shell.dart`: replace

```dart
class AppShell extends StatefulWidget {
  const AppShell({super.key, this.session});

  /// Who is signed in, and how far this device is trusted. The app passes
  /// its one session; left out (tests, previews), the shell makes its own.
  final LoafSession? session;
```

with

```dart
class AppShell extends StatefulWidget {
  const AppShell({super.key, this.session, this.rooms});

  /// Who is signed in, and how far this device is trusted. The app passes
  /// its one session; left out (tests, previews), the shell makes its own.
  final LoafSession? session;

  /// Makes the account's rooms, once, when the shell opens; the shell
  /// disposes them when it closes. Left out, the rooms are the mock's.
  final Rooms Function()? rooms;
```

**Edit 4** — `lib/ui/shell/app_shell.dart`: replace

```dart
  late final LoafSession _session = widget.session ?? MockSession();
```

with

```dart
  late final LoafSession _session = widget.session ?? MockSession();
  late final Rooms _rooms = widget.rooms?.call() ?? MockRooms();
```

**Edit 5** — `lib/ui/shell/app_shell.dart`: replace

```dart
  @override
  void initState() {
    super.initState();
    // The channel the app opens on is being read from the first frame.
    _read.add(_channel.id);
    _profile.addListener(_onChange);
```

with

```dart
  @override
  void initState() {
    super.initState();
    // The channel the app opens on is being read from the first frame.
    // Before listening: nothing is built yet to hear it.
    _rooms.markRead(_channel.id);
    _rooms.addListener(_onChange);
    _profile.addListener(_onChange);
```

**Edit 6** — `lib/ui/shell/app_shell.dart`: replace

```dart
    _session.removeListener(_onSessionChange);
    _verification?.dispose();
```

with

```dart
    _session.removeListener(_onSessionChange);
    _rooms
      ..removeListener(_onChange)
      ..dispose();
    _verification?.dispose();
```

**Edit 7** — `lib/ui/shell/app_shell.dart`: replace

```dart
  String _spaceId = mockSpaces.first.id;
```

with

```dart
  late String _spaceId = _rooms.spaces.firstOrNull?.id ?? mockHome.id;
```

**Edit 8** — `lib/ui/shell/app_shell.dart`: replace

```dart
  // This session's changes, layered over the fixtures by Space.withSession.
  final _membership = <String, bool>{};
  final _mutedNow = <String, bool>{};
  final _read = <String>{};
  final _missedCalls = <String, int>{};

  // Home's room tags, as this session has them. Favourites are a list so
  // their order is the list's; m.favourite's `order` is its position.
  late final _favourites = [
    for (final room in [
      ...mockHomeRooms,
    ]..sort((a, b) => (a.favouriteOrder ?? 1).compareTo(b.favouriteOrder ?? 1)))
      if (room.favourite) room.id,
  ];
  final _lowPriority = <String, bool>{};

  /// When a DM last saw a message or a call, this session.
  final _activity = <String, DateTime>{};

  // Invites answered this session, and what accepting them brought in.
  final _answeredInvites = <String>{};
  final _acceptedRooms = <Channel>[];
  final _acceptedSpaces = <Space>[];

  /// The invite being previewed in place of a conversation, if any.
  String? _previewInvite;

  List<Space> get _spaces => [...mockSpaces, ..._acceptedSpaces];

  List<Invite> get _invites => [
    for (final invite in mockInvites)
      if (!_answeredInvites.contains(invite.id)) invite,
  ];

  bool get _home => _spaceId == mockHome.id;

  /// Home's rooms with this session's tags and activity applied. Rooms you
  /// have left are gone: Home has no "join" pills, only what you are in.
  List<Channel> get _homeRooms => [
    for (final room in [...mockHomeRooms, ..._acceptedRooms])
      if (_membership[room.id] != false)
        room.copyWith(
          favourite: _favourites.contains(room.id),
          favouriteOrder: _favourites.contains(room.id)
              ? _favourites.indexOf(room.id) / _favourites.length
              : null,
          lowPriority: _lowPriority[room.id],
          lastActivity: _activity[room.id],
          // Read state is applied per room here, before duplicates fold
          // together, so an older room's unreads still count on the row.
          unread:
              (_read.contains(room.id) ? 0 : room.unread) +
              (_missedCalls[room.id] ?? 0),
          mentions: _read.contains(room.id) ? 0 : room.mentions,
        ),
  ];

  Space get _space {
    if (!_home) {
      return _spaces
          .firstWhere((s) => s.id == _spaceId)
          .withSession(
            membership: _membership,
            muted: _mutedNow,
            read: _read,
            occupants: _callOccupants,
            unread: _missedCalls,
          );
    }
    // Home's rooms already carry their read state; see _homeRooms.
    return Space(
      id: mockHome.id,
      name: mockHome.name,
      color: mockHome.color,
      members: mockHome.members,
      categories: homeSections(collapseDuplicates(_homeRooms)),
    ).withSession(
      membership: _membership,
      muted: _mutedNow,
      occupants: _callOccupants,
    );
  }
```

with

```dart
  // What the call and timeline mocks add over the rooms: missed calls
  // count as unread, and a DM that saw a message or a call moves up. They
  // go when those mocks do.
  final _missedCalls = <String, int>{};
  final _activity = <String, DateTime>{};

  /// The invite being previewed in place of a conversation, if any.
  String? _previewInvite;

  List<Space> get _spaces => _rooms.spaces;

  List<Invite> get _invites => _rooms.invites;

  bool get _home => _spaceId == mockHome.id;

  /// Home's rooms with the calls' and timelines' changes layered on.
  List<Channel> get _homeRooms => [
    for (final room in _rooms.homeRooms)
      room.copyWith(
        lastActivity: _activity[room.id],
        // Per room, before duplicates fold together, so an older room's
        // missed calls still count on the row.
        unread: room.unread + (_missedCalls[room.id] ?? 0),
      ),
  ];

  Space get _space {
    if (!_home) {
      return _spaces
          .firstWhere((s) => s.id == _spaceId)
          .withSession(occupants: _callOccupants, unread: _missedCalls);
    }
    return Space(
      id: mockHome.id,
      name: mockHome.name,
      color: mockHome.color,
      members: mockHome.members,
      categories: homeSections(collapseDuplicates(_homeRooms)),
    ).withSession(occupants: _callOccupants);
  }
```

**Edit 9** — `lib/ui/shell/app_shell.dart`: replace

```dart
    // Seeing a conversation is reading it, in a space as much as in Home.
    _read.add(channelId);
    _missedCalls.remove(channelId);
```

with

```dart
    // Seeing a conversation is reading it, in a space as much as in Home.
    _rooms.markRead(channelId);
    _missedCalls.remove(channelId);
```

**Edit 10** — `lib/ui/shell/app_shell.dart`: replace

```dart
      if (joining) _membership[id] = true;
```

with

```dart
      if (joining) _rooms.setJoined(id, true);
```

**Edit 11** — `lib/ui/shell/app_shell.dart`: replace

```dart
      case ChannelAction.markRead:
        _read.add(id);
      case ChannelAction.favourite:
        _favourites.add(id);
      case ChannelAction.unfavourite:
        _favourites.remove(id);
      case ChannelAction.lowPriority:
        _lowPriority[id] = true;
      case ChannelAction.notLowPriority:
        _lowPriority[id] = false;
      case ChannelAction.olderConversations:
        break; // Handled before any state changes: it asks first.
      case ChannelAction.mute:
        _mutedNow[id] = true;
      case ChannelAction.unmute:
        _mutedNow[id] = false;
      case ChannelAction.leave:
        // Leaving the channel you are reading falls through to the space's
        // first joined text channel: see _channel.
        _membership[id] = false;
```

with

```dart
      case ChannelAction.markRead:
        _rooms.markRead(id);
      case ChannelAction.favourite:
        _rooms.setFavourite(id, true);
      case ChannelAction.unfavourite:
        _rooms.setFavourite(id, false);
      case ChannelAction.lowPriority:
        _rooms.setLowPriority(id, true);
      case ChannelAction.notLowPriority:
        _rooms.setLowPriority(id, false);
      case ChannelAction.olderConversations:
        break; // Handled before any state changes: it asks first.
      case ChannelAction.mute:
        _rooms.setMuted(id, true);
      case ChannelAction.unmute:
        _rooms.setMuted(id, false);
      case ChannelAction.leave:
        // Leaving the channel you are reading falls through to the space's
        // first joined text channel: see _channel.
        _rooms.setJoined(id, false);
```

**Edit 12** — `lib/ui/shell/app_shell.dart`: replace

```dart
  // ── Adding spaces ──────────────────────────────────────────────────

  var _made = 0;
```

with

```dart
  // ── Adding spaces ──────────────────────────────────────────────────
```

**Edit 13** — `lib/ui/shell/app_shell.dart`: replace

```dart
        case JoinSpace(:final space):
          _acceptedSpaces.add(space);
          // Joining a space you were invited to answers the invite.
          for (final invite in mockInvites) {
            if (invite.space?.id == space.id) _answeredInvites.add(invite.id);
          }
          _spaceId = space.id;
        case CreateSpace(:final name):
          // The mock's space creation: the space room, then #general and a
          // voice channel as its children, both restricted to its members.
          final id = 'made-${_made++}';
          _acceptedSpaces.add(
            Space(
              id: id,
              name: name,
              color: spaceColorFor(name),
              members: [_profile.me],
              categories: [
                ChannelCategory('', [
                  Channel(id: '$id-general', name: 'general'),
                  Channel(
                    id: '$id-hangout',
                    name: 'hangout',
                    kind: ChannelKind.voice,
                  ),
                ]),
              ],
            ),
          );
          _open(id, '$id-general');
```

with

```dart
        case JoinSpace(:final space):
          _rooms.joinSpace(space);
          _spaceId = space.id;
        case CreateSpace(:final name):
          final id = _rooms.createSpace(name, me: _profile.me);
          _open(id, '$id-general');
```

**Edit 14** — `lib/ui/shell/app_shell.dart`: replace

```dart
  // ── New messages ───────────────────────────────────────────────────

  var _started = 0;
```

with

```dart
  // ── New messages ───────────────────────────────────────────────────
```

**Edit 15** — `lib/ui/shell/app_shell.dart`: replace

```dart
        case CreateDirect(:final members):
          // The mock's createRoom: is_direct, trusted_private_chat, the
          // people invited, and the room added to m.direct.
          final room = Channel(
            id: 'dm-new-${_started++}',
            name: members.length == 1
                ? members.single.name
                : members.map((m) => m.name.split(' ').first).join(', '),
            kind: ChannelKind.direct,
            members: members,
            waitingFor: members,
          );
          _acceptedRooms.add(room);
          _activity[room.id] = DateTime.now();
          _open(mockHome.id, room.id);
```

with

```dart
        case CreateDirect(:final members):
          _open(mockHome.id, _rooms.createDirect(members).id);
```

**Edit 16** — `lib/ui/shell/app_shell.dart`: replace

```dart
  /// A DM or room joins its section and opens; a space joins the rail and
  /// you stay in Home, where the rest of your invites are.
  void _acceptInvite(Invite invite) => setState(() {
    _answeredInvites.add(invite.id);
    _previewInvite = null;
    final room = invite.room;
    final space = invite.space;
    if (room != null) {
      _acceptedRooms.add(room);
      _activity[room.id] = DateTime.now();
      _open(mockHome.id, room.id);
    } else if (space != null) {
      _acceptedSpaces.add(space);
    }
  });

  void _declineInvite(Invite invite) => setState(() {
    _answeredInvites.add(invite.id);
    _previewInvite = null;
  });
```

with

```dart
  /// A DM or room joins its section and opens; a space joins the rail and
  /// you stay in Home, where the rest of your invites are.
  Future<void> _acceptInvite(Invite invite) async {
    await _rooms.accept(invite);
    if (!mounted) return;
    setState(() {
      _previewInvite = null;
      final room = invite.room;
      if (room != null) _open(mockHome.id, room.id);
    });
  }

  Future<void> _declineInvite(Invite invite) async {
    await _rooms.decline(invite);
    if (!mounted) return;
    setState(() => _previewInvite = null);
  }
```

**Edit 17** — `lib/ui/shell/app_shell.dart`: replace

```dart
              // With this session's reading applied, so badges recount.
              spaces: [
                for (final space in _spaces)
                  space.withSession(
                    membership: _membership,
                    muted: _mutedNow,
                    read: _read,
                  ),
              ],
```

with

```dart
              spaces: _spaces,
```

**Edit 18** — `lib/ui/shell/app_shell.dart`: replace

```dart
                onReorderFavourites: (ids) => setState(
                  () => _favourites
                    ..clear()
                    ..addAll(ids),
                ),
```

with

```dart
                onReorderFavourites: _rooms.reorderFavourites,
```

- [ ] **Step 2: Run the shell's tests**

```bash
mise exec -- flutter test test/app_shell_test.dart test/home_test.dart test/add_space_test.dart test/new_dm_test.dart test/calls_ui_test.dart
```

Expected: all pass, unchanged.

- [ ] **Format what you touched, by path, then analyze and run everything**

```bash
mise exec -- dart format lib/ui/shell/app_shell.dart
```

```bash
mise exec -- flutter analyze
```

```bash
mise exec -- flutter test
```

Expected: `No issues found!` and `+505: All tests passed!`.

- [ ] **Checkpoint: commit (only if Chris has said to commit this run)**

```bash
git add lib/ui/shell/app_shell.dart
```

```bash
git commit -m "refactor(shell): read rooms from a Rooms, not fixtures" -m "The shell kept membership, mutes, reading, tags and invites itself, layered over fixtures. They move behind Rooms, so the real backend can answer them. The call and timeline mocks keep their own overlays until those are real." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `MatrixRooms`

The real `Rooms`: `client.rooms` mapped onto the models, rebuilt on every `onSync`, with invites answered through `room.join()` / `room.leave()`. Everything else it cannot do yet throws `UnsupportedError`, and its `abilities` say so (the shell will not call them after Task 5).

**SDK traps found in rehearsal (do not "fix" these away):**
- `client.handleSync` (and the SDK's own made-up syncs, such as a leave the server has forgotten) fire `onSync` but never `SyncStatus.finished`, so the snapshot rebuilds on `onSync`, which fires after rooms and account data are applied. `onSyncStatus` is only for progress: `SyncStatus.processing` carries `progress` = rooms handled / total.
- The SDK keeps only "important" state in memory for rooms that are only listed. `openClient` adds `m.room.topic`, `m.room.join_rules` and `m.room.power_levels` to `importantStateEvents`. Members are not in memory either: `loadMembers` runs `requestParticipants([join], true, true)` (`cache: true` keeps them in the SDK's memory), once per room.
- `whenComplete(() => _answering.remove(id))` returns the removed future — the very one being completed — and `whenComplete` waits on it forever. The block body is deliberate.
- `room.join()` on a DM invite writes `m.direct` first (`addToDirectChat`); that is the SDK's, and fine.
- `package:matrix` exports its own `Presence` and `Role`; hide them where loaf's are meant.
- The fake server's invite (`!696r7674`) is addressed to `@bob`, not the test user, so tests inject their own invite.

**Files:**
- Create: `lib/matrix/matrix_rooms.dart`
- Modify: `lib/matrix/client_factory.dart`
- Test: `test/matrix/matrix_rooms_test.dart`

**Interfaces:**
- Consumes: `Rooms`, `RoomAbility` (Task 2); `openClient` from `lib/matrix/client_factory.dart`; `spaceColorFor` from `lib/ui/spaces/add_space.dart`.
- Produces: `class MatrixRooms extends ChangeNotifier implements Rooms` with `MatrixRooms(Client client)`; `abilities == {RoomAbility.answerInvites}`. `accept`/`decline` throw the SDK's `MatrixException` when refused, leaving the invite in place.

- [ ] **Step 1: Write the failing test** — `test/matrix/matrix_rooms_test.dart`:

```dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:loaf_native/matrix/matrix_rooms.dart';
import 'package:loaf_native/ui/members/presence.dart' as loaf;
import 'package:loaf_native/ui/model/models.dart';
import 'package:loaf_native/ui/rooms/rooms.dart';
// The SDK has a Role of its own; the one under test is loaf's.
import 'package:matrix/matrix.dart' hide Role;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _me = '@test:fakeServer.notExisting';

/// The fake server, plus answers it lacks: joining and leaving a room.
/// [hold] keeps those answers back until completed; [refuse] makes them
/// a 403.
class _Api extends FakeMatrixApi {
  final answered = <String>[];
  Completer<void>? hold;
  var refuse = false;

  @override
  FutureOr<http.Response> mockIntercept(http.Request request) async {
    final path = request.url.path;
    if (request.method == 'POST' &&
        (path.endsWith('/join') || path.endsWith('/leave'))) {
      answered.add(path);
      await hold?.future;
      return refuse
          ? http.Response(
              jsonEncode({'errcode': 'M_FORBIDDEN', 'error': 'not allowed'}),
              403,
            )
          : http.Response(jsonEncode({'room_id': '!invited:example.com'}), 200);
    }
    return super.mockIntercept(request);
  }
}

/// A client signed in to the fake server. Its first sync, handled unless
/// [firstSync] is false, has two joined rooms (one a DM) and push rules.
Future<Client> _client({_Api? api, bool firstSync = true}) async {
  final client = await openClient(
    httpClient: api ?? FakeMatrixApi(),
    databasePath: inMemoryDatabasePath,
  );
  FakeMatrixApi.client = client;
  await client.init(
    newToken: 'abcd',
    newHomeserver: Uri.parse('https://fakeServer.notExisting'),
    newUserID: _me,
    newDeviceID: 'GHTYAJCE',
    newDeviceName: 'loaf on test',
    waitForFirstSync: firstSync,
  );
  addTearDown(client.dispose);
  return client;
}

Future<MatrixRooms> _rooms(Client client) async {
  final rooms = MatrixRooms(client);
  addTearDown(rooms.dispose);
  await _settle();
  return rooms;
}

/// Lets the SDK's streams deliver.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

var _events = 0;

Map<String, Object?> _state(
  String type,
  Map<String, Object?> content, {
  String key = '',
  String sender = _me,
}) => {
  'type': type,
  'state_key': key,
  'sender': sender,
  'content': content,
  'event_id': '\$e${_events++}',
  'origin_server_ts': 1700000000000,
};

Map<String, Object?> _child(String id) => _state('m.space.child', {
  'via': ['example.com'],
}, key: id);

Map<String, Object?> _room(
  String name, {
  String? type,
  List<Map<String, Object?>> extra = const [],
  List<Map<String, Object?>> accountData = const [],
  int notifications = 0,
  int highlights = 0,
}) => {
  'state': {
    'events': [
      _state('m.room.create', {'creator': _me, 'type': ?type}),
      _state('m.room.name', {'name': name}),
      _state('m.room.member', {'membership': 'join'}, key: _me),
      ...extra,
    ],
  },
  'account_data': {'events': accountData},
  'unread_notifications': {
    'notification_count': notifications,
    'highlight_count': highlights,
  },
};

Future<void> _sync(Client client, Map<String, Object?> rooms) =>
    client.handleSync(
      SyncUpdate.fromJson({'next_batch': 'b${_events++}', 'rooms': rooms}),
    );

/// A space "Bakery" with a channel and a voice channel directly under it, a
/// category subspace holding a private channel and a nested subspace, and a
/// child you have not joined. "Annex" is a second space.
Future<void> _bakery(Client client) => _sync(client, {
  'join': {
    '!bakery:example.com': _room(
      'Bakery',
      type: 'm.space',
      extra: [
        _child('!general:example.com'),
        _child('!oven:example.com'),
        _child('!recipes:example.com'),
        _child('!unjoined:example.com'),
        _state('m.room.power_levels', {
          'users': {_me: 100, '@mod:example.com': 50},
        }),
        _state(
          'm.room.member',
          {'membership': 'join', 'displayname': 'Moddy'},
          key: '@mod:example.com',
          sender: '@mod:example.com',
        ),
      ],
    ),
    '!annex:example.com': _room('annex', type: 'm.space'),
    '!general:example.com': _room('general', notifications: 3),
    '!oven:example.com': _room('oven', type: 'm.call'),
    '!recipes:example.com': _room(
      'recipes',
      type: 'm.space',
      extra: [_child('!sourdough:example.com'), _child('!deeper:example.com')],
    ),
    '!sourdough:example.com': _room(
      'sourdough',
      highlights: 1,
      notifications: 4,
      extra: [
        _state('m.room.join_rules', {'join_rule': 'invite'}),
        _state('m.room.topic', {'topic': 'wild yeast'}),
      ],
    ),
    '!deeper:example.com': _room(
      'deeper',
      type: 'm.space',
      extra: [_child('!crumb:example.com')],
    ),
    '!crumb:example.com': _room('crumb'),
  },
});

/// Someone inviting you to a room, the way a server sends it: stripped
/// state with your membership and the inviter's profile.
Future<void> _invited(Client client, {bool direct = false}) => _sync(client, {
  'invite': {
    '!invited:example.com': {
      'invite_state': {
        'events': [
          _state('m.room.name', {'name': 'Proofing'}, sender: '@al:x.y'),
          _state('m.room.topic', {'topic': 'rise'}, sender: '@al:x.y'),
          _state(
            'm.room.member',
            {'membership': 'join', 'displayname': 'Al'},
            key: '@al:x.y',
            sender: '@al:x.y',
          ),
          _state(
            'm.room.member',
            {'membership': 'invite', 'is_direct': direct},
            key: _me,
            sender: '@al:x.y',
          ),
        ],
      },
    },
  },
});

void main() {
  test('rooms in no space land in Home, a DM as a DM', () async {
    final rooms = await _rooms(await _client());
    expect(rooms.synced, isTrue);
    expect(rooms.spaces, isEmpty);
    final byId = {for (final c in rooms.homeRooms) c.id: c};
    // The fake's m.direct lists this one.
    final dm = byId['!726s6s6q:example.com']!;
    expect(dm.kind, ChannelKind.direct);
    expect(dm.unread, 2);
    expect(dm.mentions, 2);
    expect(dm.members, isNotEmpty);
    expect(dm.members.map((m) => m.id), isNot(contains(_me)));
    expect(byId['!calls:example.com']!.kind, ChannelKind.room);
  });

  test('joined spaces make the rail, in name order', () async {
    final client = await _client();
    final rooms = await _rooms(client);
    await _bakery(client);
    await _settle();
    // Subspaces are categories, never rail items.
    expect(rooms.spaces.map((s) => s.name), ['annex', 'Bakery']);
  });

  test('a space\'s children become its categories and channels', () async {
    final client = await _client();
    final rooms = await _rooms(client);
    await _bakery(client);
    await _settle();

    final bakery = rooms.spaces.last;
    // Direct children first, uncategorised; then one category per subspace,
    // its nested subspace flattened in. The unjoined child is not listed.
    expect(bakery.categories.map((c) => c.name), ['', 'recipes']);
    expect(bakery.categories.first.channels.map((c) => c.name), [
      'general',
      'oven',
    ]);
    expect(bakery.categories.last.channels.map((c) => c.name), [
      'sourdough',
      'crumb',
    ]);
    expect(bakery.categories.first.channels.last.kind, ChannelKind.voice);
    expect(bakery.categories.first.channels.first.kind, ChannelKind.text);
  });

  test('a channel carries its counts, topic and lock', () async {
    final client = await _client();
    final rooms = await _rooms(client);
    await _bakery(client);
    await _settle();

    final sourdough = rooms.spaces.last.categories.last.channels.first;
    expect(sourdough.private, isTrue);
    expect(sourdough.topic, 'wild yeast');
    expect(sourdough.unread, 4);
    expect(sourdough.mentions, 1);
    expect(sourdough.muted, isFalse);
    expect(rooms.spaces.last.mentions, 1);
  });

  test('a space\'s rooms never also appear in Home', () async {
    final client = await _client();
    final rooms = await _rooms(client);
    await _bakery(client);
    await _settle();
    final home = rooms.homeRooms.map((c) => c.id).toSet();
    for (final id in [
      '!general:example.com',
      '!crumb:example.com',
      '!recipes:example.com',
      '!bakery:example.com',
    ]) {
      expect(home, isNot(contains(id)), reason: id);
    }
  });

  test('members carry their power level, and no presence yet', () async {
    final client = await _client();
    final rooms = await _rooms(client);
    await _bakery(client);
    await _settle();
    // Only a room list's state is in memory until a member list is wanted.
    rooms.loadMembers('!bakery:example.com');
    await _settle();
    final members = {for (final m in rooms.spaces.last.members) m.id: m};
    expect(members[_me]!.role, Role.admin);
    expect(members['@mod:example.com']!.role, Role.moderator);
    expect(members['@mod:example.com']!.name, 'Moddy');
    expect(members['@mod:example.com']!.presence, loaf.Presence.unknown);
  });

  test('a member list is asked for once, however often it is wanted', () async {
    final client = await _client();
    final rooms = await _rooms(client);
    await _bakery(client);
    await _settle();
    for (var i = 0; i < 3; i++) {
      rooms.loadMembers('!bakery:example.com');
      await _settle();
    }
    expect(
      FakeMatrixApi.calledEndpoints.keys.where((k) => k.contains('/members')),
      hasLength(1),
    );
    expect(
      FakeMatrixApi.calledEndpoints.entries
          .where((e) => e.key.contains('/members'))
          .single
          .value,
      hasLength(1),
    );
  });

  test('tags and a mentions-only push rule reach Home rooms', () async {
    final client = await _client();
    final rooms = await _rooms(client);
    await _sync(client, {
      'join': {
        '!fav:example.com': _room(
          'fav',
          accountData: [
            {
              'type': 'm.tag',
              'content': {
                'tags': {
                  'm.favourite': {'order': 0.25},
                },
              },
            },
          ],
        ),
        '!low:example.com': _room(
          'low',
          accountData: [
            {
              'type': 'm.tag',
              'content': {
                'tags': {'m.lowpriority': <String, Object?>{}},
              },
            },
          ],
        ),
      },
    });
    await client.handleSync(
      SyncUpdate.fromJson({
        'next_batch': 'rules',
        'account_data': {
          'events': [
            {
              'type': 'm.push_rules',
              'content': {
                'global': {
                  'room': [
                    {
                      'rule_id': '!low:example.com',
                      'actions': <Object>[],
                      'default': false,
                      'enabled': true,
                    },
                  ],
                },
              },
            },
          ],
        },
      }),
    );
    await _settle();
    final byId = {for (final c in rooms.homeRooms) c.id: c};
    expect(byId['!fav:example.com']!.favourite, isTrue);
    expect(byId['!fav:example.com']!.favouriteOrder, 0.25);
    expect(byId['!low:example.com']!.lowPriority, isTrue);
    expect(byId['!low:example.com']!.muted, isTrue);
    expect(byId['!fav:example.com']!.muted, isFalse);
  });

  test('two DMs with one person name the same person, so they fold', () async {
    final client = await _client();
    final rooms = await _rooms(client);
    Map<String, Object?> dm(String name, List<String> heroes) => {
      ..._room(name),
      'summary': {'m.heroes': heroes, 'm.joined_member_count': 2},
    };
    await client.handleSync(
      SyncUpdate.fromJson({
        'next_batch': 'dms',
        'account_data': {
          'events': [
            {
              'type': 'm.direct',
              'content': {
                '@sam:x.y': ['!sam1:x.y', '!sam2:x.y'],
                '@jun:x.y': ['!group:x.y'],
              },
            },
          ],
        },
        'rooms': {
          'join': {
            '!sam1:x.y': dm('Sam', ['@sam:x.y']),
            // No heroes: m.direct still says who it is with.
            '!sam2:x.y': dm('Sam', []),
            '!group:x.y': dm('crew', ['@jun:x.y', '@ada:x.y']),
          },
        },
      }),
    );
    await _settle();
    final byId = {for (final c in rooms.homeRooms) c.id: c};
    expect(byId['!sam1:x.y']!.members.single.id, '@sam:x.y');
    expect(byId['!sam2:x.y']!.members.single.id, '@sam:x.y');
    expect(byId['!group:x.y']!.members.map((m) => m.id), [
      '@jun:x.y',
      '@ada:x.y',
    ]);
    expect(byId['!group:x.y']!.kind, ChannelKind.direct);
  });

  test('an invite says who sent it and what it is', () async {
    final client = await _client();
    final rooms = await _rooms(client);
    await _invited(client);
    await _settle();
    final invite = rooms.invites.firstWhere(
      (i) => i.id == '!invited:example.com',
    );
    expect(invite.kind, InviteKind.room);
    expect(invite.name, 'Proofing');
    expect(invite.topic, 'rise');
    expect(invite.inviter.id, '@al:x.y');
    expect(invite.inviter.name, 'Al');
    expect(invite.room!.id, '!invited:example.com');
  });

  test('a DM invite is a DM invite', () async {
    final client = await _client();
    final rooms = await _rooms(client);
    await _invited(client, direct: true);
    await _settle();
    final invite = rooms.invites.firstWhere(
      (i) => i.id == '!invited:example.com',
    );
    expect(invite.kind, InviteKind.direct);
    expect(invite.room!.kind, ChannelKind.direct);
  });

  test('before the first sync: waiting, then progress, then synced', () async {
    final client = await _client(firstSync: false);
    final rooms = MatrixRooms(client);
    addTearDown(rooms.dispose);
    expect(rooms.synced, isFalse);
    expect(rooms.syncProgress, isNull);
    final seen = <(bool, double?)>[];
    rooms.addListener(() => seen.add((rooms.synced, rooms.syncProgress)));
    await client.onSync.stream.first;
    await _settle();
    expect(rooms.synced, isTrue);
    expect(rooms.syncProgress, isNull);
    expect(
      seen.where((s) => s.$2 != null).map((s) => s.$1),
      everyElement(false),
    );
    expect(seen.map((s) => s.$2), contains(1.0));
  });

  test('accepting an invite asks the server once, however many taps', () async {
    final api = _Api()..hold = Completer();
    final client = await _client(api: api);
    final rooms = await _rooms(client);
    await _invited(client);
    await _settle();
    final invite = rooms.invites.firstWhere(
      (i) => i.id == '!invited:example.com',
    );
    final first = rooms.accept(invite);
    final second = rooms.accept(invite);
    api.hold!.complete();
    await Future.wait([first, second]);
    expect(api.answered.where((p) => p.endsWith('/join')), hasLength(1));
  });

  test('declining an invite leaves it', () async {
    final api = _Api();
    final client = await _client(api: api);
    final rooms = await _rooms(client);
    await _invited(client);
    await _settle();
    await rooms.decline(
      rooms.invites.firstWhere((i) => i.id == '!invited:example.com'),
    );
    expect(api.answered.single, endsWith('/leave'));
  });

  test('a refused accept throws, and the invite stays', () async {
    final api = _Api()..refuse = true;
    final client = await _client(api: api);
    final rooms = await _rooms(client);
    await _invited(client);
    await _settle();
    final invite = rooms.invites.firstWhere(
      (i) => i.id == '!invited:example.com',
    );
    await expectLater(rooms.accept(invite), throwsA(isA<MatrixException>()));
    await _settle();
    expect(rooms.invites.map((i) => i.id), contains('!invited:example.com'));
    // And it can be tried again.
    api.refuse = false;
    await rooms.accept(invite);
    expect(api.answered.where((p) => p.endsWith('/join')), hasLength(2));
  });

  test('you are you, and only answering invites is wired', () async {
    final rooms = await _rooms(await _client());
    expect(rooms.me.id, _me);
    expect(rooms.me.name, isNotEmpty);
    expect(rooms.abilities, {RoomAbility.answerInvites});
    expect(() => rooms.markRead('!calls:example.com'), throwsUnsupportedError);
  });
}
```

- [ ] **Step 2: Run it to see it fail**

```bash
mise exec -- flutter test test/matrix/matrix_rooms_test.dart
```

Expected: FAIL — `matrix_rooms.dart` does not exist.

- [ ] **Step 3: Keep the list's state in memory** — `lib/matrix/client_factory.dart`: replace

```dart
  return Client('loaf', database: database, httpClient: httpClient);
```

with

```dart
  return Client(
    'loaf',
    database: database,
    httpClient: httpClient,
    // The SDK keeps only a room list's state in memory for rooms not open.
    // These are what the channel list and member list read on top of that:
    // a channel's topic and lock, and who is an admin or moderator.
    importantStateEvents: {
      EventTypes.RoomTopic,
      EventTypes.RoomJoinRules,
      EventTypes.RoomPowerLevels,
    },
  );
```

- [ ] **Step 4: Create `lib/matrix/matrix_rooms.dart`**

```dart
/// The account's rooms read from the SDK: [Rooms] over the app's one
/// [Client]. Nothing is kept but one snapshot derived from the client's own
/// rooms, rebuilt after every sync — the SDK is the store.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
// The SDK has a Presence of its own; loaf's is the one the UI draws.
import 'package:matrix/matrix.dart' hide Presence;

import '../ui/members/presence.dart';
import '../ui/model/models.dart';
import '../ui/rooms/rooms.dart';
import '../ui/spaces/add_space.dart' show spaceColorFor;

/// `m.room.create` types that make a room a voice channel: Element's video
/// rooms, stable and unstable.
const _voiceTypes = {'m.call', 'org.matrix.msc3417.call'};

class MatrixRooms extends ChangeNotifier implements Rooms {
  MatrixRooms(this.client) {
    _subscriptions = [
      // After the rooms and account data of a sync are applied, including
      // syncs the SDK makes up itself (a leave the server has forgotten).
      // `SyncStatus.finished` would miss those.
      client.onSync.stream.listen((_) {
        _synced = true;
        _progress = null;
        _rebuild();
      }),
      client.onSyncStatus.stream.listen(_onStatus),
    ];
    // A restored session has synced before; its rooms are already here.
    _synced = client.prevBatch != null;
    _rebuild();
    unawaited(_loadMe());
  }

  final Client client;

  late final List<StreamSubscription<Object?>> _subscriptions;
  var _disposed = false;

  var _synced = false;
  double? _progress;
  var _spaces = <Space>[];
  var _home = <Channel>[];
  var _invites = <Invite>[];
  String? _myName;

  /// Invites being answered, so a second tap or a stale preview sends
  /// nothing more.
  final _answering = <String, Future<void>>{};

  /// Rooms whose member lists have been asked for. Once each: the shell
  /// asks on every build, and later changes to a loaded list arrive over
  /// sync.
  final _membersAsked = <String>{};

  @override
  Set<RoomAbility> get abilities => const {RoomAbility.answerInvites};

  @override
  bool get synced => _synced;

  @override
  double? get syncProgress => _progress;

  @override
  Member get me {
    final id = client.userID ?? '';
    return Member(
      id,
      _myName ?? id.localpart ?? id,
      spaceColorFor(id),
      presence: Presence.unknown,
    );
  }

  @override
  List<Space> get spaces => _spaces;

  @override
  List<Channel> get homeRooms => _home;

  @override
  List<Invite> get invites => _invites;

  void _onStatus(SyncStatusUpdate update) {
    if (_synced) return;
    final progress = update.status == SyncStatus.processing
        ? update.progress
        : null;
    if (progress == _progress) return;
    _progress = progress;
    _notify();
  }

  Future<void> _loadMe() async {
    try {
      final profile = await client.fetchOwnProfile();
      _myName = profile.displayName;
      _notify();
    } on Object {
      // Offline, or no profile: the localpart stands in.
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // ── Mapping ────────────────────────────────────────────────────────────

  void _rebuild() {
    final joined = {
      for (final room in client.rooms)
        if (room.membership == Membership.join) room.id: room,
    };
    final spaces = [
      for (final room in joined.values)
        if (room.isSpace) room,
    ];
    // Every room some joined space lists, at any depth. Those are a
    // space's; Home has what is left.
    final childIds = {
      for (final space in spaces)
        for (final child in space.spaceChildren) ?child.roomId,
    };

    _spaces = [
      for (final space in spaces)
        if (!childIds.contains(space.id)) _space(space, joined),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    _home = [
      for (final room in joined.values)
        if (!room.isSpace && (room.isDirectChat || !childIds.contains(room.id)))
          _channel(room, home: true),
    ];

    _invites = [
      for (final room in client.rooms)
        if (room.membership == Membership.invite) _invite(room),
    ];
    _notify();
  }

  Space _space(Room space, Map<String, Room> joined) {
    final name = space.getLocalizedDisplayname();
    final top = <Channel>[];
    final categories = <ChannelCategory>[];
    for (final child in space.spaceChildren) {
      final room = joined[child.roomId];
      if (room == null) continue; // Not joined: phase 5 lists these.
      if (room.isSpace) {
        final channels = [
          for (final r in _descendants(room, joined, {space.id})) _channel(r),
        ];
        categories.add(
          ChannelCategory(room.getLocalizedDisplayname(), channels),
        );
      } else {
        top.add(_channel(room));
      }
    }
    return Space(
      id: space.id,
      name: name,
      color: spaceColorFor(name),
      categories: [if (top.isNotEmpty) ChannelCategory('', top), ...categories],
      members: _members(space),
    );
  }

  /// A category's rooms: its joined non-space children, then those of any
  /// subspaces under it, flattened in. [seen] stops a space that lists an
  /// ancestor from looping.
  Iterable<Room> _descendants(
    Room space,
    Map<String, Room> joined,
    Set<String> seen,
  ) sync* {
    if (!seen.add(space.id)) return;
    for (final child in space.spaceChildren) {
      final room = joined[child.roomId];
      if (room == null) continue;
      if (room.isSpace) {
        yield* _descendants(room, joined, seen);
      } else {
        yield room;
      }
    }
  }

  Channel _channel(Room room, {bool home = false}) {
    final type = room
        .getState(EventTypes.RoomCreate)
        ?.content
        .tryGet<String>('type');
    final kind = _voiceTypes.contains(type)
        ? ChannelKind.voice
        : !home
        ? ChannelKind.text
        : room.isDirectChat
        ? ChannelKind.direct
        : ChannelKind.room;
    final topic = room.topic;
    final favourite = room.tags[TagType.favourite];
    return Channel(
      id: room.id,
      name: room.getLocalizedDisplayname(),
      kind: kind,
      unread: room.notificationCount,
      mentions: room.highlightCount,
      private: const {
        JoinRules.invite,
        JoinRules.knock,
      }.contains(room.joinRules),
      topic: topic.isEmpty ? null : topic,
      muted: room.pushRuleState != PushRuleState.notify,
      members: switch (kind) {
        ChannelKind.direct => _others(room),
        ChannelKind.room => _members(room),
        _ => const [],
      },
      favourite: favourite != null,
      favouriteOrder: favourite?.order,
      lowPriority: room.isLowPriority,
      lastActivity: room.latestEventReceivedTime,
    );
  }

  /// Whoever the room has in memory; [loadMembers] fills in the rest.
  List<Member> _members(Room room) => [
    for (final user in room.getParticipants([Membership.join]))
      _member(room, user.id),
  ];

  /// Everyone in a DM but you. The server names them in the room summary
  /// (`m.heroes`) without loading the member list; failing that, `m.direct`
  /// says who a 1:1 is with. That one person is what folds duplicate DMs
  /// into one row, so it must not depend on members having loaded.
  List<Member> _others(Room room) {
    final heroes = room.summary.mHeroes ?? const <String>[];
    final ids = heroes.isNotEmpty ? heroes : [?room.directChatMatrixID];
    return [
      for (final id in ids)
        if (id != client.userID) _member(room, id),
    ];
  }

  Member _member(Room room, String userId) => Member(
    userId,
    room.unsafeGetUserFromMemoryOrFallback(userId).calcDisplayname(),
    spaceColorFor(userId),
    presence: Presence.unknown,
    powerLevel: room.getPowerLevelByUserId(userId).level,
  );

  Invite _invite(Room room) {
    final myId = client.userID ?? '';
    final inviterId = room.getState(EventTypes.RoomMember, myId)?.senderId;
    final inviter = inviterId == null
        ? null
        : room.unsafeGetUserFromMemoryOrFallback(inviterId);
    final name = room.getLocalizedDisplayname();
    final kind = room.isSpace
        ? InviteKind.space
        : room.isDirectChat
        ? InviteKind.direct
        : InviteKind.room;
    final topic = room.topic;
    final count = room.summary.mJoinedMemberCount;
    return Invite(
      id: room.id,
      kind: kind,
      name: name,
      inviter: Member(
        inviterId ?? '',
        inviter?.calcDisplayname() ?? inviterId?.localpart ?? 'someone',
        spaceColorFor(inviterId ?? ''),
        presence: Presence.unknown,
      ),
      color: spaceColorFor(name),
      topic: topic.isEmpty ? null : topic,
      memberCount: count == null || count == 0 ? null : count,
      // What the shell opens once accepted. The room itself arrives with
      // the next sync; until then the shell's fallback holds its place.
      room: kind == InviteKind.space
          ? null
          : Channel(
              id: room.id,
              name: name,
              kind: kind == InviteKind.direct
                  ? ChannelKind.direct
                  : ChannelKind.room,
            ),
      space: kind == InviteKind.space
          ? Space(id: room.id, name: name, color: spaceColorFor(name))
          : null,
    );
  }

  // ── Invites ────────────────────────────────────────────────────────────

  @override
  Future<void> accept(Invite invite) => _answer(invite, (room) => room.join());

  @override
  Future<void> decline(Invite invite) =>
      _answer(invite, (room) => room.leave());

  Future<void> _answer(Invite invite, Future<void> Function(Room) call) {
    // A second tap, or a stale preview, gets the answer already on its way
    // rather than sending another.
    final pending = _answering[invite.id];
    if (pending != null) return pending;
    final room = client.getRoomById(invite.id);
    // Answered already, here or on another device.
    if (room == null || room.membership != Membership.invite) {
      return Future.value();
    }
    // A block body: `remove` returns this very future, and `whenComplete`
    // would wait on it, which never finishes.
    final answer = call(room).whenComplete(() {
      _answering.remove(invite.id);
    });
    _answering[invite.id] = answer;
    return answer;
  }

  // ── Not wired yet ──────────────────────────────────────────────────────

  @override
  void loadMembers(String roomId) {
    final room = client.getRoomById(roomId);
    if (room == null || room.participantListComplete) return;
    if (!_membersAsked.add(roomId)) return;
    // A read into the SDK's own store: members it has on disk first, then
    // the server's list, kept in memory (`cache`) so the next snapshot has
    // them. A late or failed answer only leaves the list as it was, until
    // the app next opens.
    unawaited(
      room
          .requestParticipants([Membership.join], true, true)
          .then<void>((_) {}, onError: (Object _) {})
          .whenComplete(() {
            if (!_disposed) _rebuild();
          }),
    );
  }

  Never _unwired(String what) =>
      throw UnsupportedError('$what is not wired to the SDK yet');

  @override
  void markRead(String roomId) => _unwired('marking read');
  @override
  void setMuted(String roomId, bool muted) => _unwired('muting');
  @override
  void setJoined(String roomId, bool joined) => _unwired('joining');
  @override
  void setFavourite(String roomId, bool favourite) => _unwired('tagging');
  @override
  void reorderFavourites(List<String> roomIds) => _unwired('tagging');
  @override
  void setLowPriority(String roomId, bool lowPriority) => _unwired('tagging');
  @override
  void joinSpace(Space space) => _unwired('joining a space');
  @override
  String createSpace(String name, {required Member me}) =>
      _unwired('creating a space');
  @override
  Channel createDirect(List<Member> members) => _unwired('starting a DM');

  @override
  void dispose() {
    _disposed = true;
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    super.dispose();
  }
}
```

- [ ] **Step 5: Run the test to see it pass**

```bash
mise exec -- flutter test test/matrix/matrix_rooms_test.dart
```

Expected: `+16: All tests passed!` The `[Matrix]` log lines (invalid devices, encryption) are the fake server's and expected.

- [ ] **Format what you touched, by path, then analyze and run everything**

```bash
mise exec -- dart format lib/matrix/matrix_rooms.dart lib/matrix/client_factory.dart test/matrix/matrix_rooms_test.dart
```

```bash
mise exec -- flutter analyze
```

```bash
mise exec -- flutter test
```

Expected: `No issues found!` and `+521: All tests passed!`.

- [ ] **Checkpoint: commit (only if Chris has said to commit this run)**

```bash
git add lib/matrix/matrix_rooms.dart lib/matrix/client_factory.dart test/matrix/matrix_rooms_test.dart
```

```bash
git commit -m "feat(matrix): rooms mapped from sync" -m "Spaces, categories, Home, unreads, tags, mutes, members and invites, read from the client after every sync. The SDK stays the store: one derived snapshot. Invites can be answered, once, however many taps." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Only what is wired is drawn

The shell asks `_rooms.abilities` before drawing each control. On a backend that can only answer invites: no row menus (a row with no actions opens none), no add-space button, no new-message "+", no favourite dragging, no calls (the desktop's click-to-connect included), no status picker, no profile editing, and every room shows its real header over "messages aren't wired up yet" with no composer. The desktop update notice shows only with the mock session (nothing stands behind it yet). While here, two dead controls become honest: settings' sign-out signs out, and the copy button beside a read-only row copies. Mock behaviour is unchanged: `null` still means "everything" wherever a widget takes an allow-list, and the rail gets an explicit `addSpace` flag because an existing test pumps it without `onAddSpace` and expects the button.

**Files:**
- Modify: `lib/ui/shell/channel_actions.dart`, `lib/ui/shell/channel_list.dart`, `lib/ui/shell/spaces_rail.dart`, `lib/ui/shell/user_bar.dart`, `lib/ui/channel/channel_view.dart`, `lib/ui/settings/settings_page.dart`, `lib/ui/settings/account_section.dart`, `lib/ui/shell/app_shell.dart`
- Test: `test/app_shell_rooms_test.dart`

**Interfaces:**
- Consumes: `Rooms`, `RoomAbility` (Task 2); `AppShell(rooms:)` (Task 3).
- Produces:
  - `actionsFor(Channel, {bool home, Set<ChannelAction>? allowed})` and `showChannelActions(…, {Set<ChannelAction>? allowed})`; `ChannelList(allowedActions: Set<ChannelAction>?)`.
  - `SpacesRail(addSpace: bool = true)`.
  - `ChannelView(timeline: TimelineController?)` — null shows "messages aren't wired up yet" and no composer.
  - `showSettings(context, {ProfileController? profile, Member? me, bool editable = true, VoidCallback? onSignOut})`; `AccountSection({ProfileController? profile, Member? me, bool editable = true})`.

- [ ] **Step 1: Write the failing test** — `test/app_shell_rooms_test.dart`. Its `_FakeRooms` is plain models with only `answerInvites`, the way the real backend is in this phase; its `_Session` counts sign-outs.

```dart
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:loaf_native/ui/auth/homeserver.dart';
import 'package:loaf_native/ui/auth/loaf_session.dart';
import 'package:loaf_native/ui/auth/sign_in_state.dart';
import 'package:loaf_native/ui/channel/composer.dart';
import 'package:loaf_native/ui/members/presence.dart';
import 'package:loaf_native/ui/mock/mock_homeserver.dart';
import 'package:loaf_native/ui/model/models.dart';
import 'package:loaf_native/ui/rooms/rooms.dart';
import 'package:loaf_native/ui/shell/app_shell.dart';
import 'package:loaf_native/ui/shell/channel_list.dart';
import 'package:loaf_native/ui/shell/spaces_rail.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

final _mobile = TargetPlatformVariant.only(TargetPlatform.iOS);
final _desktop = TargetPlatformVariant.only(TargetPlatform.macOS);

const _me = Member(
  '@chris:loaf.test',
  'Chris',
  Color(0xFF3B82F6),
  presence: Presence.unknown,
);
const _mod = Member(
  '@mod:loaf.test',
  'Moddy',
  Color(0xFF8B5CF6),
  presence: Presence.unknown,
  powerLevel: 50,
);

Space _bakery({List<Channel>? channels}) => Space(
  id: '!bakery',
  name: 'Bakery',
  color: const Color(0xFFD97B2A),
  members: const [_me, _mod],
  categories: [
    ChannelCategory(
      '',
      channels ??
          const [
            Channel(id: '!general', name: 'general', unread: 2),
            Channel(id: '!oven', name: 'oven', kind: ChannelKind.voice),
          ],
    ),
  ],
);

const _dm = Channel(
  id: '!dm',
  name: 'Moddy',
  kind: ChannelKind.direct,
  members: [_mod],
);

/// Rooms as a real backend has them in phase 2: plain models, and only
/// invites can be answered.
class _FakeRooms extends ChangeNotifier implements Rooms {
  _FakeRooms({this.spaces = const [], this.homeRooms = const []});

  @override
  Set<RoomAbility> abilities = {RoomAbility.answerInvites};
  @override
  bool synced = true;
  @override
  double? syncProgress;
  @override
  Member get me => _me;
  @override
  List<Space> spaces;
  @override
  List<Channel> homeRooms;
  @override
  List<Invite> invites = const [];

  final membersAsked = <String>[];

  /// What accepting and declining answer with; completed by the test.
  Completer<void>? answer;

  void update() => notifyListeners();

  @override
  void loadMembers(String roomId) => membersAsked.add(roomId);

  @override
  Future<void> accept(Invite invite) => answer!.future;
  @override
  Future<void> decline(Invite invite) => answer!.future;

  Never _unwired() => throw UnsupportedError('not wired');
  @override
  void markRead(String roomId) => _unwired();
  @override
  void setMuted(String roomId, bool muted) => _unwired();
  @override
  void setJoined(String roomId, bool joined) => _unwired();
  @override
  void setFavourite(String roomId, bool favourite) => _unwired();
  @override
  void reorderFavourites(List<String> roomIds) => _unwired();
  @override
  void setLowPriority(String roomId, bool lowPriority) => _unwired();
  @override
  void joinSpace(Space space) => _unwired();
  @override
  String createSpace(String name, {required Member me}) => _unwired();
  @override
  Channel createDirect(List<Member> members) => _unwired();
}

/// A session that is signed in and trusted, and counts sign-outs.
class _Session extends ChangeNotifier implements LoafSession {
  var signedOut = 0;

  @override
  AccountState get account => AccountState.signedIn;
  @override
  DeviceTrust get trust => DeviceTrust.verified;
  @override
  SoftLogout? get softLogout => null;
  @override
  IncomingRequest? get incoming => null;
  @override
  String get homeserverName => 'loaf.test';
  @override
  Homeserver newHomeserver() => MockHomeserver();
  @override
  void signedIn() {}
  @override
  void signOut() => signedOut++;
  @override
  void markVerified() {}
  @override
  void clearIncoming() {}
  @override
  bool consumeFailure() => false;
}

Future<_Session> _pump(
  WidgetTester tester,
  _FakeRooms rooms, {
  Size size = const Size(1440, 900),
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final session = _Session();
  addTearDown(session.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: loafLightTheme(),
      darkTheme: loafDarkTheme(),
      themeMode: ThemeMode.dark,
      home: AppShell(session: session, rooms: () => rooms),
    ),
  );
  // A spinner never settles.
  settle ? await tester.pumpAndSettle() : await tester.pump();
  return session;
}

Finder _inList(String text) =>
    find.descendant(of: find.byType(ChannelList), matching: find.text(text));

void main() {
  group('only what is wired is drawn', () {
    testWidgets('no add-space button, and no new-message button', (
      tester,
    ) async {
      await _pump(tester, _FakeRooms(spaces: [_bakery()], homeRooms: [_dm]));
      expect(find.byTooltip('Add a space'), findsNothing);
      await tester.tap(find.byKey(SpacesRail.homeKey));
      await tester.pumpAndSettle();
      expect(find.text('DIRECT MESSAGES'), findsOneWidget);
      expect(find.byTooltip('New message'), findsNothing);
    });

    testWidgets(
      'a right-click opens no menu with nothing in it',
      variant: _desktop,
      (tester) async {
        await _pump(tester, _FakeRooms(spaces: [_bakery()]));
        await tester.tap(_inList('general'), buttons: kSecondaryButton);
        await tester.pumpAndSettle();
        expect(find.text('Mark as read'), findsNothing);
        expect(find.text('Mute channel'), findsNothing);
        expect(find.text('Leave channel'), findsNothing);
      },
    );

    testWidgets(
      'a long press opens no menu with nothing in it',
      variant: _mobile,
      (tester) async {
        await _pump(
          tester,
          _FakeRooms(spaces: [_bakery()]),
          size: const Size(390, 844),
        );
        await tester.tap(find.byIcon(LucideIcons.menu));
        await tester.pumpAndSettle();
        await tester.longPress(_inList('general'));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsNothing);
      },
    );

    testWidgets('a room says messages are not wired, with no composer', (
      tester,
    ) async {
      await _pump(tester, _FakeRooms(spaces: [_bakery()]));
      expect(find.text("messages aren't wired up yet"), findsOneWidget);
      expect(find.byType(Composer), findsNothing);
    });

    testWidgets('a voice channel never connects', variant: _desktop, (
      tester,
    ) async {
      await _pump(tester, _FakeRooms(spaces: [_bakery()]));
      await tester.tap(_inList('oven'));
      await tester.pumpAndSettle();
      expect(find.text('Voice connected'), findsNothing);
      expect(find.text('join voice'), findsNothing);
      expect(find.text("messages aren't wired up yet"), findsOneWidget);
    });

    testWidgets('a DM offers no calls', (tester) async {
      await _pump(tester, _FakeRooms(homeRooms: [_dm]));
      expect(find.text("messages aren't wired up yet"), findsOneWidget);
      expect(find.byTooltip('Start a voice call'), findsNothing);
      expect(find.byTooltip('Start a video call'), findsNothing);
    });

    testWidgets('settings show who you are, with nothing to edit', (
      tester,
    ) async {
      final session = await _pump(tester, _FakeRooms(spaces: [_bakery()]));
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('@chris:loaf.test'), findsWidgets);
      expect(find.text('save changes'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('sign out'));
      await tester.pump();
      expect(session.signedOut, 1);
    });

    testWidgets('your avatar opens no status picker', variant: _desktop, (
      tester,
    ) async {
      await _pump(tester, _FakeRooms(spaces: [_bakery()]));
      expect(find.text('Chris'), findsWidgets);
      await tester.tap(find.text('Chris').last);
      await tester.pumpAndSettle();
      expect(find.text('what are you up to?'), findsNothing);
    });

    testWidgets(
      'no update notice: nothing stands behind it yet',
      variant: _desktop,
      (tester) async {
        await _pump(tester, _FakeRooms(spaces: [_bakery()]));
        expect(find.textContaining('0.3.0'), findsNothing);
      },
    );
  });
}
```

- [ ] **Step 2: Run it to see it fail**

```bash
mise exec -- flutter test test/app_shell_rooms_test.dart
```

Expected: FAIL — among others, "Add a space" is found, a composer is drawn, and the right-click menu opens.

- [ ] **Step 3: Row actions, the rail, the user bar and the conversation**

**Edit 1** — `lib/ui/shell/channel_actions.dart`: replace

```dart
/// [home] rows can also be tagged favourite or low priority. Space channels
/// never are from loaf: each room has one place in the UI, and a favourited
/// space channel would need a second.
List<ChannelAction> actionsFor(Channel channel, {bool home = false}) => [
  if (channel.unread > 0 || channel.mentions > 0) ChannelAction.markRead,
  if (home) ...[
    channel.favourite ? ChannelAction.unfavourite : ChannelAction.favourite,
    channel.lowPriority
        ? ChannelAction.notLowPriority
        : ChannelAction.lowPriority,
    if (channel.earlier.isNotEmpty) ChannelAction.olderConversations,
  ],
  channel.muted ? ChannelAction.unmute : ChannelAction.mute,
  ChannelAction.leave,
];
```

with

```dart
/// [home] rows can also be tagged favourite or low priority. Space channels
/// never are from loaf: each room has one place in the UI, and a favourited
/// space channel would need a second.
///
/// Only actions in [allowed] are offered, when it is given: the backend may
/// not do them all yet, and one that only pretends would lie.
List<ChannelAction> actionsFor(
  Channel channel, {
  bool home = false,
  Set<ChannelAction>? allowed,
}) => [
  for (final action in [
    if (channel.unread > 0 || channel.mentions > 0) ChannelAction.markRead,
    if (home) ...[
      channel.favourite ? ChannelAction.unfavourite : ChannelAction.favourite,
      channel.lowPriority
          ? ChannelAction.notLowPriority
          : ChannelAction.lowPriority,
      if (channel.earlier.isNotEmpty) ChannelAction.olderConversations,
    ],
    channel.muted ? ChannelAction.unmute : ChannelAction.mute,
    ChannelAction.leave,
  ])
    if (allowed == null || allowed.contains(action)) action,
];
```

**Edit 2** — `lib/ui/shell/channel_actions.dart`: replace

```dart
Future<ChannelAction?> showChannelActions(
  BuildContext context,
  Channel channel, {
  Offset? position,
  bool home = false,
}) async {
  final items = [
    for (final action in actionsFor(channel, home: home))
      _item(action, _noun(channel)),
  ];
```

with

```dart
Future<ChannelAction?> showChannelActions(
  BuildContext context,
  Channel channel, {
  Offset? position,
  bool home = false,
  Set<ChannelAction>? allowed,
}) async {
  final items = [
    for (final action in actionsFor(channel, home: home, allowed: allowed))
      _item(action, _noun(channel)),
  ];
```

**Edit 3** — `lib/ui/shell/channel_list.dart`: replace

```dart
    this.onReorderFavourites,
    this.onNewMessage,
```

with

```dart
    this.onReorderFavourites,
    this.onNewMessage,
    this.allowedActions,
```

**Edit 4** — `lib/ui/shell/channel_list.dart`: replace

```dart
  /// phone, right-click on a computer). Left null, channels have no menu.
  final void Function(String channelId, ChannelAction action)? onAction;
```

with

```dart
  /// phone, right-click on a computer). Left null, channels have no menu.
  final void Function(String channelId, ChannelAction action)? onAction;

  /// The row actions the backend can do yet; null for all of them. A row
  /// left with none opens no menu.
  final Set<ChannelAction>? allowedActions;
```

**Edit 5** — `lib/ui/shell/channel_list.dart`: replace

```dart
                      onAction: widget.onAction,
                      ringingId: widget.ringingId,
                      home: widget.home,
```

with

```dart
                      onAction: widget.onAction,
                      allowedActions: widget.allowedActions,
                      ringingId: widget.ringingId,
                      home: widget.home,
```

**Edit 6** — `lib/ui/shell/channel_list.dart`: replace

```dart
    required this.onAction,
    this.ringingId,
    this.home = false,
    this.onReorder,
    this.onAdd,
  });

  final ChannelCategory category;
```

with

```dart
    required this.onAction,
    this.allowedActions,
    this.ringingId,
    this.home = false,
    this.onReorder,
    this.onAdd,
  });

  final ChannelCategory category;
  final Set<ChannelAction>? allowedActions;
```

**Edit 7** — `lib/ui/shell/channel_list.dart`: replace

```dart
        onTap: () => onSelect(channel.id),
        onAction: onAction == null || !channel.joined
            ? null
            : (action) => onAction!(channel.id, action),
      );
```

with

```dart
        onTap: () => onSelect(channel.id),
        allowedActions: allowedActions,
        onAction:
            onAction == null ||
                !channel.joined ||
                actionsFor(
                  channel,
                  home: home,
                  allowed: allowedActions,
                ).isEmpty
            ? null
            : (action) => onAction!(channel.id, action),
      );
```

**Edit 8** — `lib/ui/shell/channel_list.dart`: replace

```dart
    required this.onAction,
    this.ringing = false,
    this.home = false,
    this.longPressActions = true,
  });

  final Channel channel;
```

with

```dart
    required this.onAction,
    this.allowedActions,
    this.ringing = false,
    this.home = false,
    this.longPressActions = true,
  });

  final Channel channel;
  final Set<ChannelAction>? allowedActions;
```

**Edit 9** — `lib/ui/shell/channel_list.dart`: replace

```dart
      position: position,
      home: home,
    );
    if (action != null) onAction(action);
```

with

```dart
      position: position,
      home: home,
      allowed: allowedActions,
    );
    if (action != null) onAction(action);
```

**Edit 10** — `lib/ui/shell/spaces_rail.dart`: replace

```dart
    this.onAddSpace,
```

with

```dart
    this.onAddSpace,
    this.addSpace = true,
```

**Edit 11** — `lib/ui/shell/spaces_rail.dart`: replace

```dart
  final VoidCallback? onAddSpace;
```

with

```dart
  final VoidCallback? onAddSpace;

  /// Whether to draw the add-space button at all: false while the backend
  /// cannot add a space yet.
  final bool addSpace;
```

**Edit 12** — `lib/ui/shell/spaces_rail.dart`: replace

```dart
                      _AddSpaceButton(tokens: tokens, onTap: onAddSpace),
```

with

```dart
                      if (addSpace)
                        _AddSpaceButton(tokens: tokens, onTap: onAddSpace),
```

**Edit 13** — `lib/ui/shell/user_bar.dart`: replace

```dart
                Text(
                  currentUser.id,
```

with

```dart
                Text(
                  me.id,
```

**Edit 14** — `lib/ui/channel/channel_view.dart`: replace

```dart
  final TimelineController timeline;
```

with

```dart
  /// Null while the backend cannot read messages yet: the conversation
  /// says so, and offers no composer to write into nowhere.
  final TimelineController? timeline;
```

**Edit 15** — `lib/ui/channel/channel_view.dart`: replace

```dart
            if (callPanel != null && callPanelExpanded)
              Expanded(child: callPanel!)
            else ...[
```

with

```dart
            if (timeline == null)
              const Expanded(child: _Unwired())
            else if (callPanel != null && callPanelExpanded)
              Expanded(child: callPanel!)
            else ...[
```

**Edit 16** — `lib/ui/channel/channel_view.dart`: replace

```dart
              Expanded(child: _Timeline(controller: timeline)),
```

with

```dart
              Expanded(child: _Timeline(controller: timeline!)),
```

**Edit 17** — `lib/ui/channel/channel_view.dart`: replace

```dart
                timeline: timeline,
                prefix: switch (channel) {
```

with

```dart
                timeline: timeline!,
                prefix: switch (channel) {
```

**Edit 18** — `lib/ui/channel/channel_view.dart`: append at the end of the file:

```dart

/// Where the timeline goes, before this backend can read one.
class _Unwired extends StatelessWidget {
  const _Unwired();

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(LoafSpace.x6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.messagesSquare, size: 28, color: tokens.textMuted),
            const SizedBox(height: LoafSpace.x3),
            Text(
              "messages aren't wired up yet",
              textAlign: TextAlign.center,
              style: loafBody(13, 400).copyWith(color: tokens.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Settings — the real you, read-only where it cannot be edited, and a sign-out that signs out**

**Edit 19** — `lib/ui/settings/settings_page.dart`: replace

```dart
import 'package:lucide_icons_flutter/lucide_icons.dart';
```

with

```dart
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../model/models.dart';
```

**Edit 20** — `lib/ui/settings/settings_page.dart`: replace

```dart
/// Opens settings over the current screen. [profile] is shared with the
/// account panel's status picker, so both edit the same presence.
Future<void> showSettings(BuildContext context, {ProfileController? profile}) =>
    showDialog<void>(
      context: context,
      barrierColor: const Color(0x99000016),
      builder: (_) => SettingsModal(profile: profile),
    );
```

with

```dart
/// Opens settings over the current screen. [profile] is shared with the
/// account panel's status picker, so both edit the same presence. [me] is
/// who the account section shows, and [editable] whether it offers to
/// change anything; [onSignOut] is what the sign-out button does.
Future<void> showSettings(
  BuildContext context, {
  ProfileController? profile,
  Member? me,
  bool editable = true,
  VoidCallback? onSignOut,
}) => showDialog<void>(
  context: context,
  barrierColor: const Color(0x99000016),
  builder: (_) => SettingsModal(
    profile: profile,
    me: me,
    editable: editable,
    onSignOut: onSignOut,
  ),
);
```

**Edit 21** — `lib/ui/settings/settings_page.dart`: replace

```dart
    this.initial = SettingsSection.account,
    this.profile,
  });

  final ProfileController? profile;
```

with

```dart
    this.initial = SettingsSection.account,
    this.profile,
    this.me,
    this.editable = true,
    this.onSignOut,
  });

  final ProfileController? profile;

  /// Left null (in isolation, as in tests), the mock's account.
  final Member? me;
  final bool editable;
  final VoidCallback? onSignOut;
```

**Edit 22** — `lib/ui/settings/settings_page.dart`: replace

```dart
        child: _Nav(
          selected: _section,
          onSelect: (s) => setState(() => _section = s),
        ),
```

with

```dart
        child: _Nav(
          selected: _section,
          onSelect: (s) => setState(() => _section = s),
          onSignOut: widget.onSignOut,
        ),
```

**Edit 23** — `lib/ui/settings/settings_page.dart`: replace

```dart
      Expanded(
        child: _Detail(section: _section, profile: widget.profile),
      ),
```

with

```dart
      Expanded(child: _detail(_section)),
```

**Edit 24** — `lib/ui/settings/settings_page.dart`: replace

```dart
      return _Nav(selected: null, onSelect: (s) => setState(() => _pushed = s));
    }
    return _Detail(section: pushed, profile: widget.profile);
  }
```

with

```dart
      return _Nav(
        selected: null,
        onSelect: (s) => setState(() => _pushed = s),
        onSignOut: widget.onSignOut,
      );
    }
    return _detail(pushed);
  }

  Widget _detail(SettingsSection section) => _Detail(
    section: section,
    profile: widget.profile,
    me: widget.me,
    editable: widget.editable,
  );
```

**Edit 25** — `lib/ui/settings/settings_page.dart`: replace

```dart
class _Nav extends StatelessWidget {
  const _Nav({required this.selected, required this.onSelect});
```

with

```dart
class _Nav extends StatelessWidget {
  const _Nav({required this.selected, required this.onSelect, this.onSignOut});

  final VoidCallback? onSignOut;
```

**Edit 26** — `lib/ui/settings/settings_page.dart`: replace

```dart
          _SignOut(tokens: tokens),
```

with

```dart
          _SignOut(tokens: tokens, onTap: onSignOut),
```

**Edit 27** — `lib/ui/settings/settings_page.dart`: replace

```dart
class _SignOut extends StatelessWidget {
  const _SignOut({required this.tokens});

  final LoafTokens tokens;
```

with

```dart
class _SignOut extends StatelessWidget {
  const _SignOut({required this.tokens, this.onTap});

  final LoafTokens tokens;
  final VoidCallback? onTap;
```

**Edit 28** — `lib/ui/settings/settings_page.dart`: replace

```dart
        size: LoafButtonSize.small,
        onTap: () {},
      ),
    ),
  );
}
```

with

```dart
        size: LoafButtonSize.small,
        onTap: onTap ?? () {},
      ),
    ),
  );
}
```

**Edit 29** — `lib/ui/settings/settings_page.dart`: replace

```dart
class _Detail extends StatelessWidget {
  const _Detail({required this.section, required this.profile});

  final SettingsSection section;
  final ProfileController? profile;
```

with

```dart
class _Detail extends StatelessWidget {
  const _Detail({
    required this.section,
    required this.profile,
    required this.me,
    required this.editable,
  });

  final SettingsSection section;
  final ProfileController? profile;
  final Member? me;
  final bool editable;
```

**Edit 30** — `lib/ui/settings/settings_page.dart`: replace

```dart
      return AccountSection(profile: profile);
```

with

```dart
      return AccountSection(profile: profile, me: me, editable: editable);
```

**Edit 31** — `lib/ui/settings/account_section.dart`: replace

```dart
import 'package:flutter/material.dart';
```

with

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
```

**Edit 32** — `lib/ui/settings/account_section.dart`: replace

```dart
class AccountSection extends StatefulWidget {
  const AccountSection({super.key, this.profile});

  /// Shared with the account panel's picker. Left null (in isolation, as in
  /// tests), the section keeps a profile of its own.
  final ProfileController? profile;
```

with

```dart
class AccountSection extends StatefulWidget {
  const AccountSection({super.key, this.profile, this.me, this.editable = true});

  /// Shared with the account panel's picker. Left null (in isolation, as in
  /// tests), the section keeps a profile of its own.
  final ProfileController? profile;

  /// Who is signed in. Left null, the mock's account.
  final Member? me;

  /// False while the backend cannot change a profile yet: everything reads
  /// as fact, with nothing to edit or save.
  final bool editable;
```

**Edit 33** — `lib/ui/settings/account_section.dart`: replace

```dart
class _AccountSectionState extends State<AccountSection> {
  final _name = TextEditingController(text: currentUser.name);
```

with

```dart
class _AccountSectionState extends State<AccountSection> {
  Member get _me => widget.me ?? currentUser;

  /// The mock's ids are bare localparts; a real one is whole already.
  String get _matrixId => _me.id.contains(':') ? _me.id : '${_me.id}:loaf.moe';

  late final _name = TextEditingController(text: _me.name);
```

**Edit 34** — `lib/ui/settings/account_section.dart`: replace

```dart
              _FieldLabel(tokens: tokens, label: 'avatar'),
              _AvatarRow(tokens: tokens),
              const SizedBox(height: LoafSpace.x6),

              _FieldLabel(tokens: tokens, label: 'display name'),
              _TextRow(tokens: tokens, controller: _name),
              const SizedBox(height: LoafSpace.x5),

              _FieldLabel(tokens: tokens, label: 'matrix id'),
              _ReadOnlyRow(tokens: tokens, value: '${currentUser.id}:loaf.moe'),
              const SizedBox(height: LoafSpace.x5),
```

with

```dart
              _FieldLabel(tokens: tokens, label: 'avatar'),
              _AvatarRow(tokens: tokens, me: _me, editable: widget.editable),
              const SizedBox(height: LoafSpace.x6),

              _FieldLabel(tokens: tokens, label: 'display name'),
              if (widget.editable)
                _TextRow(tokens: tokens, controller: _name)
              else
                _ReadOnlyRow(tokens: tokens, value: _me.name, mono: false),
              const SizedBox(height: LoafSpace.x5),

              _FieldLabel(tokens: tokens, label: 'matrix id'),
              _ReadOnlyRow(tokens: tokens, value: _matrixId),
              if (widget.editable) ...[
                const SizedBox(height: LoafSpace.x5),
```

**Edit 35** — `lib/ui/settings/account_section.dart`: replace

```dart
                      onTap: () => _status.text = _profile.status,
                    ),
                  ],
                ),
              ),
            ],
```

with

```dart
                      onTap: () => _status.text = _profile.status,
                    ),
                  ],
                ),
              ),
              ],
            ],
```

**Edit 36** — `lib/ui/settings/account_section.dart`: replace

```dart
class _AvatarRow extends StatelessWidget {
  const _AvatarRow({required this.tokens});

  final LoafTokens tokens;
```

with

```dart
class _AvatarRow extends StatelessWidget {
  const _AvatarRow({
    required this.tokens,
    required this.me,
    required this.editable,
  });

  final LoafTokens tokens;
  final Member me;

  /// Offers a new picture: the camera badge and its hint.
  final bool editable;
```

**Edit 37** — `lib/ui/settings/account_section.dart`: replace

```dart
                color: currentUser.color,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text(
                currentUser.initials,
```

with

```dart
                color: me.color,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text(
                me.initials,
```

**Edit 38** — `lib/ui/settings/account_section.dart`: replace

```dart
            Positioned(
              right: -2,
              bottom: -2,
```

with

```dart
            if (editable)
              Positioned(
              right: -2,
              bottom: -2,
```

**Edit 39** — `lib/ui/settings/account_section.dart`: replace

```dart
            Text(
              currentUser.name,
              style: loafDisplay(20, 600).copyWith(color: tokens.textStrong),
            ),
            const SizedBox(height: 2),
            Text(
              'png or jpg, at least 256px',
              style: loafBody(11, 400).copyWith(color: tokens.textMuted),
            ),
```

with

```dart
            Text(
              me.name,
              style: loafDisplay(20, 600).copyWith(color: tokens.textStrong),
            ),
            if (editable) ...[
              const SizedBox(height: 2),
              Text(
                'png or jpg, at least 256px',
                style: loafBody(11, 400).copyWith(color: tokens.textMuted),
              ),
            ],
```

**Edit 40** — `lib/ui/settings/account_section.dart`: replace

```dart
class _ReadOnlyRow extends StatelessWidget {
  const _ReadOnlyRow({required this.tokens, required this.value});

  final LoafTokens tokens;
  final String value;
```

with

```dart
class _ReadOnlyRow extends StatelessWidget {
  const _ReadOnlyRow({
    required this.tokens,
    required this.value,
    this.mono = true,
  });

  final LoafTokens tokens;
  final String value;

  /// Ids are set in mono; names are not.
  final bool mono;
```

**Edit 41** — `lib/ui/settings/account_section.dart`: replace

```dart
            style: loafMono(13).copyWith(color: tokens.textBody),
          ),
        ),
        IconButton(
          onPressed: () {},
```

with

```dart
            style: (mono ? loafMono(13) : loafBody(15, 400)).copyWith(
              color: tokens.textBody,
            ),
          ),
        ),
        IconButton(
          onPressed: () => Clipboard.setData(ClipboardData(text: value)),
```

- [ ] **Step 5: The shell asks before it draws**

**Edit 42** — `lib/ui/shell/app_shell.dart`: replace

```dart
    // The channel the app opens on is being read from the first frame.
    // Before listening: nothing is built yet to hear it.
    _rooms.markRead(_channel.id);
```

with

```dart
    // The channel the app opens on is being read from the first frame.
    // Before listening: nothing is built yet to hear it.
    if (_can(RoomAbility.markRead)) _rooms.markRead(_channel.id);
```

**Edit 43** — `lib/ui/shell/app_shell.dart`: replace

```dart
  bool get _home => _spaceId == mockHome.id;
```

with

```dart
  bool get _home => _spaceId == mockHome.id;

  bool _can(RoomAbility ability) => _rooms.abilities.contains(ability);

  /// The row actions the rooms can carry out. Older conversations is only
  /// a way to reach a room, so it is always there.
  Set<ChannelAction> get _allowedActions => {
    if (_can(RoomAbility.markRead)) ChannelAction.markRead,
    if (_can(RoomAbility.tag)) ...[
      ChannelAction.favourite,
      ChannelAction.unfavourite,
      ChannelAction.lowPriority,
      ChannelAction.notLowPriority,
    ],
    ChannelAction.olderConversations,
    if (_can(RoomAbility.mute)) ...[ChannelAction.mute, ChannelAction.unmute],
    if (_can(RoomAbility.leave)) ChannelAction.leave,
  };

  /// You as others see you: with your presence and status where the
  /// backend can set them, and as the rooms know you where it cannot.
  Member get _me => _can(RoomAbility.editProfile) ? _profile.me : _rooms.me;
```

**Edit 44** — `lib/ui/shell/app_shell.dart`: replace

```dart
    return {
      session.target.id: [
        _profile.me,
```

with

```dart
    return {
      session.target.id: [
        _me,
```

**Edit 45** — `lib/ui/shell/app_shell.dart`: replace

```dart
    // Seeing a conversation is reading it, in a space as much as in Home.
    _rooms.markRead(channelId);
```

with

```dart
    // Seeing a conversation is reading it, in a space as much as in Home.
    if (_can(RoomAbility.markRead)) _rooms.markRead(channelId);
```

**Edit 46** — `lib/ui/shell/app_shell.dart`: replace

```dart
      if (channel.kind == ChannelKind.voice && !joining && isDesktop) {
```

with

```dart
      if (channel.kind == ChannelKind.voice &&
          !joining &&
          isDesktop &&
          _can(RoomAbility.calls)) {
```

**Edit 47** — `lib/ui/shell/app_shell.dart`: replace

```dart
          final id = _rooms.createSpace(name, me: _profile.me);
```

with

```dart
          final id = _rooms.createSpace(name, me: _me);
```

**Edit 48** — `lib/ui/shell/app_shell.dart`: replace

```dart
    final me = _profile.me;
    final people = <String, Member>{
```

with

```dart
    final me = _me;
    final people = <String, Member>{
```

**Edit 49** — `lib/ui/shell/app_shell.dart`: replace

```dart
    // Phones update through the App Store or TestFlight, never in-app.
    if (_showUpdate && isDesktop)
```

with

```dart
    // Phones update through the App Store or TestFlight, never in-app. The
    // mock's notice only: there is no updater behind it yet.
    if (_showUpdate && isDesktop && _session is MockSession)
```

**Edit 50** — `lib/ui/shell/app_shell.dart`: replace

```dart
    if (channel.kind == ChannelKind.voice) {
      return VoiceChannelPage(
```

with

```dart
    // Before the backend can read messages, every room is its header and a
    // line saying so — a voice channel too, since joining a call is a
    // conversation's next step.
    if (!_can(RoomAbility.messages)) {
      return ChannelView(
        channel: channel,
        timeline: null,
        navigationAttention: _notices.any((n) => n.loud),
        onOpenNavigation: openNavigation,
        onToggleMembers: wide
            ? () => setState(() => _showMembers = !_showMembers)
            : () => _scaffoldKey.currentState?.openEndDrawer(),
      );
    }

    if (channel.kind == ChannelKind.voice) {
      return VoiceChannelPage(
```

**Edit 51** — `lib/ui/shell/app_shell.dart`: replace

```dart
      onStartCall: callHere
          ? null
```

with

```dart
      onStartCall: callHere || !_can(RoomAbility.calls)
          ? null
```

**Edit 52** — `lib/ui/shell/app_shell.dart`: replace

```dart
        final me = _profile.me;
        final channel = _channel;
```

with

```dart
        final me = _me;
        final channel = _channel;
```

**Edit 53** — `lib/ui/shell/app_shell.dart`: replace

```dart
              onAddSpace: _addSpace,
```

with

```dart
              onAddSpace: _addSpace,
              addSpace: _can(RoomAbility.addSpace),
```

**Edit 54** — `lib/ui/shell/app_shell.dart`: replace

```dart
                onAction: _channelAction,
```

with

```dart
                onAction: _channelAction,
                allowedActions: _allowedActions,
```

**Edit 55** — `lib/ui/shell/app_shell.dart`: replace

```dart
                onNewMessage: _newMessage,
                onReorderFavourites: _rooms.reorderFavourites,
```

with

```dart
                onNewMessage: _can(RoomAbility.startDirect)
                    ? _newMessage
                    : null,
                onReorderFavourites: _can(RoomAbility.tag)
                    ? _rooms.reorderFavourites
                    : null,
```

**Edit 56** — `lib/ui/shell/app_shell.dart`: replace

```dart
            onSettings: () => showSettings(context, profile: _profile),
            me: _profile.me,
            onAvatarTap: (anchor) =>
                showStatusPicker(context, _profile, anchor: anchor),
```

with

```dart
            onSettings: () => showSettings(
              context,
              profile: _profile,
              me: _me,
              editable: _can(RoomAbility.editProfile),
              onSignOut: _session.signOut,
            ),
            me: _me,
            onAvatarTap: _can(RoomAbility.editProfile)
                ? (anchor) =>
                      showStatusPicker(context, _profile, anchor: anchor)
                : null,
```

- [ ] **Step 6: Run the test to see it pass**

```bash
mise exec -- flutter test test/app_shell_rooms_test.dart
```

Expected: `+9: All tests passed!`

- [ ] **Format what you touched, by path, then analyze and run everything**

```bash
mise exec -- dart format lib/ui/shell/channel_actions.dart lib/ui/shell/channel_list.dart lib/ui/shell/spaces_rail.dart lib/ui/shell/user_bar.dart lib/ui/channel/channel_view.dart lib/ui/settings/settings_page.dart lib/ui/settings/account_section.dart lib/ui/shell/app_shell.dart test/app_shell_rooms_test.dart
```

```bash
mise exec -- flutter analyze
```

```bash
mise exec -- flutter test
```

Expected: `No issues found!` and `+530: All tests passed!`.

- [ ] **Checkpoint: commit (only if Chris has said to commit this run)**

```bash
git add lib/ui/shell/channel_actions.dart lib/ui/shell/channel_list.dart lib/ui/shell/spaces_rail.dart lib/ui/shell/user_bar.dart lib/ui/channel/channel_view.dart lib/ui/settings/settings_page.dart lib/ui/settings/account_section.dart lib/ui/shell/app_shell.dart test/app_shell_rooms_test.dart
```

```bash
git commit -m "feat(shell): draw only the controls the backend can carry out" -m "A control that flips local state on a real account lies: the change is gone on relaunch. The shell now asks the rooms what they can do. Settings sign-out and copy did nothing; now they do." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Faces, fallbacks, and an answer on its way

`_channel` becomes nullable. With no conversation to show, the pane shows `SyncingFace` until the first sync lands — a spinner while the server has not answered, a progress bar once its answer is being handled room by room — and `NothingHereFace` after. Both keep a menu button to the drawer on a phone. Where you are (`_placeId`) falls back to Home when your space has gone; the channel falls back as leaving does. Member lists ask the rooms for the whole list as they are shown. Answering an invite spins the pressed button with neither button live, and a refusal says so in a toast and leaves the preview up to try again.

**Files:**
- Create: `lib/ui/shell/shell_faces.dart`
- Modify: `lib/ui/home/invite_preview.dart`, `lib/ui/shell/app_shell.dart`
- Test: `test/app_shell_rooms_test.dart`

**Interfaces:**
- Consumes: everything from Tasks 2–5; `TopBarButton` from `lib/ui/call/call_view.dart`.
- Produces: `SyncingFace({double? progress, VoidCallback? onOpenNavigation})`, `NothingHereFace({VoidCallback? onOpenNavigation})`; `enum Answering { accepting, declining }` and `InvitePreview(answering: Answering?)`.

- [ ] **Step 1: Add the failing tests** — in `test/app_shell_rooms_test.dart`, insert above the `/// Rooms as a real backend has them in phase 2` comment:

```dart
final _invite = Invite(
  id: '!proofing',
  kind: InviteKind.room,
  name: 'Proofing',
  inviter: _mod,
  color: const Color(0xFF4E9E76),
  room: const Channel(id: '!proofing', name: 'Proofing'),
);
```

and add these groups inside `main()`, after the `only what is wired is drawn` group:

```dart
  group('faces and fallbacks', () {
    testWidgets('the first sync spins, then fills a bar', (tester) async {
      final rooms = (_FakeRooms()..synced = false);
      await _pump(tester, rooms, settle: false);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      rooms
        ..syncProgress = 0.4
        ..update();
      await tester.pump();
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, 0.4);
      rooms
        ..synced = true
        ..syncProgress = null
        ..spaces = [_bakery()]
        ..update();
      await tester.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      // The app opened on Home; the space arrives on the rail.
      expect(find.byKey(const ValueKey('space-!bakery')), findsOneWidget);
    });

    testWidgets(
      'on a phone the first sync still has a way to the drawer',
      variant: _mobile,
      (tester) async {
        await _pump(
          tester,
          (_FakeRooms()..synced = false),
          size: const Size(390, 844),
          settle: false,
        );
        expect(find.byTooltip('Channels'), findsOneWidget);
      },
    );

    testWidgets('an account in no rooms says so', (tester) async {
      await _pump(tester, _FakeRooms());
      expect(find.text('nothing here yet'), findsOneWidget);
    });

    testWidgets('a room that vanishes falls back to the next', (tester) async {
      final rooms = _FakeRooms(spaces: [_bakery()]);
      await _pump(tester, rooms);
      expect(find.text('general'), findsWidgets);
      rooms
        ..spaces = [
          _bakery(
            channels: const [
              Channel(id: '!crumb', name: 'crumb'),
              Channel(id: '!oven', name: 'oven', kind: ChannelKind.voice),
            ],
          ),
        ]
        ..update();
      await tester.pumpAndSettle();
      expect(find.text('general'), findsNothing);
      expect(find.text('crumb'), findsWidgets);
    });

    testWidgets('a space that vanishes falls back to Home', (tester) async {
      final rooms = _FakeRooms(spaces: [_bakery()], homeRooms: [_dm]);
      await _pump(tester, rooms);
      rooms
        ..spaces = []
        ..update();
      await tester.pumpAndSettle();
      expect(_inList('Moddy'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a space channel asks for the space\'s whole member list', (
      tester,
    ) async {
      final rooms = _FakeRooms(spaces: [_bakery()]);
      await _pump(tester, rooms);
      expect(rooms.membersAsked, contains('!bakery'));
      expect(find.text('Moddy'), findsOneWidget);
    });
  });

  group('answering an invite', () {
    Future<_FakeRooms> openInvite(WidgetTester tester) async {
      final rooms = _FakeRooms(homeRooms: [_dm])
        ..invites = [_invite]
        ..answer = Completer();
      await _pump(tester, rooms);
      await tester.tap(_inList('Proofing'));
      await tester.pumpAndSettle();
      return rooms;
    }

    testWidgets('while an answer is on its way, neither button answers', (
      tester,
    ) async {
      final rooms = await openInvite(tester);
      await tester.tap(find.text('accept'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.text('decline'));
      await tester.pump();
      rooms.answer!.complete();
      await tester.pumpAndSettle();
      expect(find.text('accept'), findsNothing);
    });

    testWidgets('a refused answer says so, and the buttons come back', (
      tester,
    ) async {
      final rooms = await openInvite(tester);
      await tester.tap(find.text('accept'));
      await tester.pump();
      rooms.answer!.completeError(Exception('403'));
      await tester.pumpAndSettle();
      expect(find.text("couldn't join. try again?"), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('accept'), findsOneWidget);
    });
  });
```

- [ ] **Step 2: Run them to see them fail**

```bash
mise exec -- flutter test test/app_shell_rooms_test.dart
```

Expected: 7 of the 8 new tests FAIL — `Bad state: No element` thrown from `_channel` for the syncing and empty accounts and the vanished space, no `loadMembers` call, and no spinner on accept. "A room that vanishes falls back to the next" already passes (the existing leave fallback covers it); it stays as a guard.

- [ ] **Step 3: Create `lib/ui/shell/shell_faces.dart`**

```dart
/// What the conversation pane shows when there is no conversation to show:
/// the account's first sync still arriving, or nothing in it at all.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../call/call_view.dart';
import '../theme/loaf_theme.dart';

/// The first sync, still coming. A spinner while the server has not
/// answered, which says nothing about how long; a bar once its answer is
/// being worked through, room by room. Nothing to press: it cannot be
/// stopped, and it retries on its own.
class SyncingFace extends StatelessWidget {
  const SyncingFace({super.key, this.progress, this.onOpenNavigation});

  /// 0 to 1, or null while waiting on the server.
  final double? progress;

  /// The phone layout's way to the drawer, and the account panel in it.
  final VoidCallback? onOpenNavigation;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final progress = this.progress;
    return _Face(
      onOpenNavigation: onOpenNavigation,
      child: progress == null
          ? const CircularProgressIndicator.adaptive()
          : SizedBox(
              width: 200,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(LoafRadius.full),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 6,
                  color: tokens.accent,
                  backgroundColor: tokens.sunken,
                ),
              ),
            ),
    );
  }
}

/// Signed in, synced, and in no rooms at all.
class NothingHereFace extends StatelessWidget {
  const NothingHereFace({super.key, this.onOpenNavigation});

  final VoidCallback? onOpenNavigation;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return _Face(
      onOpenNavigation: onOpenNavigation,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.messagesSquare, size: 28, color: tokens.textMuted),
          const SizedBox(height: LoafSpace.x3),
          Text(
            'nothing here yet',
            style: loafBody(13, 400).copyWith(color: tokens.textMuted),
          ),
        ],
      ),
    );
  }
}

/// The page, a header bar only where there is a drawer to open, and
/// [child] in the middle.
class _Face extends StatelessWidget {
  const _Face({required this.child, this.onOpenNavigation});

  final Widget child;
  final VoidCallback? onOpenNavigation;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final onOpenNavigation = this.onOpenNavigation;
    return ColoredBox(
      color: tokens.page,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (onOpenNavigation != null)
              Container(
                height: 56,
                padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x3),
                alignment: Alignment.centerLeft,
                child: TopBarButton(
                  icon: LucideIcons.menu,
                  tooltip: 'Channels',
                  onTap: onOpenNavigation,
                ),
              ),
            Expanded(child: Center(child: child)),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Apply the edits, in order**

**Edit 1** — `lib/ui/home/invite_preview.dart`: replace

```dart
class InvitePreview extends StatelessWidget {
  const InvitePreview({
    super.key,
    required this.invite,
    required this.onAccept,
    required this.onDecline,
    this.onOpenNavigation,
  });

  final Invite invite;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
```

with

```dart
/// An answer on its way to the server.
enum Answering { accepting, declining }

class InvitePreview extends StatelessWidget {
  const InvitePreview({
    super.key,
    required this.invite,
    required this.onAccept,
    required this.onDecline,
    this.answering,
    this.onOpenNavigation,
  });

  final Invite invite;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  /// Set while an answer is on its way. Neither button answers then — the
  /// server may already have it, so there is nothing to take back — and
  /// the one pressed spins.
  final Answering? answering;
```

**Edit 2** — `lib/ui/home/invite_preview.dart`: replace

```dart
                              child: LoafButton(
                                label: 'decline',
                                emphasis: LoafButtonEmphasis.outlined,
                                onTap: onDecline,
                              ),
```

with

```dart
                              child: LoafButton(
                                label: 'decline',
                                emphasis: LoafButtonEmphasis.outlined,
                                leading: answering == Answering.declining
                                    ? const _Spinner()
                                    : null,
                                onTap: answering == null ? onDecline : null,
                              ),
```

**Edit 3** — `lib/ui/home/invite_preview.dart`: replace

```dart
                              child: LoafButton(
                                label: 'accept',
                                onTap: onAccept,
                              ),
```

with

```dart
                              child: LoafButton(
                                label: 'accept',
                                leading: answering == Answering.accepting
                                    ? const _Spinner()
                                    : null,
                                onTap: answering == null ? onAccept : null,
                              ),
```

**Edit 4** — `lib/ui/home/invite_preview.dart`: append at the end of the file:

```dart

/// Sized to sit where a button's icon goes.
class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
    width: 15,
    height: 15,
    child: CircularProgressIndicator.adaptive(strokeWidth: 2),
  );
}
```

**Edit 5** — `lib/ui/shell/app_shell.dart`: replace

```dart
import 'profile_controller.dart';
```

with

```dart
import 'profile_controller.dart';
import 'shell_faces.dart';
```

**Edit 6** — `lib/ui/shell/app_shell.dart`: replace

```dart
    // The channel the app opens on is being read from the first frame.
    // Before listening: nothing is built yet to hear it.
    if (_can(RoomAbility.markRead)) _rooms.markRead(_channel.id);
```

with

```dart
    // The channel the app opens on is being read from the first frame.
    // Before listening: nothing is built yet to hear it.
    final opening = _channel;
    if (opening != null && _can(RoomAbility.markRead)) {
      _rooms.markRead(opening.id);
    }
```

**Edit 7** — `lib/ui/shell/app_shell.dart`: replace

```dart
  /// The invite being previewed in place of a conversation, if any.
  String? _previewInvite;
```

with

```dart
  /// The invite being previewed in place of a conversation, if any.
  String? _previewInvite;

  /// The invite whose answer is on its way to the server, and which.
  (String, Answering)? _answering;
```

**Edit 8** — `lib/ui/shell/app_shell.dart`: replace

```dart
  bool get _home => _spaceId == mockHome.id;
```

with

```dart
  /// Where you are: the space you chose, or Home once it has gone — left
  /// from another client, say.
  String get _placeId =>
      _spaceId != mockHome.id && _spaces.any((s) => s.id == _spaceId)
      ? _spaceId
      : mockHome.id;

  bool get _home => _placeId == mockHome.id;
```

**Edit 9** — `lib/ui/shell/app_shell.dart`: replace

```dart
    if (!_home) {
      return _spaces
          .firstWhere((s) => s.id == _spaceId)
          .withSession(occupants: _callOccupants, unread: _missedCalls);
    }
```

with

```dart
    if (!_home) {
      return _spaces
          .firstWhere((s) => s.id == _placeId)
          .withSession(occupants: _callOccupants, unread: _missedCalls);
    }
```

**Edit 10** — `lib/ui/shell/app_shell.dart`: replace

```dart
  Channel get _channel {
    final rows = _space.allChannels;
    // An older duplicate DM is not a row of its own, but can be open.
    final channels = [...rows, for (final row in rows) ...row.earlier];
    final remembered = _channelBySpace[_spaceId];
    return channels.firstWhere(
      (c) => c.id == remembered && c.joined,
      orElse: () =>
          channels.firstWhere((c) => c.kind != ChannelKind.voice && c.joined),
    );
  }
```

with

```dart
  /// The conversation you are reading: the one you last opened here while
  /// it is still here, else the first you can read. Null when there is none
  /// — the first sync is still coming, or the account is in no rooms.
  Channel? get _channel {
    final rows = _space.allChannels;
    // An older duplicate DM is not a row of its own, but can be open.
    final channels = [...rows, for (final row in rows) ...row.earlier];
    final remembered = _channelBySpace[_placeId];
    return channels.where((c) => c.id == remembered && c.joined).firstOrNull ??
        channels
            .where((c) => c.kind != ChannelKind.voice && c.joined)
            .firstOrNull;
  }
```

**Edit 11** — `lib/ui/shell/app_shell.dart`: replace

```dart
  void _selectSpace(String id) => setState(() {
    _spaceId = id;
    // A space opens onto a conversation, and seeing it is reading it.
    _open(id, _channel.id);
  });

  void _open(String spaceId, String channelId) {
    _spaceId = spaceId;
    _channelBySpace[spaceId] = channelId;
    _fullscreen = false;
    _previewInvite = null;
    // Seeing a conversation is reading it, in a space as much as in Home.
    if (_can(RoomAbility.markRead)) _rooms.markRead(channelId);
    _missedCalls.remove(channelId);
  }
```

with

```dart
  void _selectSpace(String id) => setState(() {
    _spaceId = id;
    // A space opens onto a conversation, and seeing it is reading it.
    _open(id, _channel?.id);
  });

  /// Goes to [spaceId], and opens [channelId] there if there is one.
  void _open(String spaceId, String? channelId) {
    _spaceId = spaceId;
    _fullscreen = false;
    _previewInvite = null;
    if (channelId == null) return;
    _channelBySpace[spaceId] = channelId;
    // Seeing a conversation is reading it, in a space as much as in Home.
    if (_can(RoomAbility.markRead)) _rooms.markRead(channelId);
    _missedCalls.remove(channelId);
  }
```

**Edit 12** — `lib/ui/shell/app_shell.dart`: replace

```dart
  /// A DM or room joins its section and opens; a space joins the rail and
  /// you stay in Home, where the rest of your invites are.
  Future<void> _acceptInvite(Invite invite) async {
    await _rooms.accept(invite);
    if (!mounted) return;
    setState(() {
      _previewInvite = null;
      final room = invite.room;
      if (room != null) _open(mockHome.id, room.id);
    });
  }

  Future<void> _declineInvite(Invite invite) async {
    await _rooms.decline(invite);
    if (!mounted) return;
    setState(() => _previewInvite = null);
  }
```

with

```dart
  /// A DM or room joins its section and opens; a space joins the rail and
  /// you stay in Home, where the rest of your invites are. A room the
  /// server has let you into but not yet synced opens once it arrives:
  /// until then the list's first room holds its place.
  Future<void> _acceptInvite(Invite invite) async {
    if (!await _answer(invite, Answering.accepting)) return;
    setState(() {
      _previewInvite = null;
      final room = invite.room;
      if (room != null) _open(mockHome.id, room.id);
    });
  }

  Future<void> _declineInvite(Invite invite) async {
    if (!await _answer(invite, Answering.declining)) return;
    setState(() => _previewInvite = null);
  }

  /// Sends the answer, spinning its button meanwhile. False when it failed,
  /// which leaves the preview up with its buttons to try again, or when the
  /// shell has gone.
  Future<bool> _answer(Invite invite, Answering answering) async {
    setState(() => _answering = (invite.id, answering));
    try {
      await (answering == Answering.accepting
          ? _rooms.accept(invite)
          : _rooms.decline(invite));
      return mounted;
    } on Object {
      if (mounted) {
        showToast(
          context,
          answering == Answering.accepting
              ? "couldn't join. try again?"
              : "couldn't decline. try again?",
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _answering = null);
    }
  }
```

**Edit 13** — `lib/ui/shell/app_shell.dart`: replace

```dart
    final looking = _home && _channel.id == chat.id;
```

with

```dart
    final looking = _home && _channel?.id == chat.id;
```

**Edit 14** — `lib/ui/shell/app_shell.dart`: replace

```dart
      _calls.session?.target.id == _channel.id &&
      (_home || _channel.kind == ChannelKind.voice);
```

with

```dart
      _calls.session?.target.id == _channel?.id &&
      (_home || _channel?.kind == ChannelKind.voice);
```

**Edit 15** — `lib/ui/shell/app_shell.dart`: replace

```dart
    if (invite != null) {
      return InvitePreview(
        invite: invite,
        onAccept: () => _acceptInvite(invite),
        onDecline: () => _declineInvite(invite),
        onOpenNavigation: openNavigation,
      );
    }
```

with

```dart
    if (invite != null) {
      final (answeringId, answering) = _answering ?? ('', null);
      return InvitePreview(
        invite: invite,
        onAccept: () => _acceptInvite(invite),
        onDecline: () => _declineInvite(invite),
        answering: answeringId == invite.id ? answering : null,
        onOpenNavigation: openNavigation,
      );
    }

    if (channel == null) {
      return _rooms.synced
          ? NothingHereFace(onOpenNavigation: openNavigation)
          : SyncingFace(
              progress: _rooms.syncProgress,
              onOpenNavigation: openNavigation,
            );
    }
```

**Edit 16** — `lib/ui/shell/app_shell.dart`: replace

```dart
    if (_fullscreen && !(_calls.inCall && _channel.kind == ChannelKind.voice)) {
```

with

```dart
    if (_fullscreen &&
        !(_calls.inCall && _channel?.kind == ChannelKind.voice)) {
```

**Edit 17** — `lib/ui/shell/app_shell.dart`: replace

```dart
        final me = _me;
        final channel = _channel;
        final members = MemberList(
          members: channel.kind == ChannelKind.direct
              ? [me, ...channel.members]
              : channel.kind == ChannelKind.room
              ? [for (final m in channel.members) m.id == me.id ? me : m]
              : [for (final m in _space.members) m.id == me.id ? me : m],
        );
```

with

```dart
        final me = _me;
        final channel = _channel;
        final members = channel == null ? null : _members(channel, me);
```

**Edit 18** — `lib/ui/shell/app_shell.dart`: replace

```dart
                      if (_showMembers &&
                          _previewInvite == null &&
                          (channel.kind == ChannelKind.text ||
                              channel.kind == ChannelKind.room))
```

with

```dart
                      if (members != null &&
                          _showMembers &&
                          _previewInvite == null &&
                          (channel!.kind == ChannelKind.text ||
                              channel.kind == ChannelKind.room))
```

**Edit 19** — `lib/ui/shell/app_shell.dart`: replace

```dart
          endDrawer: Drawer(
            width: drawerWidth.clamp(0.0, LoafShell.memberListWidth + 40),
            shape: const RoundedRectangleBorder(),
            backgroundColor: tokens.sidebar,
            child: members,
          ),
```

with

```dart
          endDrawer: members == null
              ? null
              : Drawer(
                  width: drawerWidth.clamp(
                    0.0,
                    LoafShell.memberListWidth + 40,
                  ),
                  shape: const RoundedRectangleBorder(),
                  backgroundColor: tokens.sidebar,
                  child: members,
                ),
```

**Edit 20** — `lib/ui/shell/app_shell.dart`: replace

```dart
  /// Everything in a DM is addressed to you, so a DM's unreads count; a
```

with

```dart
  /// Who is in [channel]: a DM's people and you, a Home room's own
  /// members, or a space channel's space. Asks the rooms for the whole
  /// list, where they only have some of it; they say when it arrives.
  MemberList _members(Channel channel, Member me) {
    final List<Member> members;
    switch (channel.kind) {
      case ChannelKind.direct:
        members = [me, ...channel.members];
      case ChannelKind.room:
        _rooms.loadMembers(channel.id);
        members = [for (final m in channel.members) m.id == me.id ? me : m];
      case ChannelKind.text || ChannelKind.voice:
        final space = _space;
        _rooms.loadMembers(space.id);
        members = [for (final m in space.members) m.id == me.id ? me : m];
    }
    return MemberList(members: members);
  }

  /// Everything in a DM is addressed to you, so a DM's unreads count; a
```

**Edit 21** — `lib/ui/shell/app_shell.dart`: replace

```dart
              selectedSpaceId: _spaceId,
```

with

```dart
              selectedSpaceId: _placeId,
```

**Edit 22** — `lib/ui/shell/app_shell.dart`: replace

```dart
                selectedChannelId: _channel.id,
```

with

```dart
                selectedChannelId: _channel?.id ?? '',
```

- [ ] **Step 5: Run the tests to see them pass**

```bash
mise exec -- flutter test test/app_shell_rooms_test.dart
```

Expected: `+17: All tests passed!`

- [ ] **Format what you touched, by path, then analyze and run everything**

```bash
mise exec -- dart format lib/ui/shell/shell_faces.dart lib/ui/home/invite_preview.dart lib/ui/shell/app_shell.dart test/app_shell_rooms_test.dart
```

```bash
mise exec -- flutter analyze
```

```bash
mise exec -- flutter test
```

Expected: `No issues found!` and `+538: All tests passed!`.

- [ ] **Checkpoint: commit (only if Chris has said to commit this run)**

```bash
git add lib/ui/shell/shell_faces.dart lib/ui/home/invite_preview.dart lib/ui/shell/app_shell.dart test/app_shell_rooms_test.dart
```

```bash
git commit -m "feat(shell): first-sync and empty faces, and rooms that vanish" -m "A fresh sign-in has no rooms until its first sync, and the shell assumed a channel always existed. Now it spins, then fills a bar, then shows the rooms; an empty account says so; a room or space left elsewhere falls back instead of throwing. An invite answer can be waited on, and can fail honestly." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: The real backend's rooms reach the shell

`SessionRoot` forwards a `Rooms` factory to `AppShell`; `main.dart` passes `() => MatrixRooms(matrix.client)` when run with `LOAF_BACKEND=matrix`. The shell makes the rooms when it opens (signed in) and disposes them when it closes (signed out), so a new account gets fresh rooms. The mock stays the default backend.

**Files:**
- Modify: `lib/ui/auth/session_root.dart`, `lib/main.dart`, `docs/superpowers/plans/2026-09-26-sdk-wiring-roadmap.md`

**Interfaces:**
- Consumes: `MatrixRooms` (Task 4), `AppShell(rooms:)` (Task 3).
- Produces: `SessionRoot({required LoafSession session, Rooms Function()? rooms})`; top-level `Rooms Function()? newRooms` in `main.dart`.

- [ ] **Step 1: Apply the edits**

**Edit 1** — `lib/ui/auth/session_root.dart`: replace

```dart
import '../shell/app_shell.dart';
```

with

```dart
import '../rooms/rooms.dart';
import '../shell/app_shell.dart';
```

**Edit 2** — `lib/ui/auth/session_root.dart`: replace

```dart
class SessionRoot extends StatefulWidget {
  const SessionRoot({super.key, required this.session});

  final LoafSession session;
```

with

```dart
class SessionRoot extends StatefulWidget {
  const SessionRoot({super.key, required this.session, this.rooms});

  final LoafSession session;

  /// Makes the account's rooms each time the app opens onto them. Left
  /// out, the shell plays the mock's.
  final Rooms Function()? rooms;
```

**Edit 3** — `lib/ui/auth/session_root.dart`: replace

```dart
    if (signIn == null) return AppShell(session: _session);
```

with

```dart
    if (signIn == null) return AppShell(session: _session, rooms: widget.rooms);
```

**Edit 4** — `lib/main.dart`: replace

```dart
import 'matrix/matrix_session.dart';
```

with

```dart
import 'matrix/matrix_rooms.dart';
import 'matrix/matrix_session.dart';
```

**Edit 5** — `lib/main.dart`: replace

```dart
import 'ui/platform.dart';
```

with

```dart
import 'ui/platform.dart';
import 'ui/rooms/rooms.dart';
```

**Edit 6** — `lib/main.dart`: replace

```dart
/// The app's one account. Lives as long as the app, like [themeMode].
late final LoafSession session;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The stored session restores from disk before the first frame, so a
  // signed-in app never flashes the sign-in screen.
  session = backend == 'matrix'
      ? await MatrixSession.open(desktop: isDesktop)
      : MockSession();
  runApp(const LoafApp());
}
```

with

```dart
/// The app's one account. Lives as long as the app, like [themeMode].
late final LoafSession session;

/// Makes the account's rooms each time the app opens onto them; null plays
/// the mock's.
Rooms Function()? newRooms;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The stored session restores from disk before the first frame, so a
  // signed-in app never flashes the sign-in screen.
  if (backend == 'matrix') {
    final matrix = await MatrixSession.open(desktop: isDesktop);
    session = matrix;
    newRooms = () => MatrixRooms(matrix.client);
  } else {
    session = MockSession();
  }
  runApp(const LoafApp());
}
```

**Edit 7** — `lib/main.dart`: replace

```dart
        child: Focus(autofocus: true, child: SessionRoot(session: session)),
```

with

```dart
        child: Focus(
          autofocus: true,
          child: SessionRoot(session: session, rooms: newRooms),
        ),
```

- [ ] **Step 2: Build the real backend for macOS**

```bash
mise exec -- flutter build macos --debug --dart-define=LOAF_BACKEND=matrix
```

Expected: `✓ Built build/macos/Build/Products/Debug/loaf_native.app`. Swift deprecation warnings from plugins are expected.

- [ ] **Step 3: Update the roadmap.** In `docs/superpowers/plans/2026-09-26-sdk-wiring-roadmap.md`, in the phase table's row 2, after "Read-only, so low risk", add ` **Plan: `2026-09-26-rooms-from-sync.md`**`. Then add this section after "Deferred from phase 1, to place later":

```markdown
## Deferred from phase 2, to place later

- **Unjoined channels from `/hierarchy`**, and joining a space's category subspaces and suggested channels (phase 5, with joining).
- **Voice occupancy avatars** need a `VoIP` instance to read MatrixRTC memberships (phase 7).
- **Avatar images** (`mxc` thumbnails) for spaces, rooms and people (phase 6 or 9). Initials on a colour until then.
- **Presence of others** is `Presence.unknown` until phase 6.
- **Marking read on opening** waits for read markers (phase 3); until then a real room's unread count stays after reading it elsewhere only until the next sync.
- **Rail order** is alphabetical. Element orders spaces by the `org.matrix.msc3230.space_order` account data; adopt it if it matters.
- **Member lists of very large rooms** load whole into memory when shown (`requestParticipants` with `cache: true`). Fine for loaf.moe; page them if a 10k-member room appears.
- **The debug menu's call levers** still ring mock DMs on the real backend (debug builds only).
```

- [ ] **Format what you touched, by path, then analyze and run everything**

```bash
mise exec -- dart format lib/ui/auth/session_root.dart lib/main.dart
```

```bash
mise exec -- flutter analyze
```

```bash
mise exec -- flutter test
```

Expected: `No issues found!` and `+538: All tests passed!`.

- [ ] **Checkpoint: commit (only if Chris has said to commit this run)**

```bash
git add lib/ui/auth/session_root.dart lib/main.dart docs/superpowers/plans/2026-09-26-sdk-wiring-roadmap.md
```

```bash
git commit -m "feat(app): the matrix backend shows your rooms" -m "LOAF_BACKEND=matrix now opens onto the account’s own spaces, rooms and invites. The mock stays the default until the timeline is real." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Look at it for real (Chris, with an agent driving)

Not a subagent task. Offer Chris a run of the real backend, in the background, logging to the scratchpad:

```bash
mise exec -- flutter run -d macos --dart-define=LOAF_BACKEND=matrix
```

With him driving, check and note (read the `[Matrix]` log lines as he goes):

- [ ] A relaunch opens straight onto his spaces, with no spinner (restored from the database).
- [ ] His spaces are on the rail; categories match the subspaces; unread and mention badges match another client's.
- [ ] Home's sections: DMs (one row per person), rooms in no space (tuwunel's `#admins` among them), favourites and low priority as tagged in Element.
- [ ] A space's member list colours admins and moderators.
- [ ] Right-click (desktop) opens nothing; no add-space, no new-message "+"; rooms say messages aren't wired up yet.
- [ ] Settings shows his display name and full Matrix ID; copy copies; sign out signs out, and signing back in (SSO) shows the spinner, then the bar, then Home with his spaces on the rail.
- [ ] If an invite is pending (ask before creating one on his account), accept shows the spinner and the room arrives.

Anything that disagrees becomes a finding for the final review, not an improvised fix.

## Self-Review Notes

- **Spec coverage.** Scope in/out → Tasks 4–6 and the roadmap's deferred list (Task 7). Honest controls → Task 5. The seam → Tasks 1–3 and 7 (a factory through `SessionRoot`/`AppShell` rather than `LoafSession.rooms`, so `LoafSession`'s test stand-ins stay unchanged; the spec says so). Mapping → Task 4 (rail, categories and flattening, Home membership, kinds, counts, topic and lock, tags, mute, invites, members and power levels, `me`). First-sync spinner then bar, empty face, unwired pane, hidden controls, live fallbacks → Tasks 5–6. Testing → every task.
- **Deviations from the spec's first draft, now written into it:** `members(roomId)` became `loadMembers(roomId)` plus snapshot members (widgets stay synchronous); a `messages` ability joined `RoomAbility`; settings sign-out and copy made honest; the update notice is mock-only; after the first sync the app stays on Home.
- **Type consistency** was checked by the rehearsal compiling and passing at every checkpoint.
