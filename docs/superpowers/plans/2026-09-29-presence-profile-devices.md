# Presence, Profile and Devices Implementation Plan (SDK phase 6)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** You, as others see you, reach the real account:
- presence and a status message, with do not disturb and automatic idle;
- other people's presence, with unknown kept apart from offline;
- your display name and avatar;
- mxc avatars for everyone and everything;
- a devices section in settings where another device can be renamed or signed out.

**Architecture:**
- **Three new seams, reached through `Rooms`:** `Profile`, `Devices` and `AvatarImages`. They follow the `Rooms.directory` precedent: `Rooms` hands each one out, `MockRooms` answers with mocks, and `MatrixRooms` with `Matrix*` implementations over the same `Client`.
- **`ProfileController`** keeps its public API and becomes a view over a `Profile`.
- **One `LoafAvatar` widget** replaces ten hand-rolled ones. Only after that does it learn to draw an image.

**Tech Stack:** Flutter 3.47.5 via `mise exec -- flutter`; `matrix` 13.0.0; new dependency `image_picker` (iOS and Android only).
- Real-SDK tests run offline over a real `Client` on `FakeMatrixApi` with an in-memory database. Copy the `_client()` / `_settle()` helpers from `test/matrix/matrix_rooms_test.dart:174-202`: each test file keeps its own copy, as the existing ones do.
- A per-file `FakeMatrixApi` subclass overrides `mockIntercept` for the answers the fake lacks, like `_Api` in that file.

**Spec:** `docs/superpowers/specs/2026-09-29-presence-profile-devices-design.md`. Read it first, including its **Findings** section. It sits under `2026-09-20-loaf-native-design.md` ("Presence and status") and `2026-09-27-e2ee-design.md`. Roadmap: `docs/superpowers/plans/2026-09-26-sdk-wiring-roadmap.md`.

**Not rehearsed.** Like phase 5, this plan gives interfaces, test names and the key code, not verbatim edits. Implementers read the files named in each task before editing. If the code disagrees with this plan, stop and say so rather than improvising.

## Global Constraints

- **The import rule:**
  - Only files under `lib/matrix/` (and `lib/main.dart`) import `package:matrix`.
  - `lib/ui/` never imports `lib/matrix/`.
  - The SDK exports its own `Presence`, `Timeline` and `Role`. Hide them where both are imported (`hide Presence, Timeline`).
- **The SDK is the store.** `MatrixProfile` keeps only the presence map (spec, "Other people") and the in-flight state of saves. `MatrixDevices` keeps only the last listed devices. Nothing else is persisted by loaf except the `moe.loaf.presence` account data.
- **Never call `Client.fetchCurrentPresence`** or `User.fetchCurrentPresence`: they save "never seen" as offline (spec, Findings).
- **Existing tests pass unchanged,** except for these mechanical edits, each named in its task:
  - Task 2: `test/app_shell_rooms_test.dart`'s `_FakeRooms` gains `avatarImages => const NoAvatarImages()`.
  - Task 3: `test/app_shell_rooms_test.dart`'s `_FakeRooms` gains the new `Rooms` members, all throwing `_unwired()` or returning mocks.
  - Task 3: `test/matrix/matrix_rooms_test.dart`'s abilities assertion adds `RoomAbility.editProfile`.
  - Task 7: that assertion adds `RoomAbility.devices`.

  Never edit an existing test to make it pass otherwise.
- **Honest controls:**
  - A control the backend cannot carry out is not drawn: gate on `RoomAbility`.
  - A step that cannot be stopped offers no cancel: an avatar upload, or a device delete after re-auth passes.
  - No dead ends: every failure leaves the control live.
- **Toasts** use `showToast(context, "couldn't … try again?")` from `lib/ui/widgets/toast.dart`. It is copy only: the failed control stays live, so trying again is the same tap.
- **Copy and layout:**
  - Copy is lowercase and warm.
  - Split by `isDesktop` from `lib/ui/platform.dart`: right-click and hover on computers, long-press and sheets on phones.
  - No hardcoded text metrics.
- **Native first:**
  - iOS avatar picking uses PHPicker through `image_picker`.
  - macOS and Linux use `file_selector`.
- `lib/matrix/` tests use `test()`, not `testWidgets()`.
- **Format only the files you touched, by path:** `mise exec -- dart format <paths>`.
- **Running things:** commands must work in Nushell. Run the suite in the foreground, one run at a time:
  - `mise exec -- flutter analyze`
  - `mise exec -- flutter test`
