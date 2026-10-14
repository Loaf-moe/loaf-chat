# Loaf Chat — Notifications audit

An inventory of everything that decides whether a message reaches you,
and how: the triggers, the push rules, the levels and settings, the
runtime state, and each platform's delivery. Which test suite pins which
part, the defects the suites confirmed, and a checklist for a Windows
user, since no developer has a Windows machine and CI runs no Windows
job. Checked against source on 2026-10-13.

Design: `2026-10-06-notifications-design.md`. Levels:
`../plans/2026-10-13-notification-levels.md`. iOS push (the design's step
E) is not built; nothing below covers it.

## Pipeline

```
sync ─▶ SDK Client ─▶ MatrixArrivals ─▶ MatrixRooms.arrivals ─▶ Notifier
                                                                  │
                      ┌───────────────────────────────────────────┤
                      ▼                                           ▼
                    chime                 Noticer ─▶ DesktopNotifications ─▶ OS
```

- `lib/matrix/matrix_arrivals.dart` turns the SDK's timeline events into
  `Arrival`s, applying the gates below.
- `lib/ui/shell/notifier.dart` decides: nothing, the chime, a desktop
  notification, or (a phone in the background) nothing in-app.
- `lib/ui/shell/noticer.dart` builds the notice (`lib/ui/model/notice.dart`),
  shows it, and withdraws a room's notices once your receipt, on any
  device, covers their messages, or the room is gone.
- `lib/notify/` holds one `DesktopNotifications` adapter per platform;
  `lib/notify/pick_notifications.dart` picks it and wraps its clicks in
  `fronted`, which brings the window forward and feeds `AppShell.routes`.
  The shell opens the channel at the message.

## Triggers

`MatrixArrivals` drops an event when any of these holds, in this order:

1. `client.prevBatch == null`: the sign-in's first sync is history.
2. The client does not hold the room as joined.
3. You sent it.
4. `origin_server_ts` is before the moment the rooms opened.
5. It is not something the timeline shows (`countsAsMessage` in
   `lib/matrix/unread_rules.dart`): redactions, edits, reactions and state
   are out; messages, stickers and still-encrypted events are in.
6. The push rules say not to notify.
7. The room was joined this session and the event is from before the join.

The push rules are the server's `m.push_rules` account data, evaluated
by the SDK's `PushruleEvaluator`, once the room's members are loaded:
your display name is read from your member event, loaded first, and
`room_member_count` is decided against the server's count in the room
summary. The evaluator is handed the rules as the spec and Synapse apply
them (`lib/matrix/push_rules.dart`): content rules ahead of room rules,
for a message carrying `m.mentions` no legacy body-mention rules, and
member-count conditions already decided. A message still sealed when
judged is judged again once its key arrives.

## Levels and settings

**Per room**, a push rule keyed by the room id, synced to every device:

| Level | Rule | Mentions |
|---|---|---|
| all messages | none | reach you |
| mentions only | `room` kind, no actions | reach you |
| mute | `override` kind, `event_match room_id`, no actions | silenced |

User rules rank above the server's defaults except `.m.rule.master`, so a
mute outranks the mention rules. Loaf reads and writes these through the
SDK's `PushRuleState`; the channel menu offers the two levels a channel
is not at.

**Account wide**: the channel default is `.m.rule.message` and
`.m.rule.encrypted` enabled (all messages) or disabled (mentions only);
direct messages keep notifying through `.m.rule.room_one_to_one` and
`.m.rule.encrypted_room_one_to_one`. Do not disturb is `.m.rule.master`,
chosen as a presence (`lib/matrix/matrix_profile.dart`).

**On this device** (`notifications.json` in the support directory,
`lib/ui/settings/notification_settings.dart`), all default on:

- sound: the chime, in the app and on a notification;
- notifications: desktop notifications while the app is not in front,
  and whether the desktop is prepared when the shell opens;
- show message text: off, a notification says only who wrote.

**Runtime state** the decision reads: whether the app is resumed (the
same test the channel view uses before it marks anything read); which
channel's messages are on screen; whether the platform is a desktop; and
on macOS and Windows whether the OS blocks notifications, which Settings
shows.

