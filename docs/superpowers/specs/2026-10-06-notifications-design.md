# Loaf Chat — Notifications

Loaf Chat draws unread badges but counts them from the server's push-rule
numbers, plays no sound, and tells you nothing when it isn't in front. This
spec makes unread state follow the messages themselves, adds a chime while
the app is focused, native notifications on macOS, Windows and Linux when it
isn't, and push on iOS when the app is closed, decrypted on the phone. A
notification opens the message it is about, scrolled into view.

Loaf Chat is a Matrix client for any homeserver. Everything here is client
side and follows the Matrix spec; the push gateway iOS needs is an external
dependency named by a build setting.

## Scope

**In:**

- Unread state (bold, badges, the space pip) computed by the client,
  independent of push rules, correct on cold start and resume.
- A notifier that decides, per new message, between nothing, the chime, a
  desktop notification, or (on iOS, backgrounded) leaving it to push.
- Opening a channel at a given message, scrolled to and highlighted.
- A synthesized chime, the same on every platform.
- Native desktop notifications: macOS, Windows, Linux (portal inside
  Flatpak, `org.freedesktop.Notifications` outside).
- iOS push through a Matrix pusher, a Notification Service Extension that
  decrypts, and Apple's notification-filtering entitlement.
- A Notifications section in Settings.

**Out:**

| Deferred | Why |
|---|---|
| Android push | Needs FCM; not asked for |
| Running or configuring a push gateway | Outside the client; the gateway URL is a build setting |
| Keyword notifications | Can be added later without changing anything here |
| Per-space mute | Same |
| Do-not-disturb schedules | Same |
| An app-icon badge count | Not asked for; the server's push count disagrees with ours |
| Refreshing an expired token in the extension | Refresh tokens rotate; the extension would race the app and sign it out |
| The extension syncing for missing room keys | Would race the app's Olm state |

## Findings (checked 2026-10-06)

- **Counts** come from `room.notificationCount` and `room.highlightCount`
  (`lib/matrix/matrix_rooms.dart`, `_channel`). Both are push-rule
  derived: a muted or mentions-only room reports 0, and in an encrypted
  room the server can't see a mention at all.
- **Badges** are drawn in `lib/ui/shell/channel_list.dart` (`unread` bolds
  the row, except when muted; a DM shows `unread`, others `mentions`) and
  `lib/ui/shell/spaces_rail.dart` (`mentions`, falling back to `unread`).
- **Read marking is focus-aware already**: `channel_view.dart` marks read
  only while the app is resumed, and catches up on resume.
- **Mute** is `pushRuleState != PushRuleState.notify`; setting it writes
  `PushRuleState.dontNotify` (a mentions-only room rule).
- **No jump-to-event** exists. The SDK's `room.getTimeline(eventContextId:)`
  loads a timeline around an event.
- **The SDK database** (`matrix` 13.0.0, `MatrixSdkDatabase` over
  `sqflite_common_ffi`) is `loaf.sqlite` in the application support
  directory. Each box is a table `(k TEXT PRIMARY KEY, v TEXT)`.
  `box_client` holds `homeserver_url`, `token`, `token_expires_at`,
  `user_id`; `box_inbound_group_session` is keyed by session id, its value
  JSON with a `pickle` encrypted under `userId.toPickleKey()`.
- **Refresh tokens** are requested (`matrix_homeserver.dart`), so an
  access token can expire while the app is closed.
- **The SDK's `PushruleEvaluator`** evaluates push rules locally.
- **iOS** has only the Runner target (`moe.loaf.chat.ios`, team
  `6W2A5N37N3`, automatic signing). No push entitlement, no extension.
- **The Flatpak manifest** (`linux/packaging/moe.loaf.chat.yml`) does not
  grant `--talk-name=org.freedesktop.Notifications`, and a release that
  adds a permission cannot update in-app. The portal needs no permission.

## A. Unread state

Unread state follows the messages. Mute and mentions-only affect sound and
notifications only.

- **Unread message**: one from someone else after your read receipt, of a
  kind the timeline shows. Edits, reactions and state changes don't count.
- **Mention**: an unread message whose `m.mentions.user_ids` names you, or
  that carries `m.mentions.room` from a sender allowed to notify the room.
  A message without `m.mentions` (an older client) mentions you when its
  body contains your display name or user id. Encrypted messages are
  checked after decryption.
- **Channel**: bold when it has unreads, muted or not; the bell-off icon
  stays. Badge: the unread count in a DM, the mention count elsewhere.
- **Space**: a pip at the rail's left edge (the `_SelectionPill` slot) when
  any joined channel has unreads; a badge of total mentions. No unread
  count on a space.
- **Home**: unchanged in shape — DM unreads plus mentions elsewhere — now
  from the client's counts.
- **Gaps**: when a sync was limited and messages after your receipt are
  missing locally, the app fetches that stretch with `/messages`, at most
  99 events. A count at the cap shows as `99+`.
- **Start and resume**: counts are computed from the database before the
  first sync, then kept by sync. A relaunch shows yesterday's unreads
  immediately; a resume after a gap fills it as above.