- **The baseline:** Task 1's first step records the passing count. Every later task must end at that count plus its own new tests.
- **Known flakes:** `test/matrix/matrix_timeline_test.dart`, and `matrix_session_test` "signing in again after signing out works". If only these fail, rerun once.
- **Encryption tests** need `mise exec -- flutter build macos --debug` first on a fresh clone.
- **Branch and commits:**
  - Work on the branch `phase6/presence-profile-devices`.
  - Commit only when the controller says to.
  - Messages are conventional and end with exactly `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Relaunching while in do not disturb.** The push rule and account data put DND back on the picker, and nothing unmutes. Pinned in Task 4: "dnd survives a restart".
2. **Another client unmutes while DND is chosen.** The choice reads online; loaf never re-mutes on its own. Pinned in Task 4: "the push rule wins over account data".
3. **Choosing a presence twice before the first answer.** The last choice wins, on the wire and on screen. The first call's failure must not undo the second. Pinned in Task 3: "a refused choice only rolls back its own wish".
4. **Signing out with a save, upload, rename or device sign-out in flight.** Nothing throws or notifies after `dispose`. Pinned in Tasks 3, 5 and 7: "disposing mid-save notifies nothing" (one per task).
5. **An mxc that 404s, or a server answering HTML.** `LoafAvatar` keeps its initials, nothing is written to the file store, and nothing is logged louder than `Logs().v`. Pinned in Task 2: "a thumbnail that fails leaves nothing cached".

## File Map

| File | Task | Responsibility |
|---|---|---|
| `lib/ui/widgets/loaf_avatar.dart` (new) | 1, 2 | the one avatar: initials on a colour, then an image over them |
| the ten avatar sites (Task 1 lists them) | 1 | use `LoafAvatar` |
| `lib/ui/model/models.dart` | 2 | `AvatarRef`; `avatar` on `Member`, `Channel`, `Space` |
| `lib/ui/widgets/avatar_images.dart` (new) | 2 | the `AvatarImages` interface and `AvatarImagesScope` |
| `lib/matrix/matrix_avatar_images.dart` (new) | 2 | `MatrixAvatarImages` and `MxcThumbnail` |
| `lib/ui/rooms/rooms.dart` | 2, 3, 7 | `avatarImages`, `profile`, `devices`, `RoomAbility.devices` |
| `lib/ui/shell/profile.dart` (new) | 3 | the `Profile` interface |
| `lib/ui/mock/mock_profile.dart` (new) | 3 | today's `ProfileController` state, moved |
| `lib/ui/shell/profile_controller.dart` | 3, 5 | a view over a `Profile` |
| `lib/matrix/matrix_profile.dart` (new) | 3, 4, 5 | presence on the wire, the presence map, DND, profile edits |
| `lib/ui/shell/idle_watcher.dart` (new) | 4 | automatic idle |
| `lib/ui/settings/account_section.dart` | 5 | save name and status; the avatar menu |
| `lib/ui/settings/avatar_picker.dart` (new) | 5 | native picking and the 512 px PNG |
| `lib/matrix/matrix_reauth.dart` (new) | 6 | `MatrixChallenge`, shared |
| `lib/matrix/matrix_verifier.dart` | 6 | uses `MatrixChallenge` |
| `lib/ui/settings/devices.dart` (new) | 7 | the `Devices` interface and `LoafDevice` |
| `lib/ui/mock/mock_devices.dart` (new) | 7 | three made-up sessions |
| `lib/matrix/matrix_devices.dart` (new) | 7 | list, rename, and sign-out with its own `UiaRequest` |
| `lib/ui/settings/devices_section.dart` (new) | 7 | the section, and its sign-out panel |
| `lib/ui/settings/settings_page.dart` | 5, 7 | `initial` section; the devices detail |
| `lib/ui/verify/incoming_verification.dart`, `verify_panel.dart` | 7 | "that's not me" opens devices |
| `lib/ui/shell/app_shell.dart` | 2, 3, 4, 7 | scope, profile from the rooms, the idle watcher, opening devices |
| `docs/superpowers/plans/2026-09-26-sdk-wiring-roadmap.md` | 8 | phase 6 landed, and what it left |

---

### Task 1: One `LoafAvatar` (no behaviour change)

**Files:**
- Create: `lib/ui/widgets/loaf_avatar.dart`, `test/loaf_avatar_test.dart`
- Modify: every site below. Read each first; each keeps its exact size, text style, radius, ring and shadow.

| Site | Today | `LoafAvatar` |
|---|---|---|
| `lib/ui/channel/message_group_tile.dart` `_Avatar` | `CircleAvatar(radius: 18)`, text 13/600 | size 36, circle |
| `lib/ui/shell/user_bar.dart` `_Avatar` | 36 circle, 13/600, presence dot wrapper | size 36; the dot stays a `Stack` wrapper |
| `lib/ui/shell/channel_list.dart` `RoomAvatar` | rounded `size*0.3`, first letter, `size*0.5`/700, id-hash palette | `radius: size*0.3`; keep the public API and palette |
| `lib/ui/shell/channel_list.dart` `_MemberAvatar` | circle, `size*0.42`/600, one letter under 18 | circle; keep the label rule |
| `lib/ui/shell/channel_list.dart` `_DirectAvatar` | composes `_MemberAvatar` | unchanged; it already goes through `_MemberAvatar` |
| `lib/ui/spaces/add_space.dart` `SpaceAvatar` | rounded `size/3`, `spaceInitials`, `size*0.36`/600 | `radius: size/3`; keep the public API |
| `lib/ui/members/member_list.dart` `_PresenceAvatar` | 32 circle, 12/600, dot | size 32; dot wrapper stays |
| `lib/ui/home/invite_preview.dart` `_PersonAvatar` | 72 circle, 26/600 | size 72 |
| `lib/ui/auth/login_page.dart` `_Avatar` | 64 circle, 24/600, `shadowMd` | size 64, `boxShadow` |
| `lib/ui/settings/account_section.dart` `_AvatarRow` | 88 circle, 30/600 | size 88; the camera badge stays a wrapper |

Also grep for other hand-rolled initials avatars: `rg -n "initials" lib/ui` and `rg -n "BoxShape.circle" lib/ui/call lib/ui/members/invite_panel.dart lib/ui/home/new_message_picker.dart lib/ui/shell/space_actions.dart`. Convert the ones that draw a person's, room's or space's initials on its colour in the same way. Leave anything that isn't an avatar (presence dots, badges, call controls).

**Interfaces:**
- Produces:
  ```dart
  class LoafAvatar extends StatelessWidget {
    const LoafAvatar({
      super.key,
      required this.label,     // already-computed initials; drawn as given
      required this.color,
      required this.size,
      required this.textStyle, // each site passes its own, e.g. loafBody(13, 600)
      this.radius,             // null: a circle; else a rounded square
      this.boxShadow,
    });
  }
  ```
  White text is applied inside (`textStyle.copyWith(color: Colors.white)`), as every site does today.

- [ ] **Step 1: Record the baseline.** Create the branch `phase6/presence-profile-devices`. Run `mise exec -- flutter test` and write the passing count into your report.
- [ ] **Step 2: Write the failing tests** in `test/loaf_avatar_test.dart`:
  - "draws its label on its colour": pump `LoafAvatar(label: 'AB', color: Colors.red, size: 36, textStyle: loafBody(13, 600))`, then expect `find.text('AB')`. Also expect the `DecoratedBox`/`Container` decoration colour red with shape circle.
  - "a radius makes a rounded square": `radius: 10`, then expect a `BorderRadius.circular(10)` with shape rectangle.
  - "is exactly its size": `tester.getSize(find.byType(LoafAvatar)) == const Size(36, 36)`.
- [ ] **Step 3:** Run `mise exec -- flutter test test/loaf_avatar_test.dart`. Expect it to fail: `LoafAvatar` is not defined.
- [ ] **Step 4:** Implement `LoafAvatar` as a `SizedBox` holding a `Container` with the decoration, `alignment: Alignment.center`, and the `Text` label.
- [ ] **Step 5:** Convert each site, one at a time. Run `mise exec -- flutter test` after each file. The whole suite must stay at the baseline plus 3, with no existing test edited.
- [ ] **Step 6:** `mise exec -- flutter analyze`, then format the touched files.
- [ ] **Step 7: Commit:** `refactor(ui): one LoafAvatar draws every avatar`

---

### Task 2: mxc thumbnails

**Files:**
- Modify: `lib/ui/model/models.dart`, `lib/ui/widgets/loaf_avatar.dart`, `lib/ui/rooms/rooms.dart`, `lib/ui/mock/mock_rooms.dart`, `lib/matrix/matrix_rooms.dart`, `lib/ui/shell/app_shell.dart`, and each Task 1 site that has a model to hand (pass `image:`)
- Create: `lib/ui/widgets/avatar_images.dart`, `lib/matrix/matrix_avatar_images.dart`, `test/matrix/matrix_avatar_images_test.dart`
- Test: add cases to `test/loaf_avatar_test.dart`

**Interfaces:**
- Produces, in `models.dart`:
  ```dart
  /// Where someone's or something's picture lives. Opaque to the UI: only
  /// the backend that made it can turn it into an image.
  @immutable
  class AvatarRef {
    const AvatarRef(this.value);
    final String value;
    static AvatarRef? maybe(String? v) => v == null || v.isEmpty ? null : AvatarRef(v);
    // == and hashCode on value
  }
  ```
  - `Member`, `Channel` and `Space` gain a named `AvatarRef? avatar` (default null).
  - `Member.copyWith` carries it through unchanged, and gains an `avatar` parameter used only by Task 5.
  - `Channel.copyWith` and `Space.withSession` also carry it through. Read them.
- Produces, in `avatar_images.dart`:
  ```dart
  abstract interface class AvatarImages {
    /// Null draws the initials.
    ImageProvider? resolve(AvatarRef ref, double physicalSize);
  }
  class NoAvatarImages implements AvatarImages { const NoAvatarImages(); ... null }
  class AvatarImagesScope extends InheritedWidget {
    const AvatarImagesScope({super.key, required this.images, required super.child});
    final AvatarImages images;
    static AvatarImages of(BuildContext context); // NoAvatarImages when absent
  }
  ```
- Produces: `Rooms.avatarImages` (`AvatarImages get avatarImages;`). The mock returns `const NoAvatarImages()`, and `MatrixRooms` returns a `MatrixAvatarImages(client)` it owns.
- Produces: `LoafAvatar` gains `this.image` (an `AvatarRef?`).

**`MxcThumbnail`** (`lib/matrix/matrix_avatar_images.dart`), the key code:
```dart
/// 64, 128 and 320 physical px: the sizes servers pre-generate, so their
/// thumbnails are reused rather than made per request.
int bucketFor(double physical) =>
    physical <= 64 ? 64 : physical <= 128 ? 128 : 320;