| App state | Event's channel | Result |
|---|---|---|
| In front | Open | Nothing; the channel view marks it read |
| In front | Other | The chime, if sound is on |
| Desktop, not in front | Any | A notification, if notifications are on |
| Phone, not in front | Any | Nothing in-app |

One sound a second, shared by chimes and notifications: a burst sounds
once.

## Delivery

| Platform | Adapter | Chosen when |
|---|---|---|
| macOS | `ChannelDesktopNotifications` | `TargetPlatform.macOS` |
| Windows | `WindowsDesktopNotifications` | `TargetPlatform.windows` |
| Linux, Flatpak | `PortalNotifications` | `FLATPAK_ID` set |
| Linux | `FdoNotifications` | otherwise |
| iOS, Android, mock backend | none | |

With no adapter the shell builds no `Noticer`, the routes stream is null,
and Settings hides the desktop toggles.

Every adapter follows the port's contract: nothing throws, a failure is
logged once per adapter per run, the chime still plays where the
platform could not sound it.

**macOS**: a method channel (`moe.loaf.chat/notify`) to
`macos/Runner/NotifyBridge.swift`, which uses `UNUserNotificationCenter`
with the bundled chime as the sound, donates an `INSendMessageIntent` for
the sender's picture, holds clicks until Dart says `ready`, and reports
`blocked` from the authorization status.

**Windows**: `lib/notify/windows_notifications.dart` over `ToastApi`,
whose real implementation is `packages/loaf_notify` (Dart `@Native`
bindings to a Rust DLL driving WinRT `ToastNotificationManager`). The
toast is silent (an unpackaged app cannot give it a sound) and the app
plays the chime. `prepare()` registers the AUMID under
`HKCU\Software\Classes\AppUserModelId\moe.loaf.chat`. Clicks arrive
through the toast's `Activated` event in the running process. Rust
errors go to stderr; Dart failures to `Logs().w`.

**Linux, Flatpak**: `org.freedesktop.portal.Notification` over D-Bus:
`AddNotification` per message, id `room:<room>:<event>`, a default action
carrying the route, `RemoveNotification` to withdraw. The portal is told
to stay silent and the app plays the chime. `blocked` is always false.

**Linux**: `org.freedesktop.Notifications`: `Notify` with the
`desktop-entry` hint, `sound-file` where the server supports sound (else
the app plays the chime), a `default` action, `CloseNotification` to
withdraw. `blocked` is always false.

**Chime**: `lib/ui/model/chime.dart` over `loaf_media`'s method channel:
`PlaySound` on Windows, GStreamer on Linux, System Sound Services on
macOS and iOS.

## Coverage

| Behaviour | Suite | Tests |
|---|---|---|
| Gates 1–5 and 7, arrival contents, members loaded or refused | `test/matrix/matrix_arrivals_test.dart` | 19 |
| Gate 6 against the full default ruleset: account level × room level × room kind × 8 mention shapes; the same through encryption; events the defaults silence | `test/matrix/matrix_arrivals_rules_test.dart` | 245 |
| The decision and the device settings, from sync to chime or notice, through the real shell: in front × open channel × platform × sound × notifications × text; bursts; preparing the desktop | `test/app_shell_arrivals_test.dart` | 69 |
| A click opening the channel at the message; withdrawal on reading here, on another device's receipt, on leaving | `test/app_shell_notices_test.dart` | 7 |
| Levels: reading each rule shape, the six transitions and the calls they send, the account default's writes and rollback, the menu and the row icon | `test/matrix/matrix_rooms_test.dart`, `test/matrix/matrix_profile_test.dart`, `test/mock_rooms_test.dart`, `test/app_shell_test.dart`, `test/notifications_section_test.dart` | 30 |
| Each adapter against a fake bus, channel or toast API | `test/notify/*_test.dart` | 41 |
| The decision table and throttle in isolation; notice text; settings storage | `test/notifier_test.dart`, `test/notice_test.dart`, `test/noticer_test.dart`, `test/notification_settings_test.dart` | 40 |

The two shell suites run a real client, real rooms and the real shell
per case, with fakes only at the chime and the desktop. They add about
two and a half minutes to the Flutter lane. `test/shell_harness.dart`
holds their rig, and documents what a widget test over the SDK needs:
client work under `runAsync`, bounded pumps in place of `pumpAndSettle`,
no closing of the in-memory database.