## Notifier

One Dart notifier per session listens for new timeline events. It ignores
your own messages, events from before this session started (no notifying
the backlog on launch), and events the timeline wouldn't show. For the
rest it runs the SDK's `PushruleEvaluator` (with the decrypted content) and,
if the rules say notify:

| App state | Event's channel | Result |
|---|---|---|
| Focused | Open | Nothing; the channel view marks it read |
| Focused | Other | The chime (if Sound is on) |
| Desktop, unfocused | Any | A desktop notification (if Notifications is on) |
| iOS, backgrounded | Any | Nothing in-app; push carries it |

"Focused" is `AppLifecycleState.resumed`, the same test the channel view
uses. Several messages in the same second play the chime once.

## B. Jump to message

A `MessageRoute(roomId, eventId)` (not `Route`, which Flutter already
exports) selects the room's space (Home for DMs and rooms outside spaces;
the space you are in when it has the room) and opens the channel. The
timeline loads around the event with `eventContextId`, scrolls it into
view, and highlights it briefly. Scrolling down from there loads forward to
the live end. Sending from back in history returns to the newest messages
first; reacting, editing or deleting catches up to live in place.

An event the server won't return opens the channel at its newest messages
with a toast saying the message isn't available. A route to a room you
aren't in shows the same toast and stays where you are: there is no
channel to open. A route that arrives before the first sync waits for it.

Tapping a reply's quote jumps to the message it answers, the same way.

## C. The chime

`tool/chime` (Rust, a small binary with no dependencies beyond `std`)
synthesizes a soft, distinct two-note chime and writes
`assets/sounds/chime.wav` and `ios/Runner/chime.caf`. The outputs are
checked in; the tool regenerates them.

The app plays it through each platform's own player: System Sound
Services (`AudioServicesPlaySystemSound`) on macOS and iOS, Apple's player
for short alert sounds. It never touches the app's audio session, mixes
with other audio rather than interrupting it, plays at the alert volume,
and on iOS never sounds while the ring/silent switch is on silent,
whatever the rest of the app is playing. Linux plays it with GStreamer
(already a dependency for video), Windows with `PlaySound`.

## D. Desktop notifications

A Dart interface:

```dart
abstract interface class DesktopNotifications {
  Future<void> show(Notice notice);
  Future<void> withdraw(String roomId);
  Stream<MessageRoute> get clicks;
}
```

A `Notice` carries the route, a title (the sender's name, plus
`in #channel · Space` outside DMs), a body (the decrypted text, or
`sent a picture` / `sent a file`; `New message` when Show message text is
off) and the sender's avatar where the platform takes one. When a room
becomes read, on any device, its notifications are withdrawn. A click
brings the window to the front (`window_to_front`) and follows the route.

**macOS**: Swift in the Runner over a method channel, using
`UNUserNotificationCenter`. `threadIdentifier` is the room id, the sound is
the bundled chime, and clicks arrive through `didReceive`. Permission is
asked the first time the shell opens after sign-in.

**Windows**: a Rust crate using the `windows` crate's
`ToastNotificationManager`. The app registers its AUMID under
`HKCU\Software\Classes\AppUserModelId\moe.loaf.chat` (display name and
icon), which unpackaged apps may do. Clicks arrive through the toast's
`Activated` event in the running process; notifications only fire while
the app runs, so no COM activator is needed. Unpackaged apps cannot give a
toast a custom sound, so the toast is silent and the app plays the chime.

**Linux**: Dart over the existing `dbus` package.

- Inside Flatpak: `org.freedesktop.portal.Notification`. `AddNotification`
  per message, id `room:<roomId>:<eventId>`, a default action carrying the
  route; clicks arrive as `ActionInvoked`; `RemoveNotification` withdraws.
  Portal version 2 takes the chime as `sound`; on version 1 the app plays
  it.
- Outside Flatpak: `org.freedesktop.Notifications`, with the
  `desktop-entry` hint (`moe.loaf.chat`), `sound-file` pointing at the
  chime, a `default` action, `ActionInvoked` for clicks, and
  `CloseNotification` to withdraw.

## E. iOS push

**Pusher.** After sign-in, once notifications are allowed, the app calls
`registerForRemoteNotifications` and sets an `http` pusher:

- `app_id`: `moe.loaf.chat.ios`, or `moe.loaf.chat.ios.dev` in builds
  using the APNs sandbox.
- `pushkey`: the APNs token, hex.
- `data`: `{"url": <LOAF_PUSH_GATEWAY>, "format": "event_id_only"}`.

`LOAF_PUSH_GATEWAY` is a `--dart-define`. Without it the app registers no
pusher and Settings says push isn't set up in this build. The pusher is set
again when the token changes and removed on sign-out or when Notifications
is turned off on this device. The gateway must deliver `room_id` and
`event_id` at the top level of the APNs payload with `mutable-content: 1`.