class MatrixAvatarImages implements AvatarImages {
  MatrixAvatarImages(this.client);
  final Client client;
  @override
  ImageProvider? resolve(AvatarRef ref, double physicalSize) {
    final uri = Uri.tryParse(ref.value);
    if (uri == null || !uri.isScheme('mxc')) return null;
    return MxcThumbnail(client, uri, bucketFor(physicalSize));
  }
}

class MxcThumbnail extends ImageProvider<MxcThumbnail> {
  MxcThumbnail(this.client, this.mxc, this.size);
  final Client client;
  final Uri mxc;
  final int size;

  @override
  Future<MxcThumbnail> obtainKey(ImageConfiguration _) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(MxcThumbnail key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _codec(decode), scale: 1);

  Future<Codec> _codec(ImageDecoderCallback decode) async =>
      decode(await ImmutableBuffer.fromUint8List(await bytes()));

  /// Throws on any failure: the widget keeps its initials, and nothing
  /// is cached.
  Future<Uint8List> bytes() async {
    final uri = await mxc.getThumbnailUri(client, width: size, height: size);
    // The file store is keyed per thumbnail uri, so each bucket keeps its own.
    final cached = await client.database.getFile(uri);
    if (cached != null) return cached;
    final response = await client.httpClient.get(
      uri,
      headers: {'authorization': 'Bearer ${client.accessToken}'},
    );
    final type = response.headers['content-type'] ?? '';
    if (response.statusCode != 200 || !type.startsWith('image/')) {
      throw StateError('no thumbnail for $mxc (${response.statusCode})');
    }
    await client.database.storeFile(
      uri, response.bodyBytes, DateTime.now().millisecondsSinceEpoch);
    return response.bodyBytes;
  }
  // == / hashCode on (mxc, size); not on client.
}
```
Read `ImageProvider`'s docs (`flutter/packages/flutter/lib/src/painting/image_provider.dart`) for the current `loadImage` signature before writing it. Log failures with `Logs().v`, not louder.

**`LoafAvatar` with an image.** It resolves with `AvatarImagesScope.of(context).resolve(image!, size * MediaQuery.devicePixelRatioOf(context))`, then stacks the initials `Container` and, above it, `ClipRRect`/`ClipOval` around an `Image(image: provider, fit: BoxFit.cover, width: size, height: size, frameBuilder: …)`. The `frameBuilder` fades in on the first frame, and its `errorBuilder` returns `SizedBox.shrink()`. With no scope or null, only initials are drawn, exactly as in Task 1.

**Mapping in `MatrixRooms`** (read the functions first):
- `_member`: `avatar: AvatarRef.maybe(room.unsafeGetUserFromMemoryOrFallback(userId).avatarUrl?.toString())`
- `_channel` and the space builder: `AvatarRef.maybe(room.avatar?.toString())`
- `_hierarchyChannel` and hierarchy spaces: `AvatarRef.maybe(chunk.avatarUrl?.toString())`
- `me`: leave it null here; Task 5 fills it from the profile
- `_invite`: the inviter's `avatar` from their member state, and the space's or room's from `room.avatar`

**Shell:** wrap the tree built in `_AppShellState.build` (where `PresenceScope` wraps it) in `AvatarImagesScope(images: _rooms.avatarImages, child: …)`.

- [ ] **Step 1: Write the failing widget tests** in `test/loaf_avatar_test.dart`:
  - "no scope draws initials only": `image: AvatarRef('mxc://x/y')`, no scope. Expect `find.byType(Image)` to find nothing.
  - "a resolved image draws over the initials": a scope whose fake `AvatarImages` returns `MemoryImage(kTransparentImage)`. Define a 1×1 PNG byte list in the test. Expect both the `Image` and the label to be found.
  - "a failing image keeps the initials": the fake returns a `MemoryImage` of garbage bytes. After `pumpAndSettle` the label is visible, and the `Image` builds only its `errorBuilder`, with no exception in `tester.takeException()`.
- [ ] **Step 2: Write the failing matrix tests** in `test/matrix/matrix_avatar_images_test.dart`, over a `FakeMatrixApi` subclass that answers `GET …/thumbnail/…`, records request headers, and has switches `status` and `contentType`:
  - "buckets round up to 64, 128 and 320": `bucketFor(1)==64`, `bucketFor(64)==64`, `bucketFor(65)==128`, `bucketFor(129)==320`, `bucketFor(2000)==320`.
  - "a thumbnail is fetched with the access token": `await MxcThumbnail(client, Uri.parse('mxc://fake/abc'), 64).bytes()`. The recorded `authorization` must equal `'Bearer abcd'`.
  - "a second fetch comes from the file store": call `bytes()` twice. There must be exactly one recorded request.
  - "a thumbnail that fails leaves nothing cached" *(Review Focus 5)*: `status = 404`, then `bytes()` throws. Next `status = 200, contentType = 'text/html'` also throws. Then `client.database.getFile(await mxc.getThumbnailUri(client, width: 64, height: 64))` is null.
  - "a non-mxc ref resolves to nothing": `MatrixAvatarImages(client).resolve(const AvatarRef('https://x/y'), 64)` is null.
  - "a member's avatar maps from their member event": in the existing harness style, sync a room whose `m.room.member` for `@alice:x` carries `avatar_url: mxc://x/a`. The mapped `Member.avatar` must equal `const AvatarRef('mxc://x/a')`. Put this one in `test/matrix/matrix_rooms_test.dart` as a new test: adding tests to that file is allowed; editing its existing ones is not.