Not covered by any test here: the Windows native path (`notifier.rs`,
`ffi.rs`, the `@Native` bindings, the DLL's presence in an install, the
runner's focus reporting); `NotifyBridge.swift`; the chime players'
playback.

## Findings

Every finding below was confirmed by cases in
`test/matrix/matrix_arrivals_rules_test.dart` before its fix.

**F1. A direct message was silent under "mentions only".** Fixed:
`PushRules` decides every `room_member_count` condition against the
server's own count in the room summary, so the members in memory never
matter to it. The only member the rules read is yours, for your name,
loaded once from memory, the store or the server. A room whose summary
has no count gets its whole list loaded instead, as the evaluator then
counts memory; a load the server refuses is logged, the rules run on
what is known, and the next message asks again.

**F2. Mute silenced mentions while its text promised mentions-only.**
Fixed: three levels, per room and account wide.

**F3. A message read late never notified.** Fixed: a message still
sealed when judged is kept, by room and session, and judged again when
`Room.onSessionKeyReceived` brings its key, as the unread store already
did for its counts. It arrives again as what it says; the notifier
sounds no second time, and the notice, keyed by room and event on every
platform, is replaced. One noticed while sealed whose text turns out not
to notify (a bot notice, an edit, a room since left) has its notice
taken back: by the one message on macOS and Linux, by the room on
Windows, whose native side does not expose a toast by tag yet.

**F4. A mentions-only room silenced your localpart.** The SDK checks room
rules before content rules; the spec says content first. Fixed: Loaf
hands the evaluator the content rules as overrides, at the end, where
they come before room rules.

**F5. A legacy name mention was unseen in a room nobody has opened.**
Fixed with F1: your member event is among the members loaded.

**F6. The SDK applied the legacy body rules beside `m.mentions`.** A
message carrying `m.mentions` (present, whatever its shape) decides by it
alone: Synapse
skips `.m.rule.contains_display_name`, `.m.rule.contains_user_name` and
`.m.rule.roomnotif` for such a message, and so does Loaf's unread count.
Fixed: such a message is judged by a ruleset without the three.

**Windows, unconfirmed.** No test here can run the native path; these are
from reading it. Each adapter logs one failure per run, so the second
problem is never seen. `blocked()` reads a failed call as not blocked, so
Settings never shows the "blocking" line on a machine where the call
itself fails. The AUMID is registered only from `prepare()`, which runs
when the shell opens with notifications on, or when the toggle is turned
on. An installed build has no console (`windows/runner/main.cpp` attaches
one only to a parent console or a debugger) and there is no file log, so
every failure is invisible to a user. `tool/release/windows-smoke.sh`
checks four files of the install and not `loaf_notify_win.dll`.

## Windows: a checklist for a user

In this order; each step says what to send back.

1. Open the install folder (where `loaf-chat.exe` is). Is
   `loaf_notify_win.dll` there? Send yes or no.
2. Quit Loaf Chat. Open Command Prompt, type the full path of
   `loaf-chat.exe` and press Enter. The log now shows in that window.
   Have someone message you with the window not in front. Copy every
   line that starts with `[loaf]` or `[loaf notify]`.
3. In Loaf Chat, Settings, Notifications: is "notifications" on? Turn it
   off and on again. Does a line say windows is blocking notifications?
4. Windows Settings, System, Notifications: is Loaf Chat in the list, and
   on? Is do not disturb (focus assist) off?
5. Press Win+R, type `regedit`, and look for
   `HKEY_CURRENT_USER\Software\Classes\AppUserModelId\moe.loaf.chat`. Does
   it exist, with `DisplayName` and `IconUri`?
6. Put another window in front and have someone message you. Did you
   hear the chime? Did a toast show? Send both answers.
7. With Loaf Chat in front and a different channel open, have someone
   message you. Did you hear the chime?

## Where the design spec and the code differ

- The account default (Channels: all messages / mentions only) exists
  now; the spec's Settings section describes it.
- iOS push (step E) is not built: a phone in the background gets nothing.
- Spec v1.17 removed the legacy body-mention default rules
  (`contains_display_name`, `contains_user_name`, `roomnotif`); Synapse
  still serves them, and skips them for events with `m.mentions`. Loaf's
  tests model Synapse.
- The SDK's rule-kind order differs from the spec; Loaf compensates (F4).
