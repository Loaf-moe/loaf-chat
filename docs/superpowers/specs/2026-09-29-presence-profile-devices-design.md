# loaf native — presence, profile and devices (SDK phase 6)

Phase 6 of `docs/superpowers/plans/2026-09-26-sdk-wiring-roadmap.md`: you,
as others see you, reach the real account. Presence and a status message,
a display name and an avatar, avatars for everyone else, and a devices
section in settings. It amends, and never contradicts,
`2026-09-20-loaf-native-design.md` ("Presence and status", whose mapping
table this implements) and `2026-09-27-e2ee-design.md` (re-authentication).

## Scope

**In:**

- The four presence choices and the status message, on the wire, surviving
  relaunch and shared across your devices.
- Do not disturb as MSC3026 `busy` plus the master push rule.
- Automatic idle: backgrounding on phones, inactivity on computers.
- Other people's presence and status, with unknown kept apart from offline.
- Detecting a server that shares no presence.
- Editing your display name. Choosing and removing your avatar with each
  platform's native picker.
- mxc avatar thumbnails for people, rooms and spaces everywhere an avatar is
  drawn (deferred from phase 2).
- A devices section in settings: list, rename, sign out another device.
- "that's not me" points at the devices section (deferred from phase 4).
- Re-authentication shared between the verify panel and device sign-out.

**Out, logged in the roadmap:**