- [ ] **Step 3:** Run both files. They fail to compile.
- [ ] **Step 4:** Implement the models, `avatar_images.dart`, `MatrixAvatarImages`/`MxcThumbnail`, `LoafAvatar`'s image, `Rooms.avatarImages` (in both the mock and matrix; `test/app_shell_rooms_test.dart`'s `_FakeRooms` returns `const NoAvatarImages()`, a Task 3-style mechanical edit made here), the mapping, the shell scope, and `image:` at each site that has a model.
- [ ] **Step 5:** The whole suite passes, and `analyze` is clean. Format the touched files.
- [ ] **Step 6: Commit:** `feat(avatars): mxc thumbnails for people, rooms and spaces`

---

### Task 3: The `Profile` seam, presence and status

**Files:**
- Create: `lib/ui/shell/profile.dart`, `lib/ui/mock/mock_profile.dart`, `lib/matrix/matrix_profile.dart`, `test/matrix/matrix_profile_test.dart`
- Modify: `lib/ui/shell/profile_controller.dart`, `lib/ui/rooms/rooms.dart`, `lib/ui/mock/mock_rooms.dart`, `lib/matrix/matrix_rooms.dart`, `lib/ui/shell/app_shell.dart`, `test/app_shell_rooms_test.dart` (`_FakeRooms` gains `profile => MockProfile()`), and `test/matrix/matrix_rooms_test.dart` (the abilities assertion adds `editProfile`)

**Interfaces:**
- Produces, in `lib/ui/shell/profile.dart`:
  ```dart
  abstract interface class Profile implements Listenable {
    PresenceChoice get choice;
    String get status;
    bool get presenceShared;
    /// You, as others see you.
    Member get me;
    /// Someone else's presence and status as last heard. `Presence.unknown`
    /// and null when nothing was ever heard.
    (Presence, String?) presenceOf(String userId);
    Future<void> choose(PresenceChoice choice);
    /// Empty clears it.
    Future<void> setStatus(String status);
    void dispose();
  }
  ```
  Task 5 adds `displayName`, `setDisplayName`, `setAvatar` and `saveAccount`. Keep room for them.