**Shared storage.** `loaf.sqlite` moves into the App Group container
`group.moe.loaf.chat`. On first launch after the update, before the
database opens, the app moves `loaf.sqlite` and any `-wal`/`-shm` beside
it. The app opens the database in WAL mode so the extension can read while
it writes. The app also keeps in the App Group:

- `names.json`: room id → room name, space name, whether it's a DM.
  Written when the room list changes. The SDK computes room names; this is
  the computed result, not a second source of truth.
- The device settings (Notifications, Sound, Show message text) in shared
  `UserDefaults`.

**Notification Service Extension** (`moe.loaf.chat.ios.notify`, Swift).
For each push:

1. Open `loaf.sqlite` read-only (system SQLite). Read `homeserver_url`,
   `token`, `token_expires_at`, `user_id` from `box_client`.
2. `GET /_matrix/client/v3/rooms/{roomId}/event/{eventId}`, and the
   sender's `m.room.member` state for their name.
3. If the event is `m.room.encrypted`: find its `session_id` in
   `box_inbound_group_session`, check the session's room matches, and
   decrypt with `packages/loaf_push` — a Rust staticlib wrapping vodozemac
   behind a C ABI: unpickle with the user id's pickle key, decrypt the
   Megolm message, return the plaintext JSON.
4. Evaluate the account's push rules (fetched with the event, cached in the
   App Group for an hour) against the decrypted event. If they say don't
   notify, deliver nothing (filtering entitlement).
5. Set title and body as on desktop, `threadIdentifier` = room id,
   `userInfo` = the route, and the sound `chime.caf`.

Fallbacks: no room key on this device yet → `Encrypted message` from the
sender in the room. Token expired, missing, or the fetch fails →
`New message` in the room (from `names.json`). The extension never
refreshes the token. If the extension runs out of time, iOS shows whatever
alert the gateway sent.

**Filtering entitlement.** `com.apple.developer.usernotifications.filtering`
lets the extension drop a push. Encrypted rooms need it: the server can't
read an encrypted message, so it can't tell a mention from anything else.
With the entitlement, the default push rule for encrypted messages is left
at notify, and the extension applies the real rules after decrypting. Chris
requests the entitlement from Apple. Until it's granted, the extension
can't drop pushes, so the app sets `.m.rule.encrypted` to match the
Channels default, and in mentions-only encrypted rooms mentions don't push.
One build setting switches between the two.

**In the app.** `willPresent` returns no presentation options: in front,
the notifier and chime handle it. `didReceive` hands the route to Dart; on a
cold start it is held until the shell is up. When a room becomes read,
delivered notifications whose `threadIdentifier` is that room are removed.

**Signing.** The extension target, the App Group, Push Notifications and
(once granted) the filtering entitlement are provisioned by the existing
automatic signing in `release.yml`. A real tag confirms it.

## Settings

A Notifications section beside Account, Appearance, Devices and About.

**On this device** (stored locally, and in the App Group on iOS):

- Notifications — on/off. On iOS, off removes this device's pusher.
- Sound — the chime, in-app and on notifications.
- Show message text — off gives `New message from <sender>`.
- When the OS blocks notifications for Loaf Chat: a line saying so and
  `Open System Settings` (macOS, iOS, Windows). On Linux there's no such
  state to read, so no line.

**Everywhere you're signed in** (push rules):

- Channels: All messages / Mentions only — the default
  (`.m.rule.message`, and `.m.rule.encrypted` per the filtering
  entitlement above).
- Direct messages: always notify. Shown, not configurable.

A channel's mute in its menu stays as it is and overrides the default.

## Build order

Each step ships on its own and gets its own plan.

1. **A — unread state.** Client-side counts, bold and badges, space pip,
   gaps, start and resume.
2. **B — jump to message.**
3. **C + notifier — the chime.** The notifier, `tool/chime`, the players,
   the Sound setting.
4. **D — desktop notifications.** macOS, Windows, Linux, the rest of
   Settings.
5. **E — iOS push.** Database move, pusher, `loaf_push`, the extension,
   filtering.

## Testing

- **Unread**: unit tests over the SDK's fake client — receipt positions,
  mentions by `m.mentions`, `@room` power, body fallback, muted rooms still
  bold, a limited sync filled from `/messages` with the 99 cap, counts on a
  relaunch from a saved database.
- **Notifier**: the decision table above, with the push-rule evaluator and
  lifecycle faked; the backlog on launch notifies nothing.
- **Jump**: a widget test opening a route to an old event, scrolled and
  highlighted, then scrolled forward to live.
- **Desktop**: notice text; the Linux D-Bus calls against a fake portal and
  a fake notification server (as the Flatpak updater is tested); a Rust
  test for the toast XML. macOS and Windows by hand.
- **iOS format pin**: a Dart test writes a real SDK database with a room
  key and a message encrypted under it; a Rust test in `loaf_push` reads
  that fixture's pickle and decrypts the message. If the SDK changes its
  storage, this fails before a phone does.
- **iOS end to end**: on TestFlight, by hand — encrypted DM, mention in a
  mentions-only encrypted room, tap to the message, a cold start.