| Deferred | Why |
|---|---|
| Appearance, notifications, voice & video, stickers, developer and about sections | Each is new UI the spec does not draw |
| Starting verification of another of your devices from settings | The incoming "is this you?" already covers it |
| Cropping a picked avatar | Circles cover-fit; a crop step is new UI |
| Per-space profiles | A proposal, deliberately not designed (account section's note) |

## Findings (verified 2026-09-29 against `matrix` 13.0.0)

- **`PresenceType` has no `busy`.** It is `online`, `offline` and
  `unavailable`. MSC3026 `busy` goes out as a raw `PUT /presence`, and
  arrives parsed as offline, so it is read from the raw event content.
- **`Client.fetchCurrentPresence` turns "never seen" into offline**
  (`CachedPresence.neverSeen` is `PresenceType.offline`), and on a failed
  fetch writes that to the database. loaf never calls it.
  `database.getPresence` returns null for someone never seen.
- **`Client.syncPresence`** is sent as `set_presence` on every sync.
- **DND's push rule** is `setMuteAllPushNotifications` /
  `allPushNotificationsMuted` (`.m.rule.master`).
- **Profile:** `fetchOwnProfile`, `setProfileField` (display name),
  `setAvatar(MatrixFile?)`, `onUserProfileUpdate`.
- **Devices:** `getDevices`, `updateDevice(id, displayName:)`,
  `deleteDevice(id, auth:)`, which raises a UIA request through
  `onUiaRequest` like phase 4's identity upload.
- **Thumbnails:** `Uri.getThumbnailUri(client, …)` picks the authenticated
  media endpoint where the server supports it, which then needs the bearer
  token on the request.

## The seams

Everything follows the `Rooms` precedent: a plain interface in `lib/ui/`,
`Mock*` and `Matrix*` implementations, and only `lib/matrix/` imports the
SDK. The mock keeps today's behaviour, so existing tests pass unchanged.

### `Profile`

`ProfileController` stops holding state and becomes a view over a
`Profile`. Its public API (`choice`, `status`, `choose`, `setStatus`,
`presenceShared`, `me`) is unchanged, so the status picker and the account
section keep working as they are. `Profile` adds:

- `displayName`, `avatar` (`AvatarRef?`), `setDisplayName(String)`,
  `setAvatar(Uint8List? png)` (null removes).
- `presenceOf(userId) → (Presence, String? status)` and a change stream the
  shell rebuilds member rows from.

`MockProfile` is today's `ProfileController` state, including the debug
lever that toggles `presenceShared`. `MatrixProfile` lives in
`lib/matrix/matrix_profile.dart`.

### `Devices`

`list()`, `rename(id, name)`, `signOut(id)`, and a change stream.
`MockDevices` holds three made-up sessions. `MatrixDevices` lives in
`lib/matrix/matrix_devices.dart`.

### `AvatarImages`

`lib/ui/model` gains `AvatarRef`, an opaque value that holds an mxc string
the UI never reads. `Member`, `Room` and `Space` carry an `AvatarRef?`. The
matrix mapping fills it from `avatarUrl`, and the mock leaves it null.

`AvatarImages` is found by an InheritedWidget and answers
`ImageProvider? resolve(AvatarRef, double physicalSize)`. The mock answers
null. `MatrixAvatarImages` answers an `MxcThumbnail` provider (below).

### Abilities

`RoomAbility.editProfile` turns on for the matrix backend. A new
`RoomAbility.devices` gates the devices section. Without it, the section
keeps its "not designed yet" placeholder.

## Presence and status

### Your choice on the wire

| Choice | Sent |
|---|---|
| online | `syncPresence = online` |
| idle | `syncPresence = unavailable` |
| do not disturb | raw `PUT /presence/{me}/status` with `busy`, **and** `setMuteAllPushNotifications(true)`. A server that refuses `busy` gets `unavailable` instead: others see idle, and your devices are still silenced |
| invisible | `syncPresence = offline` |

Leaving DND unmutes before anything else is sent. The status message rides
on `setPresence(…, statusMsg:)`. Empty clears it.

### Remembering the choice

The server cannot tell "chose idle" from "went idle", nor "invisible" from
"offline", so the choice is stored in account data as
`moe.loaf.presence: {"choice": "online" | "idle" | "dnd" | "invisible"}`.
It is read on start and on every account-data update, so a choice made on
one device shows on the others. The master push rule is account-wide, so
DND already is.

If they disagree, the push rule wins. Account data saying DND with the rule
off (another client unmuted) reads as online. The rule on with account data
not saying DND reads as DND. Your devices are never left silently muted
behind a choice that says otherwise.

### Automatic idle

An `IdleWatcher` in the shell:

- **Phones:** `AppLifecycleState.paused` sets `syncPresence = unavailable`,
  and `resumed` restores the choice.
- **Computers:** 10 minutes with no pointer or keyboard input (a root
  `Listener` and `HardwareKeyboard`) sets `unavailable`, and the next input
  restores the choice.

It acts only while the choice is online, and it changes `syncPresence`,
never the stored choice.

### Other people

`MatrixProfile` keeps its own map of user id → (presence, status, last
active). It is seeded from `database.getPresence` and fed by
`onPresenceChanged`. No entry maps to `Presence.unknown`. A raw
`presence: busy` maps to `Presence.dnd`. `unavailable` maps to idle.
Member rows take presence and `status_msg` from the map when mapped, and a
change for someone on screen rebuilds them.

### A server that shares none

There is no capability flag, so the first presence `PUT` of a session
decides. Choices other than DND travel on `syncPresence`, so once the
first sync finishes, `MatrixProfile` always sends one `PUT` of the current
choice and status. That republishes your status, and it asks the question. A refusal (tuwunel's "presence is disabled", any `M_FORBIDDEN` or
`M_UNRECOGNIZED` on that endpoint) sets `presenceShared = false`: every dot
disappears and the picker shows "this server doesn't share presence". Any
presence event arriving sets it back to true. A network failure decides
nothing. `presenceShared` is not persisted; each session asks again.

## Profile

### Display name and status

The account section's **save changes** saves the display name and the
status together. While saving, the button shows a working state and the
fields are read-only. A failure leaves your edits in the fields and toasts
what didn't save, with **try again**. **discard** restores what the server
has. The server copies a global profile change into every room's member
event, so names in rooms follow through sync.

### Choosing an avatar

The camera badge becomes a button, and on a computer right-clicking the
avatar does the same. It offers **choose a picture…** and, when there is
one, **remove picture**: a menu at the click point on a computer, an action
sheet on a phone.

| Platform | Picker |
|---|---|
| iOS | the system photo picker (PHPicker) through `image_picker`, a new dependency and the only route to the native picker |
| macOS, Linux | `file_selector` (NSOpenPanel; the portal on Linux), already a dependency, filtered to images |
| Android (best-effort) | `image_picker` |

The picked image is downscaled so its long side is at most 512 px and
re-encoded as PNG with `dart:ui` (`instantiateImageCodec(targetWidth:)`,
then `toByteData(format: png)`). No image library is added.

The upload cannot be stopped once it starts, so nothing offers to cancel.
The avatar shows a working state and the badge is disabled until it lands.
A failure toasts "couldn't change your picture. try again?", and the
badge is live again. The hint
under the name reads "any picture, it's shrunk to fit".

## Avatars everywhere

One `LoafAvatar(ref, initials, color, size, shape)` replaces the
hand-rolled avatars: `message_group_tile`, `login_page`, `user_bar`,
`invite_preview`, `channel_list` (`RoomAvatar`, `_DirectAvatar`,
`_MemberAvatar`), `add_space`'s `SpaceAvatar`, `member_list`,
`account_section`, the call tiles and bars, `invite_panel`,
`new_message_picker` and `space_actions`. Each keeps its size, shape and
ring. Presence dots and rings stay as wrappers at each site. The merge
lands first, with no behaviour change, so the existing tests pin it.

`LoafAvatar` draws the initials on the colour, then fades the image in over
them once it decodes. While loading, and whenever loading fails, the
initials stay. There is no retry and no error mark: an avatar is
decoration, and the fallback is already honest.

`MxcThumbnail` is an `ImageProvider` keyed on (mxc, size bucket). Size
buckets are 64, 128 and 320 physical pixels, the smallest at or above
`size × devicePixelRatio`, so the server's pre-generated thumbnails are
reused. It resolves `getThumbnailUri(client, width, height, method: crop)`
and fetches it with the access token over the client's `http.Client`. The
bytes are kept in the SDK's file store (`database.storeFile` /
`getFile`), so a relaunch draws from disk. Flutter's `ImageCache` holds
decoded images in memory.