- Produces: `Rooms.profile` (`Profile get profile;`). The rooms own it and dispose it.
- Produces: `ProfileController`. Its constructor becomes `ProfileController({Profile? profile})`. With no profile it makes and owns a `MockProfile()`, so `ProfileController()` in existing tests behaves as before.
  - It forwards `choice`, `status`, `presenceShared`, `me`, `choose` and `setStatus` (the controller's `choose`/`setStatus` stay `void` and `unawaited` the future).
  - It re-notifies when the profile notifies.
  - `togglePresenceShared()` stays, and only acts on a `MockProfile`.
- `MockProfile`: exactly today's `ProfileController` fields and defaults (`online`, `'feeding the starter'`, `presenceShared` true, `me` from `currentUser`). Futures complete with `SynchronousFuture`. `presenceOf` returns the fixture member's presence (look it up in `lib/ui/mock/fixtures.dart`'s members) or `(Presence.unknown, null)`.
- The shell: `final _profile = ProfileController()` becomes `late final _profile = ProfileController(profile: _rooms.profile)`. The shell must not dispose the rooms' profile: `ProfileController.dispose` disposes only one it made itself.
- The shell's `_members` maps each non-you member through `_rooms.profile.presenceOf(m.id)` into `m.copyWith(presence:, statusMessage:)`, but only when `_can(RoomAbility.editProfile)`. The mock keeps its fixture presence because that ability is on and `MockProfile.presenceOf` returns the fixtures'.

**`MatrixProfile(client)`**, presence only in this task:
- **State:** `_choice` (default online), `_status` ('' until read), `_shared` (true), and `_heard`, a `Map<String, (Presence, String?)>`.
- **Start:**
  - Seed `_status` and your own choice from `client.database.getPresence(client.userID!)` if present (status only; the choice comes from account data in Task 4).
  - Listen to `client.onSync.stream`. For each `update.presence` event (a `Presence` event with a raw `content` map), map `content['presence']`: `online` becomes online, `unavailable` becomes idle, `busy` becomes dnd, and `offline` becomes offline. Record it along with `content['status_msg']`, set `_shared = true`, and notify.
  - For people never heard this session, `presenceOf` falls back to `client.database.getPresence(id)`. That is async, so warm `_heard` lazily: kick off a lookup the first time an id is asked for, return unknown meanwhile, and notify when it lands. A DB entry maps by `presence.name`; busy isn't kept there (spec).
- **After the first sync** (`client.onSyncStatus` reaching `SyncStatus.finished` once), send one `PUT` of the current choice and status: `client.setPresence(client.userID!, _wire(_choice), statusMsg: _status)`.
  - A `MatrixException` with `M_FORBIDDEN` or `M_UNRECOGNIZED`, or an HTTP 403 or 404, sets `_shared = false` and notifies.
  - Any other error decides nothing.
- **`choose(c)`:** set `_choice` at once and notify. Set `client.syncPresence = _wire(c)`, then `await client.setPresence(userID, _wire(c), statusMsg: _status)`. On failure, roll back to the previous choice only if no later `choose` has happened (a turn counter). Rethrow for the shell to toast.
- **`setStatus(s)`:** the same, on `_status`.
- **`_wire`:** online → `PresenceType.online`, idle → `unavailable`, invisible → `offline`. DND is `unavailable` in this task; Task 4 makes it busy.
- **`dispose`:** cancel the subscriptions, set `_disposed`, and never notify after it.

The shell toasts "couldn't change your presence. try again?" or "couldn't save your status. try again?" when these throw. `ProfileController`'s constructor also takes `void Function(Object error)? onError`. Its `void` `choose`/`setStatus` catch the future's error and call it. The shell passes `onError: _profileFailed`, which toasts with the shell's own `context` if `mounted`: presence errors get the presence copy, and `HalfApplied` (Task 4) gets its own.

- [ ] **Step 1: Write the failing tests** in `test/matrix/matrix_profile_test.dart` (a `FakeMatrixApi` subclass that records `PUT …/presence/…/status` bodies and can refuse them with a chosen errcode or status):
  - "choosing idle sends unavailable": after `choose(PresenceChoice.idle)`, the last recorded body has `presence == 'unavailable'` and `client.syncPresence == PresenceType.unavailable`.
  - "invisible sends offline".
  - "a status goes out with the presence": `setStatus('baking')`, so the body has `status_msg: 'baking'`. Then `setStatus('')` gives `status_msg: ''`.
  - "the first finished sync publishes the choice once": run a sync and count the PUTs; there is exactly one.
  - "a refused publish means the server shares none": refuse with `M_FORBIDDEN`, so after the first sync `presenceShared` is false.
  - "a presence event means the server shares again": after the above, sync a presence event for `@alice:x`. `presenceShared` is true again.
  - "a network failure decides nothing": the PUT throws `SocketException`, and `presenceShared` stays true.
  - "someone never heard is unknown, not offline": `presenceOf('@nobody:x').$1 == Presence.unknown`, and that stays true after `_settle()`.
  - "busy reads as do not disturb": sync `{type: m.presence, sender: @alice:x, content: {presence: busy, status_msg: 'focus'}}`, which gives `(Presence.dnd, 'focus')`.
  - "a refused choice only rolls back its own wish" *(Review Focus 3)*: hold the first PUT, `choose(idle)`, `choose(invisible)`, then fail the first PUT. `choice` is still invisible.
  - "disposing mid-save notifies nothing" *(Review Focus 4)*: hold a PUT, `choose(idle)`, `dispose()`, then release the PUT with an error. No listener call happens and no uncaught error.
- [ ] **Step 2:** Run the tests; they fail to compile.
- [ ] **Step 3:** Implement `Profile`, `MockProfile`, `ProfileController` over it, `Rooms.profile` in the mock (a `MockProfile` it owns) and in matrix (a `MatrixProfile(client)` it owns), `RoomAbility.editProfile` added to `MatrixRooms.abilities`, and the shell changes.
- [ ] **Step 4:** The whole suite passes (`settings_test`, `app_shell_test` and `presence_test` unchanged), and `analyze` is clean. Format the touched files.
- [ ] **Step 5: Commit:** `feat(matrix): presence and status reach the server, and others' arrive`

---

### Task 4: Do not disturb and automatic idle

**Files:**
- Modify: `lib/matrix/matrix_profile.dart`, `lib/ui/shell/app_shell.dart`
- Create: `lib/ui/shell/idle_watcher.dart`, `test/idle_watcher_test.dart`
- Test: add to `test/matrix/matrix_profile_test.dart`

**Interfaces:**
- Produces: `class HalfApplied implements Exception`, in `profile.dart` so the shell can see it. `MatrixProfile.choose` throws it when one DND call landed and the other didn't. The shell toasts "do not disturb only half-applied. try again?".
- Produces: `Profile.away(bool)`, for automatic idle. When true and the choice is online, `syncPresence` becomes unavailable and one PUT of unavailable goes out. When false, the choice's own wire value is restored. It never changes `choice`, never toasts, and swallows its errors (`Logs().v`). The mock ignores it.
- Produces:
  ```dart
  class IdleWatcher extends StatefulWidget {
    const IdleWatcher({super.key, required this.onAway, required this.child,
        this.after = const Duration(minutes: 10)});
    final ValueChanged<bool> onAway;
    ...
  }
  ```
  - Phones: it is a `WidgetsBindingObserver`. `paused` or `hidden` calls `onAway(true)`, and `resumed` calls `onAway(false)`.
  - Computers: a `Listener` (`onPointerDown`, `onPointerHover`, `onPointerSignal`) plus `HardwareKeyboard.instance.addHandler` reset a `Timer(after)`. When the timer fires it calls `onAway(true)`, and the next input calls `onAway(false)`.
  - It only calls on changes, never twice in a row with the same value.
  - Platform comes from `isDesktop`. Make it overridable for tests with a `@visibleForTesting bool? desktop` parameter.

**DND in `MatrixProfile`:**
- **Choosing DND:**
  1. `client.syncPresence = PresenceType.unavailable`, so sync never resets it to online.
  2. A raw PUT: `client.request(RequestType.PUT, '/client/v3/presence/${Uri.encodeComponent(userID)}/status', data: {'presence': 'busy', 'status_msg': _status})`. If that throws a `MatrixException`, fall back to `setPresence(unavailable)`; the fallback is not a failure.
  3. `await client.setMuteAllPushNotifications(true)`.
  4. Write account data `moe.loaf.presence` as `{'choice': 'dnd'}` via `client.setAccountData(userID, 'moe.loaf.presence', {...})`.

  If step 2 lands and step 3 fails, or the reverse, throw `HalfApplied`. `choice` then shows what stuck, by the reconcile rule below.
- **Leaving DND:** unmute first (`setMuteAllPushNotifications(false)`), then the new choice's presence, then account data.
- **Every other `choose`** also writes account data.
- **Reconcile** runs at start, on every account-data sync, and after a `HalfApplied`:
  ```dart
  PresenceChoice _reconcile(String? stored, bool muted) {
    if (muted) return PresenceChoice.dnd;               // the rule wins
    if (stored == 'dnd') return PresenceChoice.online;  // someone unmuted
    return PresenceChoice.values.asNameMap()[stored] ?? PresenceChoice.online;
  }
  ```
  `stored` is `client.accountData['moe.loaf.presence']?.content['choice']`. `muted` is `client.allPushNotificationsMuted`. After reconciling, set `syncPresence` to the reconciled choice's wire value, but never PUT from a reconcile, so a remote change is followed, not fought. `PresenceChoice` has no `name` clash: use `.name` on the enum values (`online`, `idle`, `dnd`, `invisible`).

**Shell:** wrap the shell's tree in `IdleWatcher(onAway: _rooms.profile.away, child: …)`, only when `_can(RoomAbility.editProfile)`.

- [ ] **Step 1: Write the failing tests.** The fake records push-rule PUTs (`/pushrules/global/override/.m.rule.master/enabled`, already answered by `FakeMatrixApi`; record and optionally refuse them) and `/user/…/account_data/moe.loaf.presence`.
  - "dnd sends busy and mutes every device": the PUT body has `presence: 'busy'`, the master rule is `enabled: true`, and the account data is `{choice: dnd}`.
  - "a server that refuses busy gets unavailable": refuse the busy PUT with `M_INVALID_PARAM`, so the next body is `unavailable`, the mute still happens, and `choose` completes normally.
  - "leaving dnd unmutes first": `choose(dnd)`, then `choose(online)`. The recorded order is the rule `enabled: false`, then the presence `online`.
  - "a refused mute is half-applied": refuse the push-rule PUT, so `choose(dnd)` throws `HalfApplied` and `choice` is online.
  - "dnd survives a restart" *(Review Focus 1)*: sync account data `{choice: dnd}` and a master rule enabled, then build a new `MatrixProfile` on the same client. `choice` is dnd and no push-rule PUT is recorded.
  - "the push rule wins over account data" *(Review Focus 2)*: account data dnd with the master rule disabled gives online, and no PUT at all. Account data idle with the master rule enabled gives dnd.
  - "away sends unavailable only while online": `away(true)` records `unavailable`. After `choose(invisible)`, `away(true)` records nothing. `away(false)` restores `offline`.
- [ ] **Step 2: Write the failing widget tests** in `test/idle_watcher_test.dart`:
  - "computer: ten quiet minutes is away, input is back": `desktop: true`. `tester.pump(const Duration(minutes: 10))`, then `onAway` was called with `[true]`. Send a pointer hover (`tester.createGesture(kind: PointerDeviceKind.mouse)` … `moveTo`), and the calls are `[true, false]`.
  - "computer: input resets the clock": 9 minutes, a key press (`tester.sendKeyEvent(LogicalKeyboardKey.shift)`), 9 more minutes, and still no calls.
  - "phone: backgrounding is away": `desktop: false`. `tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused)` gives `[true]`, and `resumed` gives `[true, false]`.
- [ ] **Step 3:** Run; the tests fail.
- [ ] **Step 4:** Implement.
- [ ] **Step 5:** The whole suite passes, and `analyze` is clean. Format the touched files.
- [ ] **Step 6: Commit:** `feat(presence): do not disturb silences every device, and idle comes on its own`

---

### Task 5: Display name and avatar

**Files:**
- Modify: `lib/ui/shell/profile.dart`, `lib/ui/mock/mock_profile.dart`, `lib/matrix/matrix_profile.dart`, `lib/ui/shell/profile_controller.dart`, `lib/ui/settings/account_section.dart`, `lib/ui/settings/settings_page.dart`, `lib/matrix/matrix_rooms.dart` (`me` takes name and avatar from the profile), `pubspec.yaml`
- Create: `lib/ui/settings/avatar_picker.dart`, `test/avatar_picker_test.dart`, `test/account_section_test.dart`
- Test: add to `test/matrix/matrix_profile_test.dart`

**Interfaces:**
- `Profile` gains:
  ```dart
  String get displayName;
  AvatarRef? get avatar;
  /// Saves the name and the status together; throws naming what didn't
  /// save. Unchanged fields aren't sent.
  Future<void> saveAccount({required String displayName, required String status});
  /// PNG bytes, or null to remove. One upload at a time.
  Future<void> setAvatar(Uint8List? png);
  bool get savingAccount;
  bool get uploadingAvatar;
  ```
  `me` includes `displayName` and `avatar`. `MockProfile` keeps them in memory, with the name from `currentUser.name`.
- Produces: `class AccountSaveFailed implements Exception { const AccountSaveFailed({required this.name, required this.status}); final bool name, status; }` in `profile.dart`. The flags say which part failed.
- `ProfileController` forwards all of these.
- Produces, in `lib/ui/settings/avatar_picker.dart`:
  ```dart
  /// The platform's own picker. Null when nothing was chosen.
  Future<Uint8List?> pickAvatarBytes();
  /// Long side at most [max] px, re-encoded as PNG.
  Future<Uint8List> shrinkToPng(Uint8List bytes, {int max = 512});
  ```
  - `pickAvatarBytes`: on iOS and Android, `ImagePicker().pickImage(source: ImageSource.gallery)` (which is PHPicker on iOS 14+). Otherwise `openFile(acceptedTypeGroups: [XTypeGroup(label: 'pictures', extensions: ['png','jpg','jpeg','gif','webp','heic'], uniformTypeIdentifiers: ['public.image'])])` from `file_selector`.
  - `shrinkToPng`: `instantiateImageCodec` with `targetWidth` or `targetHeight` set on the longer side only when it exceeds `max`, then `frame.image.toByteData(format: ImageByteFormat.png)`.
- Dependency: `mise exec -- flutter pub add image_picker`.
  - iOS: add `NSPhotoLibraryUsageDescription` to `ios/Runner/Info.plist` as `"pick a picture for your profile"`. PHPicker needs no permission, but `image_picker` checks for the key.
  - Check `image_picker`'s README for current iOS requirements before adding anything else.

**`MatrixProfile`:**
- On start, `fetchOwnProfile()` fills `displayName` and `avatar`. Listen to `client.onUserProfileUpdate` for your own id and refetch.
- `saveAccount` sends `client.setProfileField(userID, 'displayname', {'displayname': name})` if changed, and the status via Task 3's path if changed. It collects failures into `AccountSaveFailed`. `savingAccount` is true while either is in flight.
- `setAvatar(png)` calls `client.setAvatar(png == null ? null : MatrixImageFile(bytes: png, name: 'avatar.png', mimeType: 'image/png'))`. `uploadingAvatar` is true while in flight, and the avatar then refetches.
- `MatrixRooms.me` uses `profile.displayName` and `profile.avatar` once they are loaded.

**Account section:**
- **save changes:** `onTap` is null (drawn as the working state; read `LoafButton` for its disabled or busy look) while `savingAccount` is true, and the text fields are `readOnly` meanwhile. It calls `saveAccount`, and on `AccountSaveFailed` toasts:

  | Failed | Toast |
  |---|---|
  | both | "couldn't save your changes. try again?" |
  | name only | "couldn't save your name. try again?" |
  | status only | "couldn't save your status. try again?" |

  Fields keep their text on failure.
- **discard:** resets both fields to the profile's current values.
- **The camera badge and avatar:**
  - On a computer, a `GestureDetector` with `onTap` and `onSecondaryTapUp` opens the app's action menu at the point (read `lib/ui/widgets/action_menu.dart` for its API). On a phone, `onTap` opens a bottom sheet with the same items.
  - Items: "choose a picture…", then "remove picture" only when `avatar != null`.
  - Choosing runs `pickAvatarBytes`, then `shrinkToPng`, then `setAvatar`. A failure toasts "couldn't change your picture. try again?".
  - While `uploadingAvatar`, the badge's `onTap` is null and a small `CircularProgressIndicator.adaptive` sits over the avatar. There is no cancel.
- **The avatar row** uses `LoafAvatar(image: me.avatar, …)`. The hint reads "any picture, it's shrunk to fit".
- `editable: false` still draws everything read-only, as today.

- [ ] **Step 1: Write the failing tests.**
  - matrix:
    - "saving sends only what changed": change the name only, and there is no presence PUT.
    - "a refused name is named": refuse `PUT /profile/…/displayname`, so it throws `AccountSaveFailed(name: true, status: false)`.
    - "an avatar goes up and is set": `setAvatar(pngBytes)` records a `POST …/upload` and then `PUT …/avatar_url` with the returned mxc.
    - "removing sends an empty avatar_url".
    - "disposing mid-save notifies nothing" *(Review Focus 4)*.
  - `test/avatar_picker_test.dart`: "a large picture shrinks to 512 on its long side". Build a 1024×600 PNG in-test via `PictureRecorder`, run `shrinkToPng`, decode the result, and check its width is 512 and its height 300. Also "a small picture keeps its size", with 100×80.
  - `test/account_section_test.dart`, over a hand-written fake `Profile` whose `saveAccount` can hold or throw:
    - "save is busy and fields are read-only while saving"
    - "a failed name save says so and keeps your text"
    - "remove picture is offered only with a picture"
    - "the badge can't be tapped mid-upload"
- [ ] **Step 2:** Run; the tests fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** The whole suite passes (`settings_test` unchanged), and `analyze` is clean. Format the touched files.
- [ ] **Step 5: Commit:** `feat(profile): change your name and picture`

---

### Task 6: Re-authentication, shared

**Files:**
- Create: `lib/matrix/matrix_reauth.dart`
- Modify: `lib/matrix/matrix_verifier.dart`
- Test: existing `test/matrix/matrix_verifier_test.dart` and the verify widget tests pass unchanged; new tests come with Task 7's use

**Interfaces:**
- Produces:
  ```dart
  /// A server's "who are you?" for one request, answered by password or by
  /// the SSO fallback page in the real browser. Once an answer is on its
  /// way nothing here takes it back.
  class MatrixChallenge implements AuthChallenge {
    MatrixChallenge(this.client, this.uia, this.kind, {
      required this.retry,
      required this.onCancel,
      required Future<bool> Function(Uri) openBrowser,
    });
    ...
  }
  /// The kind a UIA request can be answered with here, or null.
  AuthKind? authKindFor(UiaRequest<Object?> uia);
  ```
- Move `_Challenge` from `matrix_verifier.dart:225-297` into `MatrixChallenge` verbatim, replacing `_verifier.client` with `client` and `_verifier._openBrowser` with `openBrowser`. Move the password/SSO kind choice from `matrix_verifier.dart:167-171` into `authKindFor`. `MatrixVerifier` uses both. Its behaviour, logs and comments stay the same.
- This is a pure move. No test file is edited, and the full suite is the proof.

- [ ] **Step 1:** Move the code.
- [ ] **Step 2:** Run `mise exec -- flutter test test/matrix/matrix_verifier_test.dart test/verify_panel_test.dart test/verification_controller_test.dart`, then the whole suite. All pass.
- [ ] **Step 3:** `analyze`; format the touched files.
- [ ] **Step 4: Commit:** `refactor(matrix): re-authentication stands on its own`

---

### Task 7: Devices

**Files:**
- Create: `lib/ui/settings/devices.dart`, `lib/ui/mock/mock_devices.dart`, `lib/matrix/matrix_devices.dart`, `lib/ui/settings/devices_section.dart`, `test/matrix/matrix_devices_test.dart`, `test/devices_section_test.dart`
- Modify: `lib/ui/rooms/rooms.dart` (`RoomAbility.devices`, `Devices get devices`), `lib/ui/mock/mock_rooms.dart`, `lib/matrix/matrix_rooms.dart`, `lib/ui/settings/settings_page.dart`, `lib/ui/shell/app_shell.dart`, `lib/ui/verify/incoming_verification.dart`, `lib/ui/verify/verify_panel.dart`, `test/app_shell_rooms_test.dart` (`_FakeRooms.devices => MockDevices()`), `test/matrix/matrix_rooms_test.dart` (the abilities assertion adds `devices`)

**Interfaces:**
- Produces, in `devices.dart`:
  ```dart
  @immutable
  class LoafDevice {
    const LoafDevice({required this.id, required this.name, required this.current,
        required this.verified, this.lastSeen, this.lastIp});
    final String id; final String name; final bool current; final bool verified;
    final DateTime? lastSeen; final String? lastIp;
  }
  abstract interface class Devices implements Listenable {
    /// Null until the first load; throws are the caller's to show.
    List<LoafDevice>? get list;
    Future<void> load();
    Future<void> rename(String id, String name);
    /// False when [onAuth]'s challenge was cancelled; nothing changed then.
    Future<bool> signOut(String id, {required void Function(AuthChallenge) onAuth});
    void dispose();
  }
  ```
  Sorting is the section's job, not the seam's. `LoafDevice.name` falls back to the device id when the server has no display name.
- `MockDevices`: three sessions ("loaf on this mac" as current and verified, "element on phone" verified 2 hours ago, "unknown session" unverified 30 days ago). `signOut` hands `onAuth` a mock challenge whose `password` succeeds for any non-empty string. Read `lib/ui/mock/mock_verifier.dart`'s challenge and reuse its shape.
- `MatrixDevices(client)`:
  - **`load`:** `client.getDevices()`, mapped. `verified` comes from `client.userDeviceKeys[userID]?.deviceKeys[id]?.verified ?? false`, `current` is `id == client.deviceID`, `lastSeen` from `lastSeenTs`, and `lastIp` from `lastSeenIp`.
  - **Reloading:** listen to `client.onSync` and reload when `update.deviceLists?.changed?.contains(client.userID)`.
  - **`rename`:** `client.updateDevice(id, displayName: name)`, then `load()`.
  - **`signOut`:** build a UIA request of its own, so it never passes through `onUiaRequest`. That is the spec's re-authentication isolation. The `onUpdate` callback must not re-enter.
    ```dart
    final done = Completer<bool>();
    var cancelled = false, asked = 0;
    late final UiaRequest<void> uia;
    uia = UiaRequest<void>(
      request: (auth) => client.deleteDevice(id, auth: auth),
      onUpdate: (state) {
        switch (state) {
          case UiaRequestState.done: if (!done.isCompleted) done.complete(true);
          case UiaRequestState.fail:
            if (done.isCompleted) return;
            cancelled ? done.complete(false) : done.completeError(uia.error!);
          case UiaRequestState.waitForUser:
            final kind = authKindFor(uia);
            if (kind == null) { uia.cancel(); return; }
            onAuth(MatrixChallenge(client, uia, kind, retry: asked++ > 0,
                onCancel: () => cancelled = true, openBrowser: _openBrowser));
          case UiaRequestState.loading: break;
        }
      },
    );
    final ok = await done.future;
    if (ok) await load();
    return ok;
    ```
    Read `UiaRequest` in the SDK (`lib/src/utils/uia_request.dart`) to confirm the state names and that the constructor starts the request itself.
  - `_openBrowser` defaults to the same `url_launcher` launch `MatrixVerifier` uses. Read `matrix_verifier.dart:17-24` and take it as a constructor parameter the same way.
- `RoomAbility.devices` is in `MatrixRooms.abilities` and in the mock's `RoomAbility.values`.
- `showSettings` gains `SettingsSection initial = SettingsSection.account` and `Devices? devices`. `_Detail` shows `DevicesSection(devices: …)` for `SettingsSection.devices` when a `devices` is given; otherwise the placeholder, as today.
- The shell passes `devices: _can(RoomAbility.devices) ? _rooms.devices : null`.

**The devices section:**
- **Order:** current first, then by `lastSeen` descending, with nulls last.
- **Loading:** `load()` runs on open. While `list == null` it shows a working line. On a throw it shows "couldn't load your devices" plus a quiet "try again" button.
- **A row shows:**
  - the name: `SelectableText` on computers, `Text` on phones
  - a small badge, "verified" or "unverified"
  - a muted line: "this device", or "last seen 3 days ago", then "· 1.2.3.4" when there is an IP. Write `_ago(DateTime)` locally: "just now", "N minutes ago", "N hours ago", "N days ago".
  - for an unverified other: "verify it from that device"
- **Rename:**
  - On a computer, clicking the name turns it into a `TextField`. Enter saves, Escape reverts, and it is `readOnly` while saving.
  - On a phone, tapping opens a bottom sheet with a field and "save".
  - Failure toasts "couldn't rename that device. try again?".
- **Sign out** (other devices only): a quiet "sign out" button opens `showAdaptivePanel` (`lib/ui/widgets/adaptive_panel.dart`) with a `_SignOutFlow` state machine:

  | State | Shows |
  |---|---|
  | `confirm` | "sign out {name}?", "it'll need to sign in again to read anything.", then "sign out" and "keep it" |
  | `auth` | `ResetAuthStep(lead: "confirm it's you before {name} is signed out.", …)`, wired exactly as `verify_panel.dart:211-226` wires it, including `inBrowser`, `checking` and `rejected` |
  | `signingOut` | a `WorkingLine` "signing out…" with no buttons. This is the point of no return |
  | done | closes the panel |
  | failed | back to `confirm`, with a toast "couldn't sign that device out. try again?" |

  A cancelled challenge (`signOut` returns false) closes the panel quietly.

**"that's not me":**
- `NotMeStep` gains `VoidCallback? onOpenDevices`. When it is given, the note reads "someone may be signed in as you. change your password, and sign that device out in settings." and a second button, "open devices", calls it.
- `verify_panel.dart` passes a callback that closes the panel and calls a new `VerifyPanel` parameter `onOpenDevices`. The shell supplies that as `showSettings(context, initial: SettingsSection.devices, devices: _rooms.devices, …)`, only when `_can(RoomAbility.devices)`.
- Existing `NotMeStep` tests pass unchanged, because the parameter is optional and the old copy stays when it is null.

- [ ] **Step 1: Write the failing tests.**
  - `test/matrix/matrix_devices_test.dart`, with a fake answering `GET /devices`, `PUT /devices/{id}`, and `DELETE /devices/{id}`. The delete answers 401 with a `flows: [{stages: [m.login.password]}]` and `session` the first time, then 200 when `auth.password == 'right'`, or 401 with `errcode: M_FORBIDDEN` for any other password.
    - "devices map with this one marked current"
    - "rename sends the name and reloads"
    - "signing out asks who you are, then deletes": `signOut('OTHER', onAuth: (c) => c.password('right'))` returns true, and `list` no longer contains `OTHER`.
    - "a wrong password asks again with retry": the first challenge gets `'wrong'`, and the second arrives with `retry == true`.
    - "cancelling signs nothing out": the challenge is cancelled, the call returns false, and no second DELETE is recorded.
    - "sign-out never appears on onUiaRequest": subscribe to `client.onUiaRequest` during a sign-out. It receives nothing.
    - "disposing mid-save notifies nothing" *(Review Focus 4)*: hold the DELETE, dispose, then release it.
  - `test/devices_section_test.dart`, over `MockDevices` and a hand fake for failures:
    - "this device is first, then newest"
    - "a failed load offers try again"
    - "renaming inline on a computer" (`debugDefaultTargetPlatformOverride = TargetPlatform.macOS`; read `test/platform_test.dart` for how the suite sets platform)
    - "signing out walks confirm, auth, then closes"
    - "no cancel while signing out": in `signingOut`, `find.text('keep it')` and every `IconButton` close find nothing
    - "not me opens devices": pump `NotMeStep(onClose: …, onOpenDevices: cb)`, tap "open devices", and `cb` was called
- [ ] **Step 2:** Run; the tests fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** The whole suite passes, and `analyze` is clean. Format the touched files.
- [ ] **Step 5: Commit:** `feat(settings): see your devices, rename them, sign one out`

---

### Task 8: By hand, and the roadmap

**Files:**
- Modify: `docs/superpowers/plans/2026-09-26-sdk-wiring-roadmap.md`

- [ ] **Step 1: The by-hand checks.** These need Chris; the controller asks him to run them.
  1. `mise exec -- flutter run -d macos`. Choose each presence, and watch it from another client (Element on loaf.moe):
     - Does tuwunel share presence at all?
     - Does it accept `busy`?
     - Does a sync with `set_presence=unavailable` keep `busy`?
  2. DND on the Mac. Is the phone silenced, and does the phone's picker show DND after relaunch?
  3. Set a picture with the native picker on macOS, and on the iOS simulator.
  4. Sign a spare session out through SSO (the fallback page in the real browser, "i've finished").
- [ ] **Step 2: Update the roadmap.**
  - The status line: phases 1–6 have landed, adding `2026-09-29-presence-profile-devices.md`.
  - Tick phase 6 in the table, and strike through the deferred items it settled:
    - phase 2's avatar images and presence of others;
    - phase 4's "a device list in settings" and "making an identity takes every re-auth request".
  - Add "Deferred from phase 6":
    - the other settings sections;
    - verifying another of your devices from settings;
    - cropping;
    - `busy` not surviving a relaunch for other people (the SDK's database stores it as offline);
    - whatever the by-hand run found.
- [ ] **Step 3: Commit:** `docs(roadmap): phase 6 landed, and what it left`