## Devices

### On screen

"this device" comes first, then every other device by most recent activity.
A row shows:

- the name, selectable on computers (it's what gets copied)
- a verified or unverified badge, from cross-signing trust in
  `userDeviceKeys`
- last seen, relative ("3 days ago"), and the last IP where the server
  shares it

An unverified other device carries a muted line, "verify it from that
device".

**Rename:** inline on a computer, where Enter saves and Escape reverts. On
a phone, tapping the name opens a small sheet. Saving follows the account
form: read-only while in flight, a toast with **try again** on failure.

**Sign out** is offered on other devices only. This device signs out with
the existing button at the foot of the settings nav. A confirmation names
the device, then re-authentication runs. From the point of no return
(re-authentication passed, delete in flight) nothing offers to cancel, and
the row reads "signing out…" until it disappears. A refusal toasts with
**try again**.

**Loading:** the list loads when the section opens, after each action, and
when sync reports your device list changed. It doesn't poll. A failed load
reads "couldn't load your devices · try again".

### "that's not me"

The incoming verification's "that's not me" no longer says to sign the
device out from another app. It says to sign it out in settings, with a
button that opens settings on the devices section.

## Re-authentication, shared

Phase 4's challenge (`matrix_verifier.dart`: password, or SSO through the
server's fallback page in the real browser with "i've finished") moves to
`lib/matrix/matrix_reauth.dart`, with its UI step to a reusable widget
under `lib/ui/auth/`. The verify panel and device sign-out both use it. The
existing verify tests pass unchanged, which proves the move kept
behaviour.

Device sign-out builds its own `UiaRequest` around `deleteDevice` rather
than going through `Client.uiaRequestBackground`, so its challenge never
appears on `onUiaRequest`. Identity creation (which the SDK routes through
`onUiaRequest` internally) is then the only listener there, and it can no
longer take another flow's request. This settles phase 4's leftover that
"making an identity takes every re-auth request on the client".

## Errors

Toasts follow the app's existing convention: copy only, in the form
"couldn't save your name. try again?", with the control that failed still
live, so trying again is the same tap. Wherever this spec says "a toast
with **try again**", it means that.

- Anything you asked for that fails toasts what didn't happen, and the
  screen shows what the server has.
- Presence you didn't ask for (auto-idle) is never toasted. It is sent
  again with the next change.
- A half-applied DND (presence set but the push rule refused, or the
  reverse) toasts "do not disturb only half-applied · try again", and the
  choice shows what actually stuck, under the push-rule-wins rule.
- Offline, `syncPresence` changes go out with the next sync that succeeds.
  That is honest, because sync is what carries them.

## Testing

Existing tests pass **unchanged** at every step.

**`test/matrix/`**, a real `Client` over `FakeMatrixApi`, with `MockClient`
for error paths:

- the choice → wire table, including a refused `busy` falling back to
  `unavailable`
- the DND push rule in both directions, and each half-applied case
- the choice surviving a restart through account data, and push-rule-wins
- unknown vs offline, and raw `busy` read as DND
- "doesn't share" detection, and the flip back on a presence event
- display name and status save, and their failures
- avatar upload bytes, and removal
- `MxcThumbnail`'s bearer header, bucket choice and file-store hit
- device list, rename, and sign-out through a password UIA
- the shared re-auth claiming only its own request

**Widget tests** on the mock: `LoafAvatar`'s fallback and image states, the
devices section's states, the avatar menu per platform, and `IdleWatcher`
on a fake clock.

**By hand on loaf.moe:** whether tuwunel shares presence and accepts
`busy`, a real SSO device sign-out, and the native pickers on iOS and macOS.

## Order

Each step ends in its own checkpoint and commit:

1. `LoafAvatar` merges the avatars, with no behaviour change.
2. mxc thumbnails through `AvatarImages`.
3. The `Profile` seam, presence and status.
4. Do not disturb and automatic idle.
5. Display name and avatar upload.
6. Re-authentication extracted and shared.
7. Devices, and "that's not me" pointing there.
8. Roadmap update: phase 6 landed, and what it left.
