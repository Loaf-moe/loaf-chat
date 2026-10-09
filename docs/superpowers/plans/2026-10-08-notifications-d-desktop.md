# Notifications D: Desktop Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a message the push rules say should notify arrives while Loaf Chat isn't in front on macOS, Windows or Linux, show a native notification. It names the sender and the channel, and shows the message text, or a stand-in when Show message text is off. Clicking it brings the window forward and opens the message. Notifications are withdrawn once the room is read on any device. Settings gets the Notifications and Show message text toggles, plus the OS-blocked line.

**Architecture:**
- **The decision stays in the C-step `Notifier`.** Its `desktopNotice` branch hands the arrival, and whether it may sound, to a new `Noticer`. The `Noticer` builds a `Notice`, shows it through a `DesktopNotifications` and withdraws a room's notices once that room has been seen unread and is then read.
- **`Arrival` carries what a notice needs.** That is the sender, their avatar, the text and the message kind, read by `MatrixArrivals` off the decrypted event.
- **There are three `DesktopNotifications` implementations:**
  - one Dart class over the method channel `moe.loaf.chat/notify`. Its native ends are Swift in the macOS Runner (`UNUserNotificationCenter`, with each message donated as an incoming `INSendMessageIntent` so it shows as a communication notification carrying the sender's picture), and a new Windows-only plugin, `packages/loaf_notify`, whose Rust crate drives `ToastNotificationManager`;
  - Dart over D-Bus to `org.freedesktop.portal.Notification` inside Flatpak;
  - Dart over D-Bus to `org.freedesktop.Notifications` outside Flatpak.
- **Part 0, first, on its own branch:** it caps the catch-up that writes do from back in history.

**Tech Stack:**
- Flutter/Dart: the `matrix` 13.0.0 SDK, `dbus` 0.8, `dart:ffi` with `package:ffi`, and `window_to_front`.
- Swift: UserNotifications and Intents.
- Rust: `windows` 0.62, WinRT `UI_Notifications`.
- C++: the Flutter Windows plugin glue.

**Spec:** `docs/superpowers/specs/2026-10-06-notifications-design.md`. The binding sections are "D. Desktop notifications", "Notifier" and "Settings" (the parts for "on this device").

## Global Constraints

- **Decisions Chris made on 2026-10-08:**
  - **Catch-up past the cap stays in place.** A write from back in history pages forward at most `catchUpPages` (10 pages of 50) and then stops. The write has already gone, and its result shows once you scroll down to live.
  - **macOS uses real communication notifications.** Each notice is donated as an incoming `INSendMessageIntent`, so macOS draws the sender's picture.
    - This needs `com.apple.developer.usernotifications.communication`, which a Developer ID app may hold only with an embedded Developer ID provisioning profile. Apple's capability table ticks Communication Notifications for Developer ID.
    - **Debug and Profile builds carry it too** (Chris, 2026-10-08: "Why not also on debug builds?"). Those two configs move from ad hoc signing (`CODE_SIGN_IDENTITY = "-"`) to automatic signing as Apple Development with `DEVELOPMENT_TEAM = 6W2A5N37N3`. That lets Xcode make a development profile with the entitlement, and `DebugProfile.entitlements` gets the key.
      - This Mac has the `Apple Development: me@cthomas.dev` identity and an Xcode account.
      - The Release config is **not** touched. CI's `flutter build macos --release` has no Apple account. There, `tool/release/macos.sh` adds the entitlement at re-signing, and only when the profile secret is present. `Release.entitlements` never gets it.
    - Without the entitlement, the donation or `updating(from:)` fails, and the plain notification still shows.
- **`DesktopNotifications`** carries the spec's three members, `show`, `withdraw` and `clicks`, plus `prepare`, `blocked` and `openSystemSettings` for "Settings". None of them throws: failures are logged once and swallowed, the same rule `Chime` follows.
- **A `Notice`** holds:
  - `route`;
  - `sender`, the display name, falling back to the user id;
  - `senderId`;
  - `place`: `#<channel> · <Space>` in a space, `#<room>` for a non-DM in Home, and null in a DM;
  - `body`;
  - `avatarPath`;
  - `sound`.
  
  `title` is `sender` in a DM, and `'$sender in $place'` otherwise.
- **Copy is lowercase**, matching the app's voice (C plan, "Settings copy"). Use these strings verbatim:
  - Body when Show message text is off, or the text is empty: `new message`
  - Picture or sticker: `sent a picture`
  - `m.file`, `m.video` or `m.audio`: `sent a file`
  - An event that is still `m.room.encrypted` (no key): `encrypted message`
  - Message text is trimmed, then cut at **400** characters with a trailing `…`. Windows rejects toast XML over 5 KB.
  - Settings, `notifications`: `a notification when loaf chat isn't in front.`
  - Settings, `show message text`: `off, a notification says only who wrote.`
  - Settings, `sound` detail on desktop: `a soft chime for messages in other channels, and on notifications.` On phones it stays as it is.
  - The OS-blocked line: `macos is blocking notifications from loaf chat.` or `windows is blocking notifications from loaf chat.`, with a `LoafButton` reading `open system settings`.
- **Notifications and Show message text** are shown only on desktop (`isDesktop`) in step D. On a phone they would do nothing until step E, and a control that does nothing breaks memory `honest-controls`.
- **Sound.** A notice sounds only when Sound is on and no chime or notice has sounded in the last second: the Notifier's one throttle covers both. Where the platform can't attach the chime, the app plays it itself:
  - Windows (an unpackaged app can't give a toast a custom sound);
  - portal version 1;
  - an `org.freedesktop.Notifications` server without the `sound` capability.
- **Ids.**
  - Windows: the AUMID is `moe.loaf.chat`. It is already set on the process (`windows/runner/main.cpp`) and on the installer's shortcut. Register it under `HKCU\Software\Classes\AppUserModelId\moe.loaf.chat`.
  - Linux: the desktop entry and icon are `moe.loaf.chat`.
  - macOS: the bundle id is `moe.loaf.chat.ios`, for every build: the same App ID as iOS, after Task 8b. It was `moe.loaf.native`. The team is `6W2A5N37N3`.
- **Portal facts, checked in xdg-desktop-portal's `desktop-portal/notification.c` on 2026-10-08:**
  - `version` is `min(backend version, 2)`.
  - `sound` is dropped when the backend's version is 1, and must be `('file-descriptor', h)` on a **sealable memfd**.
  - A `('bytes', ay)` icon is still accepted: the portal seals it itself.
  - Actions whose names start with `app.` go through D-Bus activation instead of `ActionInvoked`, so the default action is `open`.
- **Native first (memory `native-first`).** No local servers, no shelling out, and no notification packages from pub. Each platform uses its own API.
- **Rust:** edition 2024, `rust-version = "1.92"`, and no `.unwrap()`, `.expect()` or `panic!` outside tests. Every FFI entry point goes through `catch_unwind`, as `loaf_media_win`'s `ffi.rs` does.
  - Check every `windows` 0.62 signature before you write it: `TypedEventHandler` closures take `windows_core::Ref<…>` arguments in 0.6x. Use `rustdoc-mcp-server` or `rust-analyzer-mcp` if available, otherwise docs.rs for `windows` 0.62.
  - Check with `cargo check --target x86_64-pc-windows-msvc` and `cargo clippy --target x86_64-pc-windows-msvc -- -D warnings`, with `PATH=~/.rustup/toolchains/1.96.1-aarch64-apple-darwin/bin:$PATH`, because Homebrew's rustc lacks that std.
- **Checks:**
  - `mise exec -- flutter test`: baseline **1597**. Add the new tests to that count.
  - `mise exec -- flutter analyze` and `mise exec -- dart format lib test packages`.
  - `cargo test --locked` in each touched crate.
  - Encryption tests need `build/vodozemac/libflutter_vodozemac.dylib`. Copy it into each new worktree, and run `mise trust` there.
- **Branches.**
  - Part 0 is done in `.claude/worktrees/catch-up-cap` on `fix/catch-up-cap`, and merged to `main` before Part D starts.
  - Part D is done in `.claude/worktrees/desktop-notices` on `feat/desktop-notices`, branched off `main` **after** Part 0 merges. Rebase onto `main` if this plan's commit sits on an older base.
  - Never stage `tmpl_plugin/`. Run `git branch --show-current` before every commit.
- **Commits:** follow the repo's style (`fix(timeline): …`, `feat(notify): …`), and end each one with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Out of scope:**
  - iOS push (E).
  - Tagging the Linux chime stream `media.role=event`. That's a C-player change, to go on its own branch if wanted.
  - Raising the window with a Wayland activation token. `window_to_front` uses `gtk_window_present`; the spec names `window_to_front`.
  - Clearing notifications at sign-out.

## Review Focus

1. **A notice withdrawn the moment it shows.** The room's unread count can lag behind the arrival within one sync. If it reads 0 when the rooms next notify, a naive "withdraw read rooms" deletes the notice it just showed. A room's notices are withdrawn only after the `Noticer` has **seen it unread** (at show time or later) and then seen it read. Test: Task 4, "a notice is not withdrawn before its room was seen unread".
2. **Markup in a message on Linux.** `org.freedesktop.Notifications` servers with `body-markup` parse the body as markup. A message reading `<b>hi</b> & co` must show those characters literally, not bold, and must not break the notification. The body is escaped exactly when the server says `body-markup`. Test: Task 6, "the body is escaped for a markup server".
3. **A very long message.** A 10,000-character paste must still notify: cut to 400 characters plus `…`. Above about 5 KB of toast XML, Windows silently shows nothing. Tests: Task 2, "a long message is cut at 400 characters", and Task 10's Rust test "a long body still makes a toast under 5 KB".
4. **A message with no key yet.** An encrypted message the SDK couldn't decrypt reaches `MatrixArrivals` still `m.room.encrypted`. Its body must read `encrypted message`, not the SDK's English "could not decrypt" text or the ciphertext. Test: Task 3, "an undecryptable message reads as encrypted".
5. **A click that comes before anyone is listening.** On macOS, a click on a notice left from the last run launches the app, and the click arrives before Dart is up. It must be held and delivered once the shell listens, and then the shell holds it until the first sync, as step B already does. Dart says `ready` when `clicks` gets its first listener. Test: Task 8, "the first listener says ready, and only then are held clicks wanted". The Swift side is in Task 9's hand test.

---

## File Structure

| File | Responsibility |
|---|---|
| **Part 0** | |
| `lib/matrix/matrix_timeline.dart` | `catchUpPages`, and the capped `_catchUp` |
| `lib/ui/channel/message_group_tile.dart` | Drop the doubled `if (focusKey != null)` |
| `test/matrix/matrix_timeline_jump_test.dart` | Cap tests |
| **Part D, Dart** | |
| `lib/ui/settings/notification_settings.dart` | `notifications` and `showText` fields, value equality, and `NotificationController.desktop` |
| `lib/ui/model/arrival.dart` | `ArrivalKind`, and sender and text fields on `Arrival` |
| `lib/ui/model/notice.dart` | `Notice`, `noticeFor`, `noticePlace`, `noticeBody` |
| `lib/ui/model/desktop_notifications.dart` | The `DesktopNotifications` interface, and `FakeDesktopNotifications` |
| `lib/matrix/matrix_arrivals.dart` | Fills the new `Arrival` fields from the event |
| `lib/ui/rooms/rooms.dart`, `lib/matrix/matrix_rooms.dart`, `lib/ui/mock/mock_rooms.dart` and the two test `_FakeRooms` | `Future<String?> noticeAvatar(AvatarRef ref)` |
| `lib/ui/shell/noticer.dart` | Shows notices, and withdraws read rooms' notices |
| `lib/ui/shell/notifier.dart` | The `desktopNotice` branch, and one sound throttle |
| `lib/ui/shell/app_shell.dart` | Owns the `Noticer`, and calls `prepare` |
| `lib/ui/settings/notifications_section.dart` | The new toggles, and the blocked line |
| `lib/notify/channel_notifications.dart` | macOS and Windows, over `moe.loaf.chat/notify` |
| `lib/notify/fdo_notifications.dart` | `org.freedesktop.Notifications` |
| `lib/notify/portal_notifications.dart` | `org.freedesktop.portal.Notification` |
| `lib/notify/memfd.dart` | A sealable memfd copy of a file (Linux, `dart:ffi`) |
| `lib/notify/pick_notifications.dart` | Picks the implementation; `bundledChime`; `fronted` |
| `lib/main.dart`, `lib/ui/auth/session_root.dart` | Wiring, and `routes:` |
| **Part D, native** | |
| `macos/Runner/NotifyBridge.swift`, `MainFlutterWindow.swift`, `Info.plist`, `Runner.xcodeproj/project.pbxproj` | The macOS end, and `chime.wav` in the bundle |
| `tool/release/macos.sh`, `.github/workflows/release.yml` | The profile and the communication entitlement at signing |
| `packages/loaf_notify/…` | A Windows-only plugin: the C++ glue and the Rust crate `loaf_notify_win` |
| `pubspec.yaml` | `loaf_notify`, `ffi`, and the `linux/packaging/moe.loaf.chat.png` asset (the Windows AUMID icon) |
| `.github/workflows/ci.yml` | One line: `cargo test` for `loaf_notify_win` in the Linux job |

---

## Part 0: the catch-up cap (branch `fix/catch-up-cap`)

### Task 0: Cap the catch-up, and drop the doubled `if`

**Files:**
- Modify: `lib/matrix/matrix_timeline.dart` (`_catchUp`, around line 773; add the constant beside `historyPage` at line 29)
- Modify: `lib/ui/channel/message_group_tile.dart:747-748`
- Test: `test/matrix/matrix_timeline_jump_test.dart`

**Interfaces:**
- Produces: `const catchUpPages = 10;` (public, so the test can name it).

- [ ] **Step 1: Make the worktree.** In Nushell:

```nu
cd /Users/faore/code/loaf-native
git fetch origin
git worktree add -b fix/catch-up-cap .claude/worktrees/catch-up-cap origin/main
cd .claude/worktrees/catch-up-cap
mkdir build/vodozemac
cp ../../../build/vodozemac/libflutter_vodozemac.dylib build/vodozemac/
mise trust
```

- [ ] **Step 2: Write the failing tests.** Add them to `test/matrix/matrix_timeline_jump_test.dart`, after "deleting a message from back in history removes it":

```dart
  test('a write from far back stops paging at the cap and stays put', () async {
    final h = await _open();
    h.api.contexts[r'$old'] = _context(r'$old', 'the old one');
    // More pages than the cap, none of them live.
    for (var i = 0; i < catchUpPages + 2; i++) {
      h.api.forward.add(_page([_text('later $i')]));
    }
    h.timeline.jumpTo(r'$old');
    await _until(() => h.timeline.jumpTarget != null);

    h.timeline.delete(r'$old');
    await _until(
      () => h.api.redacted.isNotEmpty && h.api.forwardAsked == catchUpPages,
    );
    await _settle();
    expect(h.api.redacted, [r'$old']);
    expect(h.api.forwardAsked, catchUpPages);
    expect(h.timeline.canLoadNewer, isTrue);
    // Still where you were: the jumped-to message is loaded.
    expect(h.bodies, contains('the old one'));

    // Scrolling down still pages on from there.
    h.timeline.loadNewer();
    await _until(() => !h.timeline.loadingNewer);
    expect(h.api.forwardAsked, catchUpPages + 1);
  });

  test('a reaction from far back is sent once the cap is reached', () async {
    final h = await _open();
    h.api.contexts[r'$old'] = _context(r'$old', 'the old one');
    for (var i = 0; i < catchUpPages + 2; i++) {
      h.api.forward.add(_page([_text('later $i')]));
    }
    h.timeline.jumpTo(r'$old');
    await _until(() => h.timeline.jumpTarget != null);

    h.timeline.toggleReaction(r'$old', '👍');
    await _until(() => h.api.sent.isNotEmpty);
    expect(h.api.sent, ['m.reaction']);
    expect(h.api.forwardAsked, catchUpPages);
  });
```

- [ ] **Step 3: Run them to watch them fail.**

Run: `mise exec -- flutter test test/matrix/matrix_timeline_jump_test.dart`
Expected: a compile error, because `catchUpPages` isn't defined.

- [ ] **Step 4: Implement the cap.** In `lib/matrix/matrix_timeline.dart`, below `const historyPage = 50;`:

```dart
/// How far a write from back in history pages forward before it stops: 500
/// events. Past that you stay where you are; the write has gone either way,
/// and its result shows once you scroll down to the live end.
const catchUpPages = 10;
```

Then replace `_catchUp`, keeping its doc comment and adding one sentence to it:

```dart
  /// Pages forward to the live end, so a reaction, edit or deletion lands
  /// in a timeline that hears it, without losing your place. Stops at a
  /// failed page, or one that moved the forward token nowhere: the write has
  /// gone either way, and scrolling down tries again. Events are no measure
  /// of a page: one of only reactions adds none to the list. Stops, too,
  /// after [catchUpPages], so a jump years back doesn't page through them.
  Future<void> _catchUp() async {
    for (var page = 0; page < catchUpPages; page++) {
      if (_disposed || !canLoadNewer) return;
      final before = _timeline?.chunk.nextBatch;
      await _pageNewer();
      if (_newerFailed || _timeline?.chunk.nextBatch == before) return;
    }
  }
```

In `lib/ui/channel/message_group_tile.dart`, delete line 748, the second `if (focusKey != null)`.

- [ ] **Step 5: Run the tests to see them pass.**

Run: `mise exec -- flutter test test/matrix/matrix_timeline_jump_test.dart test/channel_jump_test.dart`
Expected: PASS.

Then run the whole suite: `mise exec -- flutter test`. Expected: **1599** pass, which is the baseline plus 2. Also run `mise exec -- flutter analyze`.

- [ ] **Step 6: Commit.**

```nu
git branch --show-current   # fix/catch-up-cap
git add lib/matrix/matrix_timeline.dart lib/ui/channel/message_group_tile.dart test/matrix/matrix_timeline_jump_test.dart
git commit -m "fix(timeline): a write from far back pages forward at most ten pages

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 7 (controller): merge into `main`.** Follow the approved process. Make the merge commit on top of `origin/main`, run the full suite on the merged tree, then push `main`. There is no release for this fix on its own: it ships with D. Then rebase `feat/desktop-notices` onto the new `main`.

---

## Part D: desktop notifications (branch `feat/desktop-notices`)

### Task 1: The Notifications and Show message text settings

**Files:**
- Modify: `lib/ui/settings/notification_settings.dart`
- Test: `test/notification_settings_test.dart`

**Interfaces:**
- Consumes: `DesktopNotifications` from Task 2. **Do Task 2's Step 3 (the interface file) first if you are working out of order.** Otherwise add the `desktop` field in Task 2.
- Produces:
  - `NotificationSettings({bool sound = true, bool notifications = true, bool showText = true})`, with `==`/`hashCode`. JSON keys: `sound`, `notifications`, `showText`.
  - On `NotificationController`: `bool get notifications`, `bool get showText`, `void setNotifications(bool)` and `void setShowText(bool)`.

- [ ] **Step 1: Write the failing tests.** Add them to `test/notification_settings_test.dart`:

```dart
  test('notifications and message text are on unless turned off', () {
    const s = NotificationSettings();
    expect(s.notifications, isTrue);
    expect(s.showText, isTrue);
    expect(NotificationSettings.fromJson(const {'sound': false}).notifications, isTrue);
    final off = NotificationSettings.fromJson(const {
      'notifications': false,
      'showText': false,
    });
    expect(off.notifications, isFalse);
    expect(off.showText, isFalse);
    expect(off.sound, isTrue);
  });

  test('every field round-trips through the file store', () async {
    final dir = Directory.systemTemp.createTempSync('loaf-notify-settings');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = FileNotificationStore(File('${dir.path}/notifications.json'));
    const saved = NotificationSettings(
      sound: false,
      notifications: false,
      showText: false,
    );
    await store.save(saved);
    expect(await store.load(), saved);
  });

  test('turning notifications or message text off notifies and saves', () async {
    final store = MemoryNotificationStore();
    final c = NotificationController(store: store, chime: FakeChime());
    var heard = 0;
    c.addListener(() => heard++);
    c.setNotifications(false);
    c.setShowText(false);
    await pumpEventQueue();
    expect(heard, 2);
    expect(c.notifications, isFalse);
    expect(c.showText, isFalse);
    expect(store.saved, const NotificationSettings(notifications: false, showText: false));
    c.setShowText(false);
    expect(heard, 2, reason: 'the same value again is no change');
  });
```

Add `import 'dart:io';` if the file doesn't already import it.

- [ ] **Step 2: Run them to watch them fail.**

Run: `mise exec -- flutter test test/notification_settings_test.dart`
Expected: a compile error: no `notifications`/`showText`.

- [ ] **Step 3: Implement.** Replace `NotificationSettings` and update the controller:

```dart
@immutable
class NotificationSettings {
  const NotificationSettings({
    this.sound = true,
    this.notifications = true,
    this.showText = true,
  });

  /// Anything unreadable falls back to that field's default, so a
  /// hand-edited file degrades instead of failing.
  factory NotificationSettings.fromJson(Object? json) {
    if (json is! Map) return const NotificationSettings();
    bool flag(String key) => switch (json[key]) {
      final bool on => on,
      _ => true,
    };
    return NotificationSettings(
      sound: flag('sound'),
      notifications: flag('notifications'),
      showText: flag('showText'),
    );
  }

  /// The chime, in the app and on notifications.
  final bool sound;

  /// Desktop notifications while the app isn't in front.
  final bool notifications;

  /// Off, a notification says who wrote but not what.
  final bool showText;

  NotificationSettings copyWith({
    bool? sound,
    bool? notifications,
    bool? showText,
  }) => NotificationSettings(
    sound: sound ?? this.sound,
    notifications: notifications ?? this.notifications,
    showText: showText ?? this.showText,
  );

  Map<String, Object> toJson() => {
    'sound': sound,
    'notifications': notifications,
    'showText': showText,
  };

  @override
  bool operator ==(Object other) =>
      other is NotificationSettings &&
      other.sound == sound &&
      other.notifications == notifications &&
      other.showText == showText;

  @override
  int get hashCode => Object.hash(sound, notifications, showText);
}
```

In `NotificationController`, add the following, and change `_update`'s guard from `next.sound == sound` to `next == _settings`:

```dart
  bool get notifications => _settings.notifications;
  bool get showText => _settings.showText;

  void setNotifications(bool on) =>
      _update(_settings.copyWith(notifications: on));
  void setShowText(bool on) => _update(_settings.copyWith(showText: on));
```

Update the library doc's second sentence ("For now that is one switch: the chime.") to: `The chime, desktop notifications, and how much a notification says.`

- [ ] **Step 4: Run the tests to see them pass.**

Run: `mise exec -- flutter test test/notification_settings_test.dart test/notifications_section_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit.**

```nu
git branch --show-current   # feat/desktop-notices
git add lib/ui/settings/notification_settings.dart test/notification_settings_test.dart
git commit -m "feat(notify): Notifications and Show message text settings

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 2: `Arrival`'s content, `Notice`, and the `DesktopNotifications` interface

**Files:**
- Modify: `lib/ui/model/arrival.dart`
- Create: `lib/ui/model/notice.dart`
- Create: `lib/ui/model/desktop_notifications.dart`
- Modify: `lib/ui/settings/notification_settings.dart` (add `desktop` to the controller)
- Test: `test/notice_test.dart`

**Interfaces:**
- Consumes: `MessageRoute` (`lib/ui/model/message_route.dart`), and `Space`, `Channel`, `ChannelKind`, `AvatarRef` (`lib/ui/model/models.dart`).
- Produces:
  - `enum ArrivalKind { text, picture, file, encrypted }`.
  - `Arrival({required String roomId, required String eventId, String senderId = '', String senderName = '', AvatarRef? senderAvatar, ArrivalKind kind = ArrivalKind.text, String text = ''})`. Equality stays on `roomId` and `eventId`.
  - `Notice`, with the fields from Global Constraints and `String get title`.
  - `const noticeTextLimit = 400`.
  - `String? noticePlace(String roomId, {required List<Space> spaces, required List<Channel> homeRooms})`.
  - `String noticeBody(Arrival a, {required bool showText})`.
  - `Notice noticeFor(Arrival a, {required List<Space> spaces, required List<Channel> homeRooms, required bool showText, bool sound = false, String? avatarPath})`.
  - The `DesktopNotifications` interface, and `FakeDesktopNotifications`, which exposes `shown`, `withdrawn`, `prepared`, `isBlocked`, `settingsOpened` and `click(MessageRoute)`.
  - `NotificationController({…, DesktopNotifications? desktop})`, and `NotificationController.load(store, chime:, desktop:)`.

- [ ] **Step 1: Write the failing tests.** Create `test/notice_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/mock/fixtures.dart';
import 'package:loaf_native/ui/mock/mock_rooms.dart';
import 'package:loaf_native/ui/model/arrival.dart';
import 'package:loaf_native/ui/model/message_route.dart';
import 'package:loaf_native/ui/model/models.dart';
import 'package:loaf_native/ui/model/notice.dart';

void main() {
  final rooms = MockRooms();
  tearDownAll(rooms.dispose);

  Channel inSpace() => rooms.spaces.first.allChannels.firstWhere(
    (c) => c.joined && c.kind == ChannelKind.text,
  );
  Channel dm() => rooms.homeRooms.firstWhere((c) => c.kind == ChannelKind.direct);

  Arrival arrival(
    String roomId, {
    String text = 'hello',
    ArrivalKind kind = ArrivalKind.text,
    String senderName = 'Ada',
  }) => Arrival(
    roomId: roomId,
    eventId: r'$e1',
    senderId: '@ada:loaf.moe',
    senderName: senderName,
    kind: kind,
    text: text,
  );

  Notice make(Arrival a, {bool showText = true}) => noticeFor(
    a,
    spaces: rooms.spaces,
    homeRooms: rooms.homeRooms,
    showText: showText,
  );

  test('a channel in a space is named with its space', () {
    final c = inSpace();
    final n = make(arrival(c.id));
    expect(n.place, '#${c.name} · ${rooms.spaces.first.name}');
    expect(n.title, 'Ada in #${c.name} · ${rooms.spaces.first.name}');
    expect(n.route, MessageRoute(c.id, r'$e1'));
  });

  test('a DM is titled with the sender alone', () {
    final n = make(arrival(dm().id));
    expect(n.place, isNull);
    expect(n.title, 'Ada');
  });

  test('an unknown room is titled with the sender alone', () {
    expect(make(arrival('!gone:x')).title, 'Ada');
  });

  test('a sender with no name is shown by id', () {
    expect(make(arrival(dm().id, senderName: '')).sender, '@ada:loaf.moe');
  });

  test('the body is the text, or what was sent', () {
    final id = dm().id;
    expect(make(arrival(id, text: '  hi there \n')).body, 'hi there');
    expect(make(arrival(id, kind: ArrivalKind.picture)).body, 'sent a picture');
    expect(make(arrival(id, kind: ArrivalKind.file)).body, 'sent a file');
    expect(make(arrival(id, kind: ArrivalKind.encrypted)).body, 'encrypted message');
    expect(make(arrival(id, text: '   ')).body, 'new message');
  });

  test('with message text off, the body says only that something came', () {
    final n = make(arrival(dm().id, text: 'secret'), showText: false);
    expect(n.body, 'new message');
    expect(n.title, 'Ada');
  });

  test('a long message is cut at 400 characters', () {
    final body = make(arrival(dm().id, text: 'x' * 10000)).body;
    expect(body.length, noticeTextLimit + 1);
    expect(body, endsWith('…'));
  });
}
```

If `MockRooms` has no DM in `homeRooms`, or no joined text channel in its first space, check `lib/ui/mock/fixtures.dart` and pick the fixture's ids. Don't add fixtures.

- [ ] **Step 2: Run them to watch them fail.**

Run: `mise exec -- flutter test test/notice_test.dart`
Expected: a compile error: `notice.dart` doesn't exist.

- [ ] **Step 3: Implement the interface.** Create `lib/ui/model/desktop_notifications.dart`:

```dart
/// The desktop's own notifications: Notification Center, toasts, the
/// freedesktop server or portal. One per app run, so a click that launched
/// the app is not lost. See `lib/notify/` for the implementations.
library;

import 'dart:async';

import 'message_route.dart';
import 'notice.dart';

/// None of these throws: a notification that can't be shown isn't worth
/// an error in front of you. Failures are logged once.
abstract interface class DesktopNotifications {
  /// Gets ready to show: on macOS asks permission if it was never asked; on
  /// Windows registers the app's name and icon. Called when the shell opens.
  Future<void> prepare();

  /// Shows [notice], sounding the chime with it when [Notice.sound] says
  /// so, through the platform where it can and the app where it can't.
  Future<void> show(Notice notice);

  /// Takes back every notification shown for [roomId].
  Future<void> withdraw(String roomId);

  /// Where clicked notifications lead.
  Stream<MessageRoute> get clicks;

  /// Whether the OS has been told to block this app's notifications. Always
  /// false where that can't be read (Linux).
  Future<bool> blocked();

  /// Opens the OS's notification settings for this app.
  Future<void> openSystemSettings();
}

/// Records calls: for tests only.
class FakeDesktopNotifications implements DesktopNotifications {
  final shown = <Notice>[];
  final withdrawn = <String>[];
  var prepared = 0;
  var isBlocked = false;
  var settingsOpened = 0;
  final _clicks = StreamController<MessageRoute>.broadcast();

  void click(MessageRoute route) => _clicks.add(route);

  @override
  Future<void> prepare() async => prepared++;

  @override
  Future<void> show(Notice notice) async => shown.add(notice);

  @override
  Future<void> withdraw(String roomId) async => withdrawn.add(roomId);

  @override
  Stream<MessageRoute> get clicks => _clicks.stream;

  @override
  Future<bool> blocked() async => isBlocked;

  @override
  Future<void> openSystemSettings() async => settingsOpened++;
}
```

- [ ] **Step 4: Implement `Arrival` and `Notice`.** Replace `lib/ui/model/arrival.dart`:

```dart
import 'package:flutter/foundation.dart';

import 'models.dart';

/// What a message is, as far as a notification says: its text, a
/// picture, a file, or something not yet decrypted.
enum ArrivalKind { text, picture, file, encrypted }

/// A new message that should notify you: which room and event, and what a
/// notification needs to say about it. The same message is the same
/// arrival, whatever was read off it.
@immutable
class Arrival {
  const Arrival({
    required this.roomId,
    required this.eventId,
    this.senderId = '',
    this.senderName = '',
    this.senderAvatar,
    this.kind = ArrivalKind.text,
    this.text = '',
  });

  final String roomId;
  final String eventId;
  final String senderId;

  /// Their display name in the room; empty when there is none.
  final String senderName;
  final AvatarRef? senderAvatar;
  final ArrivalKind kind;

  /// The message as plain text, reply quote left out. Only for
  /// [ArrivalKind.text].
  final String text;

  @override
  bool operator ==(Object other) =>
      other is Arrival && other.roomId == roomId && other.eventId == eventId;

  @override
  int get hashCode => Object.hash(roomId, eventId);

  @override
  String toString() => 'Arrival($roomId, $eventId)';
}
```

Create `lib/ui/model/notice.dart`:

```dart
/// What a desktop notification says about one message, and where clicking
/// it leads. Built from an [Arrival] and the rooms as the shell knows them.
library;

import 'package:flutter/foundation.dart';

import 'arrival.dart';
import 'message_route.dart';
import 'models.dart';

/// Past this many characters a message is cut: platforms truncate long
/// text anyway, and a Windows toast over 5 KB is silently dropped.
const noticeTextLimit = 400;

@immutable
class Notice {
  const Notice({
    required this.route,
    required this.sender,
    required this.senderId,
    required this.body,
    this.place,
    this.avatarPath,
    this.sound = false,
  });

  final MessageRoute route;
  final String sender;
  final String senderId;

  /// `#general · The Starter Pack`; `#general` for a room in Home; null in
  /// a DM, where the sender is the conversation.
  final String? place;
  final String body;

  /// The sender's picture on disk, where there is one.
  final String? avatarPath;

  /// Whether the chime goes with it.
  final bool sound;

  String get title => place == null ? sender : '$sender in $place';
}

/// Where [roomId] is, for a notification's title. The first space on the
/// rail that has it joined, as the jump to it would choose.
String? noticePlace(
  String roomId, {
  required List<Space> spaces,
  required List<Channel> homeRooms,
}) {
  final home = homeRooms.where((c) => c.id == roomId).firstOrNull;
  if (home?.kind == ChannelKind.direct) return null;
  for (final space in spaces) {
    for (final c in space.allChannels) {
      if (c.id == roomId && c.joined) return '#${c.name} · ${space.name}';
    }
  }
  return home == null ? null : '#${home.name}';
}

String noticeBody(Arrival a, {required bool showText}) {
  if (!showText) return 'new message';
  return switch (a.kind) {
    ArrivalKind.picture => 'sent a picture',
    ArrivalKind.file => 'sent a file',
    ArrivalKind.encrypted => 'encrypted message',
    ArrivalKind.text => _clip(a.text.trim()),
  };
}

String _clip(String text) {
  if (text.isEmpty) return 'new message';
  if (text.length <= noticeTextLimit) return text;
  return '${text.substring(0, noticeTextLimit)}…';
}

Notice noticeFor(
  Arrival a, {
  required List<Space> spaces,
  required List<Channel> homeRooms,
  required bool showText,
  bool sound = false,
  String? avatarPath,
}) => Notice(
  route: MessageRoute(a.roomId, a.eventId),
  sender: a.senderName.isEmpty ? a.senderId : a.senderName,
  senderId: a.senderId,
  place: noticePlace(a.roomId, spaces: spaces, homeRooms: homeRooms),
  body: noticeBody(a, showText: showText),
  avatarPath: avatarPath,
  sound: sound,
);
```

`substring(0, 400)` can split a surrogate pair. Cut on runes instead if `characters` is already a dependency (`grep characters pubspec.lock`). If it is, use `text.characters.take(noticeTextLimit)`, and keep the test's length check on `.characters.length`.

In `lib/ui/settings/notification_settings.dart`, give `NotificationController` a `desktop` field:

```dart
  NotificationController({
    required this._store,
    required this.chime,
    this.desktop,
    this._settings = const NotificationSettings(),
  });

  static Future<NotificationController> load(
    NotificationStore store, {
    required Chime chime,
    DesktopNotifications? desktop,
  }) async => NotificationController(
    store: store,
    chime: chime,
    desktop: desktop,
    settings: await store.load() ?? const NotificationSettings(),
  );

  /// The desktop's notifications, for the shell to show and Settings to ask
  /// after; null on phones, in the mock, and in tests that leave it out.
  final DesktopNotifications? desktop;
```

- [ ] **Step 5: Run the tests to see them pass.**

Run: `mise exec -- flutter test test/notice_test.dart test/notifier_test.dart test/app_shell_notifier_test.dart test/notification_settings_test.dart`
Expected: PASS.

- [ ] **Step 6: Commit.**

```nu
git branch --show-current
git add lib/ui/model/arrival.dart lib/ui/model/notice.dart lib/ui/model/desktop_notifications.dart lib/ui/settings/notification_settings.dart test/notice_test.dart
git commit -m "feat(notify): what a notification says, and the DesktopNotifications interface

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 3: Arrivals carry the sender and the text; rooms give an avatar file

**Files:**
- Modify: `lib/matrix/matrix_arrivals.dart`
- Modify: `lib/ui/rooms/rooms.dart`, `lib/matrix/matrix_rooms.dart`, `lib/ui/mock/mock_rooms.dart`, `test/app_shell_rooms_test.dart` (`_FakeRooms`) and `test/space_actions_test.dart` (`_FakeRooms`)
- Test: the existing arrivals test file. Find it with `grep -rln "MatrixArrivals" test`, and add to it.

**Interfaces:**
- Consumes: `Arrival`, `ArrivalKind` (Task 2), and `MxcThumbnail` (`lib/matrix/matrix_avatar_images.dart`).
- Produces:
  - On `Rooms`: `Future<String?> noticeAvatar(AvatarRef ref)`.
  - In `matrix_arrivals.dart`: a top-level `ArrivalKind arrivalKind(Event event)` that tests can call.

- [ ] **Step 1: Write the failing tests.** In the arrivals test file, use its existing harness: a sync with an event from another user after start, collecting `stream`. Add:

```dart
  test('an arrival carries the sender, their picture and the text', () async {
    // Use the file's existing harness: a sync that sets @ada's member event
    // with displayname 'Ada' and avatar_url 'mxc://loaf.moe/ada', then an
    // m.text from her reading 'hello **there**', replying to nothing.
    final a = await arriveOne(/* that sync */);
    expect(a.senderId, '@ada:loaf.moe');
    expect(a.senderName, 'Ada');
    expect(a.senderAvatar, const AvatarRef('mxc://loaf.moe/ada'));
    expect(a.kind, ArrivalKind.text);
    expect(a.text, 'hello there');
  });

  test('a reply carries its own text, not the quote', () async {
    // An m.text whose body is "> <@bob:x> earlier\n\nmy answer" with an
    // m.relates_to m.in_reply_to.
    final a = await arriveOne(/* that sync */);
    expect(a.text, 'my answer');
  });

  test('an undecryptable message reads as encrypted', () async {
    // An m.room.encrypted event the client has no session for. The file's
    // harness must not decrypt it; if push rules wouldn't notify for it,
    // set the room rule to notify for this test.
    final a = await arriveOne(/* that sync */);
    expect(a.kind, ArrivalKind.encrypted);
  });

  test('pictures, stickers and files are told apart', () {
    // Build Events directly over a room in the harness's client.
    expect(arrivalKind(event('m.room.message', {'msgtype': 'm.image', 'body': 'x.png'})), ArrivalKind.picture);
    expect(arrivalKind(event('m.sticker', {'body': 'wave'})), ArrivalKind.picture);
    expect(arrivalKind(event('m.room.message', {'msgtype': 'm.file', 'body': 'x.pdf'})), ArrivalKind.file);
    expect(arrivalKind(event('m.room.message', {'msgtype': 'm.video', 'body': 'x.mp4'})), ArrivalKind.file);
    expect(arrivalKind(event('m.room.message', {'msgtype': 'm.audio', 'body': 'x.ogg'})), ArrivalKind.file);
    expect(arrivalKind(event('m.room.message', {'msgtype': 'm.notice', 'body': 'hi'})), ArrivalKind.text);
  });
```

`arriveOne` and `event` stand for the file's own helpers. If those helpers don't exist, write them in that file in the style of its other tests: an `_sync` that feeds `client.handleSync`, then `await stream.first`. **Every expectation above is required.**

For `MatrixRooms.noticeAvatar`, add to `test/matrix_rooms_test.dart`, or whichever file builds `MatrixRooms` over `FakeMatrixApi`:

```dart
  test('a non-mxc avatar has no notice picture', () async {
    expect(await rooms.noticeAvatar(const AvatarRef('https://x/y.png')), isNull);
  });
```

- [ ] **Step 2: Run them to watch them fail.**

Run: `mise exec -- flutter test <the arrivals test file> test/matrix_rooms_test.dart`
Expected: FAIL. The fields are empty, `arrivalKind` and `noticeAvatar` are undefined.

- [ ] **Step 3: Implement.** In `lib/matrix/matrix_arrivals.dart`, change `_settle`'s `add` to `_arrivals.add(_arrival(event));` and add:

```dart
  /// What a notification will say about [event]: read now, while the
  /// sender's member event and the decrypted content are at hand.
  Arrival _arrival(Event event) {
    final sender = event.senderFromMemoryOrFallback;
    final kind = arrivalKind(event);
    return Arrival(
      roomId: event.room.id,
      eventId: event.eventId,
      senderId: event.senderId,
      senderName: sender.calcDisplayname(),
      senderAvatar: AvatarRef.maybe(sender.avatarUrl?.toString()),
      kind: kind,
      text: kind == ArrivalKind.text
          ? event.calcLocalizedBodyFallback(
              const MatrixDefaultLocalizations(),
              hideReply: true,
              hideEdit: true,
              plaintextBody: true,
              removeMarkdown: true,
            )
          : '',
    );
  }
```

Add a top-level function:

```dart
/// A picture, a file, words, or a message this device has no key for.
ArrivalKind arrivalKind(Event event) {
  if (event.type == EventTypes.Encrypted) return ArrivalKind.encrypted;
  if (event.type == EventTypes.Sticker) return ArrivalKind.picture;
  return switch (event.messageType) {
    MessageTypes.Image => ArrivalKind.picture,
    MessageTypes.File || MessageTypes.Video || MessageTypes.Audio =>
      ArrivalKind.file,
    _ => ArrivalKind.text,
  };
}
```

Import `../ui/model/models.dart` for `AvatarRef`. `calcDisplayname()` falls back to the localpart, so `senderName` is rarely empty. `Notice` falls back to the id anyway.

Add to `Rooms` in `lib/ui/rooms/rooms.dart`:

```dart
  /// [ref]'s picture as a file, for a desktop notification to show; null
  /// when there is none to be had within a moment.
  Future<String?> noticeAvatar(AvatarRef ref);
```

Then add `MockRooms` and each test `_FakeRooms`: `@override Future<String?> noticeAvatar(AvatarRef ref) async => null;`.

In `MatrixRooms`:

```dart
  /// The thumbnail the rail draws, from the SDK's file store or the server,
  /// written once to the temp directory under a hash of its uri. A slow
  /// server gives no picture rather than a late notification.
  @override
  Future<String?> noticeAvatar(AvatarRef ref) async {
    final mxc = Uri.tryParse(ref.value);
    if (mxc == null || !mxc.isScheme('mxc')) return null;
    try {
      final bytes = await MxcThumbnail(
        client,
        mxc,
        avatarBuckets[1],
      ).bytes().timeout(const Duration(seconds: 2));
      final dir = Directory(
        '${(await getTemporaryDirectory()).path}'
        '${Platform.pathSeparator}loaf-notice-avatars',
      );
      await dir.create(recursive: true);
      final name = sha256.convert(utf8.encode(ref.value)).toString();
      final file = File(
        '${dir.path}${Platform.pathSeparator}$name.${_imageExtension(bytes)}',
      );
      if (!await file.exists()) await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } on Object {
      return null;
    }
  }

  /// Windows reads a toast's picture by its extension.
  static String _imageExtension(Uint8List b) {
    if (b.length > 3 && b[0] == 0x89 && b[1] == 0x50) return 'png';
    if (b.length > 2 && b[0] == 0xFF && b[1] == 0xD8) return 'jpg';
    if (b.length > 3 && b[0] == 0x47 && b[1] == 0x49) return 'gif';
    return 'webp';
  }
```

The imports `crypto` (already a dependency), `path_provider`, `dart:io` and `dart:convert` may already be present. Check before adding them.

- [ ] **Step 4: Run the tests to see them pass.**

Run: `mise exec -- flutter test <the arrivals test file> test/matrix_rooms_test.dart test/app_shell_rooms_test.dart test/space_actions_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit.**

```nu
git branch --show-current
git add lib/matrix/matrix_arrivals.dart lib/matrix/matrix_rooms.dart lib/ui/rooms/rooms.dart lib/ui/mock/mock_rooms.dart test
git commit -m "feat(notify): arrivals carry the sender and text; rooms give an avatar file

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 4: The `Noticer`, the Notifier's `desktopNotice` branch, and the shell

**Files:**
- Create: `lib/ui/shell/noticer.dart`
- Modify: `lib/ui/shell/notifier.dart`, `lib/ui/shell/app_shell.dart:126-143,187-190`
- Test: `test/noticer_test.dart` (new), `test/notifier_test.dart`, `test/app_shell_notifier_test.dart`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces:
  - `Noticer({required DesktopNotifications desktop, required Rooms rooms, required NotificationController settings})`, with `Future<void> show(Arrival a, {required bool sound})` and `void dispose()`.
  - A new `Notifier` parameter, `void Function(Arrival arrival, {required bool sound})? notice`.

- [ ] **Step 1: Write the failing `Noticer` tests.** Create `test/noticer_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/mock/mock_rooms.dart';
import 'package:loaf_native/ui/model/arrival.dart';
import 'package:loaf_native/ui/model/chime.dart';
import 'package:loaf_native/ui/model/desktop_notifications.dart';
import 'package:loaf_native/ui/model/models.dart';
import 'package:loaf_native/ui/settings/notification_settings.dart';
import 'package:loaf_native/ui/shell/noticer.dart';

/// Mock rooms whose unread counts the test sets, and an avatar file for
/// anyone.
class _Rooms extends MockRooms {
  final unread = <String, int>{};

  @override
  List<Channel> get homeRooms => [
    for (final c in super.homeRooms)
      unread.containsKey(c.id) ? c.copyWith(unread: unread[c.id]) : c,
  ];

  void setUnread(String id, int n) {
    unread[id] = n;
    notifyListeners();
  }

  @override
  Future<String?> noticeAvatar(AvatarRef ref) async => '/tmp/${ref.value}.png';
}

void main() {
  late _Rooms rooms;
  late FakeDesktopNotifications desktop;
  late NotificationController settings;
  late Noticer noticer;
  late String dm;

  setUp(() {
    rooms = _Rooms();
    desktop = FakeDesktopNotifications();
    settings = NotificationController(
      store: MemoryNotificationStore(),
      chime: FakeChime(),
      desktop: desktop,
    );
    noticer = Noticer(desktop: desktop, rooms: rooms, settings: settings);
    dm = rooms.homeRooms.firstWhere((c) => c.kind == ChannelKind.direct).id;
  });

  tearDown(() {
    noticer.dispose();
    rooms.dispose();
  });

  Arrival arrival(String room, {AvatarRef? avatar}) => Arrival(
    roomId: room,
    eventId: r'$e',
    senderId: '@ada:x',
    senderName: 'Ada',
    senderAvatar: avatar,
    text: 'hi',
  );

  test('shows a notice with the avatar file and the sound it was given', () async {
    await noticer.show(arrival(dm, avatar: const AvatarRef('ada')), sound: true);
    expect(desktop.shown.single.title, 'Ada');
    expect(desktop.shown.single.body, 'hi');
    expect(desktop.shown.single.avatarPath, '/tmp/ada.png');
    expect(desktop.shown.single.sound, isTrue);
  });

  test('with notifications off, shows nothing', () async {
    settings.setNotifications(false);
    await noticer.show(arrival(dm), sound: true);
    expect(desktop.shown, isEmpty);
  });

  test('with message text off, the body hides it', () async {
    settings.setShowText(false);
    await noticer.show(arrival(dm), sound: false);
    expect(desktop.shown.single.body, 'new message');
  });

  test('a read room has its notices withdrawn', () async {
    rooms.setUnread(dm, 1);
    await noticer.show(arrival(dm), sound: false);
    rooms.setUnread(dm, 0);
    expect(desktop.withdrawn, [dm]);
    rooms.setUnread(dm, 0);
    expect(desktop.withdrawn, [dm], reason: 'once');
  });

  test('a notice is not withdrawn before its room was seen unread', () async {
    rooms.setUnread(dm, 0);
    await noticer.show(arrival(dm), sound: false);
    rooms.setUnread(dm, 0); // the count has not caught up yet
    expect(desktop.withdrawn, isEmpty);
    rooms.setUnread(dm, 1);
    rooms.setUnread(dm, 0);
    expect(desktop.withdrawn, [dm]);
  });

  test('a room that is gone has its notices withdrawn', () async {
    await noticer.show(arrival('!gone:x'), sound: false);
    rooms.notifyListeners();
    expect(desktop.withdrawn, ['!gone:x']);
  });
}
```

If `Channel` has no `copyWith` taking `unread`, add the one parameter to its existing `copyWith`, or write the `_Rooms` override with the constructor the fixtures use.

- [ ] **Step 2: Write the failing `Notifier` tests.** In `test/notifier_test.dart`:
  - add `final notices = <(Arrival, bool)>[];` to the group's state, and pass `notice: (a, {required sound}) => notices.add((a, sound)),` in `make()`;
  - clear `notices` in `setUp`;
  - rename the test "unfocused, the chime waits for step D" to "unfocused on a desktop, a notification instead of the chime", and give it this body:

```dart
      focused = false;
      final n = make();
      addTearDown(n.dispose);
      await arrive('!other');
      expect(chime.plays, 0);
      expect(notices.single.$1.roomId, '!other');
      expect(notices.single.$2, isTrue);
```

Add two tests:

```dart
    test('unfocused, the open channel notifies too', () async {
      focused = false;
      final n = make();
      addTearDown(n.dispose);
      await arrive('!open');
      expect(notices, hasLength(1));
    });

    test('one throttle for chimes and notifications: a burst sounds once', () async {
      final n = make();
      addTearDown(n.dispose);
      await arrive('!other'); // chimes
      focused = false;
      await arrive('!other'); // a notice, within the second: silent
      elapsed = const Duration(seconds: 1);
      await arrive('!other'); // a notice, a second on: sounds
      expect(chime.plays, 1);
      expect([for (final (_, sound) in notices) sound], [false, true]);
    });

    test('with sound off, notices are silent', () async {
      sound = false;
      focused = false;
      final n = make();
      addTearDown(n.dispose);
      await arrive('!other');
      expect(notices.single.$2, isFalse);
    });
```

- [ ] **Step 3: Write the failing shell test.** In `test/app_shell_notifier_test.dart`:
  - give `pump` a `FakeDesktopNotifications desktop` (create it in `pump`, and pass `desktop: desktop` to `NotificationController.load`);
  - set `debugDefaultTargetPlatformOverride = TargetPlatform.macOS;` at the top of the new tests, resetting it with `addTearDown(() => debugDefaultTargetPlatformOverride = null);`.
  
  Add:

```dart
  testWidgets('on a desktop the shell prepares notifications as it opens', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await pump(tester);
    expect(desktop.prepared, 1);
  });

  testWidgets('in the background, a message becomes a notification', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await pump(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await arrive(tester, openId());
    await tester.pump();
    expect(desktop.shown.single.route.roomId, openId());
    expect(chime.plays, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
```

`Notifier` reads `isDesktop` once, in its constructor, so the override must be set before `pump`.

- [ ] **Step 4: Run them to watch them fail.**

Run: `mise exec -- flutter test test/noticer_test.dart test/notifier_test.dart test/app_shell_notifier_test.dart`
Expected: a compile error: no `Noticer`, and no `notice:` on `Notifier`.

- [ ] **Step 5: Implement the `Noticer`.** Create `lib/ui/shell/noticer.dart`:

```dart
/// Desktop notifications for the shell: what each says, and taking a
/// room's back once it is read, here or on another device.
library;

import 'dart:async';

import '../model/arrival.dart';
import '../model/desktop_notifications.dart';
import '../model/models.dart';
import '../model/notice.dart';
import '../rooms/rooms.dart';
import '../settings/notification_settings.dart';

class Noticer {
  Noticer({required this.desktop, required this.rooms, required this.settings}) {
    rooms.addListener(_onRooms);
  }

  final DesktopNotifications desktop;
  final Rooms rooms;
  final NotificationController settings;

  /// Rooms with notices up, and whether each has been seen unread since.
  /// A count can lag its message within a sync: a room read as 0 before it
  /// was ever seen unread has not been read, only not yet counted.
  final _shown = <String, bool>{};
  var _disposed = false;

  Future<void> show(Arrival a, {required bool sound}) async {
    if (!settings.notifications) return;
    final ref = a.senderAvatar;
    final avatarPath = ref == null ? null : await rooms.noticeAvatar(ref);
    if (_disposed || !settings.notifications) return;
    _shown[a.roomId] = (_shown[a.roomId] ?? false) || _unread(a.roomId);
    await desktop.show(
      noticeFor(
        a,
        spaces: rooms.spaces,
        homeRooms: rooms.homeRooms,
        showText: settings.showText,
        sound: sound,
        avatarPath: avatarPath,
      ),
    );
  }

  bool _unread(String roomId) {
    final c = _channel(roomId);
    return c != null && (c.unread > 0 || c.mentions > 0);
  }

  Channel? _channel(String roomId) {
    for (final c in rooms.homeRooms) {
      if (c.id == roomId) return c;
    }
    for (final space in rooms.spaces) {
      for (final c in space.allChannels) {
        if (c.id == roomId && c.joined) return c;
      }
    }
    return null;
  }

  void _onRooms() {
    for (final MapEntry(key: id, value: seen) in _shown.entries.toList()) {
      if (_channel(id) == null) {
        _withdraw(id);
      } else if (_unread(id)) {
        _shown[id] = true;
      } else if (seen) {
        _withdraw(id);
      }
    }
  }

  void _withdraw(String roomId) {
    _shown.remove(roomId);
    unawaited(desktop.withdraw(roomId));
  }

  void dispose() {
    _disposed = true;
    rooms.removeListener(_onRooms);
  }
}
```

- [ ] **Step 6: Implement the Notifier's branch.** In `lib/ui/shell/notifier.dart`:
  - add `this.notice,` to the constructor's parameters;
  - add the field:

```dart
  /// Shows a desktop notification for [arrival]; null where there are none.
  /// [sound]: whether this one may sound, by the same throttle as the chime.
  final void Function(Arrival arrival, {required bool sound})? notice;
```

Replace the `desktopNotice` case body with `notice?.call(arrival, sound: _sounds());`. Replace `_chime` with:

```dart
  void _chime() {
    if (_sounds()) unawaited(chime.play());
  }

  /// Whether a sound may go now: Sound is on and nothing has sounded in the
  /// last second. Saying yes counts as sounding.
  bool _sounds() {
    if (!soundOn()) return false;
    final now = _elapsed();
    final last = _lastChime;
    if (last != null && now - last < const Duration(seconds: 1)) return false;
    _lastChime = now;
    return true;
  }
```

Update the doc on `_lastChime` to say "When a chime or notification last sounded".

- [ ] **Step 7: Wire the shell.** In `lib/ui/shell/app_shell.dart`, add `Noticer? _noticer;` beside `_notifier`, and replace the body of `didChangeDependencies`'s `if`:

```dart
    final notifications = NotificationScope.find(context);
    if (_notifier == null && notifications != null) {
      final desktop = notifications.desktop;
      final noticer = desktop == null
          ? null
          : Noticer(desktop: desktop, rooms: _rooms, settings: notifications);
      _noticer = noticer;
      _notifier = Notifier(
        arrivals: _rooms.arrivals,
        chime: notifications.chime,
        soundOn: () => notifications.sound,
        openRoom: () => _openMessagesRoom,
        notice: noticer == null
            ? null
            : (arrival, {required sound}) =>
                  unawaited(noticer.show(arrival, sound: sound)),
      );
      // The first time the shell opens after sign-in is when macOS asks
      // permission; asking again later does nothing.
      if (desktop != null && notifications.notifications) {
        unawaited(desktop.prepare());
      }
    }
```

In `dispose`, add `_noticer?.dispose();` after `_notifier?.dispose();`.

- [ ] **Step 8: Run the tests to see them pass.**

Run: `mise exec -- flutter test test/noticer_test.dart test/notifier_test.dart test/app_shell_notifier_test.dart`
Expected: PASS. Then run `mise exec -- flutter test` and `mise exec -- flutter analyze`.

- [ ] **Step 9: Commit.**

```nu
git branch --show-current
git add lib/ui/shell/noticer.dart lib/ui/shell/notifier.dart lib/ui/shell/app_shell.dart test/noticer_test.dart test/notifier_test.dart test/app_shell_notifier_test.dart
git commit -m "feat(notify): unfocused on a desktop, a message becomes a notification

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 5: The Notifications section: the toggles and the blocked line

**Files:**
- Modify: `lib/ui/settings/notifications_section.dart`
- Test: `test/notifications_section_test.dart`

**Interfaces:**
- Consumes: `NotificationController.desktop`, `notifications`, `showText`, `setNotifications` and `setShowText`; `DesktopNotifications.blocked`, `prepare` and `openSystemSettings`; `isDesktop` (`lib/ui/platform.dart`); and `LoafButton` (as `about_section.dart` uses it).
- Produces: nothing new for later tasks.

- [ ] **Step 1: Write the failing tests.** Add them to `test/notifications_section_test.dart`, reusing its `pumpWidget` helper and passing a controller built with `desktop: FakeDesktopNotifications()`:

```dart
  testWidgets('on a desktop: notifications and message text, which save', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final desktop = FakeDesktopNotifications();
    final c = NotificationController(
      store: MemoryNotificationStore(),
      chime: FakeChime(),
      desktop: desktop,
    );
    await pumpSection(tester, c);
    expect(find.text('notifications'), findsOneWidget);
    expect(find.text('show message text'), findsOneWidget);
    expect(find.text('a soft chime for messages in other channels, and on notifications.'), findsOneWidget);

    await tester.tap(find.text('show message text'));
    await tester.pump();
    expect(c.showText, isFalse);

    await tester.tap(find.text('notifications'));
    await tester.pump();
    expect(c.notifications, isFalse);
    await tester.tap(find.text('notifications'));
    await tester.pumpAndSettle();
    expect(c.notifications, isTrue);
    expect(desktop.prepared, 1, reason: 'turning it on gets it ready');
  });

  testWidgets('on a phone: only sound', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final c = NotificationController(store: MemoryNotificationStore(), chime: FakeChime());
    await pumpSection(tester, c);
    expect(find.text('notifications'), findsNothing);
    expect(find.text('show message text'), findsNothing);
  });

  testWidgets('when the OS blocks them, a line says so and opens settings', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final desktop = FakeDesktopNotifications()..isBlocked = true;
    final c = NotificationController(store: MemoryNotificationStore(), chime: FakeChime(), desktop: desktop);
    await pumpSection(tester, c);
    await tester.pumpAndSettle();
    expect(find.text('macos is blocking notifications from loaf chat.'), findsOneWidget);
    await tester.tap(find.text('open system settings'));
    expect(desktop.settingsOpened, 1);

    // Back from System Settings with them allowed: the line goes.
    desktop.isBlocked = false;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.textContaining('is blocking'), findsNothing);
  });

  testWidgets('show message text is greyed while notifications are off', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final c = NotificationController(store: MemoryNotificationStore(), chime: FakeChime(), desktop: FakeDesktopNotifications());
    c.setNotifications(false);
    await pumpSection(tester, c);
    await tester.tap(find.text('show message text'));
    await tester.pump();
    expect(c.showText, isTrue);
  });
```

`pumpSection` is the file's existing pump helper. If it pumps inline, extract it into a helper first.

- [ ] **Step 2: Run them to watch them fail.**

Run: `mise exec -- flutter test test/notifications_section_test.dart`
Expected: FAIL. The new texts aren't found.

- [ ] **Step 3: Implement.** In `settings_controls.dart`, give `SettingsCheck` an `enabled` flag that defaults to `true`. When it is `false`:
  - `onTap` and the `Checkbox`'s `onChanged` are `null`;
  - the row is wrapped in `Opacity(opacity: 0.5)`.

Then rewrite `notifications_section.dart`:

```dart
/// Notifications: the chime, and on a desktop the notifications themselves
/// and how much they say.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../platform.dart';
import '../theme/loaf_theme.dart';
import '../widgets/loaf_button.dart';
import 'notification_settings.dart';
import 'settings_controls.dart';

class NotificationsSection extends StatefulWidget {
  const NotificationsSection({super.key, required this.controller});

  final NotificationController controller;

  @override
  State<NotificationsSection> createState() => _NotificationsSectionState();
}

class _NotificationsSectionState extends State<NotificationsSection>
    with WidgetsBindingObserver {
  /// Read when the section opens and each time the app comes back, as it
  /// does from System Settings.
  var _blocked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_check());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_check());
  }

  Future<void> _check() async {
    final blocked = await widget.controller.desktop?.blocked() ?? false;
    if (mounted && blocked != _blocked) setState(() => _blocked = blocked);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  String get _os => defaultTargetPlatform == TargetPlatform.windows ? 'windows' : 'macos';

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final desktop = isDesktop ? controller.desktop : null;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(LoafSpace.x6),
        children: [
          const SettingsLabel(label: 'on this device'),
          if (desktop != null) ...[
            SettingsCheck(
              title: 'notifications',
              detail: "a notification when loaf chat isn't in front.",
              value: controller.notifications,
              onChanged: (on) {
                controller.setNotifications(on);
                if (on) unawaited(desktop.prepare().then((_) => _check()));
              },
            ),
            if (_blocked) _BlockedLine(os: _os, onOpen: desktop.openSystemSettings),
          ],
          SettingsCheck(
            title: 'sound',
            detail: desktop != null
                ? 'a soft chime for messages in other channels, and on notifications.'
                : 'a soft chime for messages in other channels.',
            value: controller.sound,
            onChanged: (on) {
              controller.setSound(on);
              // Turning it on plays it, so you know what you turned on.
              if (on) unawaited(controller.chime.play());
            },
          ),
          if (desktop != null)
            SettingsCheck(
              title: 'show message text',
              detail: 'off, a notification says only who wrote.',
              value: controller.showText,
              enabled: controller.notifications,
              onChanged: controller.setShowText,
            ),
        ],
      ),
    );
  }
}

class _BlockedLine extends StatelessWidget {
  const _BlockedLine({required this.os, required this.onOpen});

  final String os;
  final Future<void> Function() onOpen;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: LoafSpace.x10, bottom: LoafSpace.x3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$os is blocking notifications from loaf chat.',
            style: loafBody(13, 400).copyWith(color: tokens.textMuted),
          ),
          const SizedBox(height: LoafSpace.x2),
          LoafButton(
            label: 'open system settings',
            icon: LucideIcons.externalLink,
            emphasis: LoafButtonEmphasis.outlined,
            size: LoafButtonSize.small,
            onTap: () => unawaited(onOpen()),
          ),
        ],
      ),
    );
  }
}
```

Check the import paths for `LoafButton`, `lucide_icons` and `defaultTargetPlatform` (`package:flutter/foundation.dart`) against `about_section.dart`. If `LoafSpace.x10` doesn't exist, use the indent that lines up with a `SettingsCheck`'s title: the checkbox width plus `x2`.

- [ ] **Step 4: Run the tests to see them pass.**

Run: `mise exec -- flutter test test/notifications_section_test.dart test/settings_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit.**

```nu
git branch --show-current
git add lib/ui/settings test/notifications_section_test.dart
git commit -m "feat(notify): the Notifications and Show message text toggles, and the blocked line

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 6: Linux outside Flatpak: `org.freedesktop.Notifications`

**Files:**
- Create: `lib/notify/fdo_notifications.dart`
- Test: `test/notify/fdo_notifications_test.dart`

**Interfaces:**
- Consumes: `DesktopNotifications`, `Notice` and `Chime`.
- Produces: `FdoNotifications({required Chime chime, required String soundFile, DBusClient? bus, void Function(Object)? log})`.

- [ ] **Step 1: Write the failing tests.** Create `test/notify/fdo_notifications_test.dart`. It uses a private bus the same way `packages/loaf_media/test/portal_test.dart` does:

```dart
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/notify/fdo_notifications.dart';
import 'package:loaf_native/ui/model/chime.dart';
import 'package:loaf_native/ui/model/message_route.dart';
import 'package:loaf_native/ui/model/notice.dart';

const _iface = 'org.freedesktop.Notifications';

/// Stands in for a notification server: records Notify and
/// CloseNotification, and says what it can do.
class _FakeServer extends DBusObject {
  _FakeServer(this.caps) : super(DBusObjectPath('/org/freedesktop/Notifications'));

  final List<String> caps;
  final notified = <List<DBusValue>>[];
  final closed = <int>[];
  var _next = 1;

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface != _iface) return DBusMethodErrorResponse.unknownInterface();
    switch (call.name) {
      case 'GetCapabilities':
        return DBusMethodSuccessResponse([DBusArray.string(caps)]);
      case 'Notify':
        notified.add(call.values);
        return DBusMethodSuccessResponse([DBusUint32(_next++)]);
      case 'CloseNotification':
        closed.add(call.values.single.asUint32());
        return DBusMethodSuccessResponse();
    }
    return DBusMethodErrorResponse.unknownMethod();
  }

  Future<void> invoke(int id, String action) => emitSignal(
    _iface,
    'ActionInvoked',
    [DBusUint32(id), DBusString(action)],
  );
}

Notice _notice({String room = '!r:x', String body = 'hi', bool sound = true, String? avatar}) =>
    Notice(
      route: MessageRoute(room, r'$e'),
      sender: 'Ada',
      senderId: '@ada:x',
      place: '#general · Loaf',
      body: body,
      sound: sound,
      avatarPath: avatar,
    );

void main() {
  late Directory dir;
  late DBusServer server;
  late DBusClient serverSide;
  late DBusClient appSide;
  late FakeChime chime;

  Future<_FakeServer> serve(List<String> caps) async {
    final s = _FakeServer(caps);
    await serverSide.requestName(_iface);
    await serverSide.registerObject(s);
    return s;
  }

  FdoNotifications make() => FdoNotifications(chime: chime, soundFile: '/app/chime.wav', bus: appSide);

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('loaf-fdo-test');
    server = DBusServer();
    final address = await server.listenAddress(DBusAddress.unix(dir: dir));
    serverSide = DBusClient(address, authClient: DBusAuthClient(uid: '0'));
    appSide = DBusClient(address, authClient: DBusAuthClient(uid: '0'));
    chime = FakeChime();
  });

  tearDown(() async {
    await appSide.close();
    await serverSide.close();
    await server.close();
    dir.deleteSync(recursive: true);
  });

  test('notifies with the desktop entry, the sound file, and a default action', () async {
    final s = await serve(['actions', 'body', 'sound']);
    await make().show(_notice(avatar: '/tmp/a b.png'));
    final v = s.notified.single;
    expect(v[0], const DBusString('Loaf Chat'));
    expect(v[2], const DBusString('moe.loaf.chat'));
    expect(v[3], const DBusString('Ada in #general · Loaf'));
    expect(v[4], const DBusString('hi'));
    expect(v[5], DBusArray.string(['default', 'open']));
    final hints = v[6].asStringVariantDict();
    expect(hints['desktop-entry'], const DBusString('moe.loaf.chat'));
    expect(hints['sound-file'], const DBusString('/app/chime.wav'));
    expect(hints['image-path'], DBusString(Uri.file('/tmp/a b.png').toString()));
    expect(v[7], const DBusInt32(-1));
    expect(chime.plays, 0);
  });

  test('a server without sound: the app plays the chime', () async {
    final s = await serve(['actions', 'body']);
    await make().show(_notice());
    expect(s.notified.single[6].asStringVariantDict().containsKey('sound-file'), isFalse);
    expect(chime.plays, 1);
  });

  test('a silent notice asks the server to keep quiet', () async {
    final s = await serve(['actions', 'body', 'sound']);
    await make().show(_notice(sound: false));
    final hints = s.notified.single[6].asStringVariantDict();
    expect(hints['suppress-sound'], const DBusBoolean(true));
    expect(hints.containsKey('sound-file'), isFalse);
    expect(chime.plays, 0);
  });

  test('the body is escaped for a markup server', () async {
    final s = await serve(['body', 'body-markup']);
    await make().show(_notice(body: '<b>hi</b> & co'));
    expect(s.notified.single[4], const DBusString('&lt;b&gt;hi&lt;/b&gt; &amp; co'));
  });

  test('a server without actions gets none', () async {
    final s = await serve(['body']);
    await make().show(_notice());
    expect(s.notified.single[5], DBusArray.string([]));
  });

  test('a click on the default action is a route', () async {
    final s = await serve(['actions', 'body']);
    final n = make();
    final clicks = <MessageRoute>[];
    n.clicks.listen(clicks.add);
    await n.show(_notice());
    await s.invoke(1, 'default');
    await s.invoke(1, 'something-else');
    await s.invoke(99, 'default');
    await pumpEventQueue();
    expect(clicks, [const MessageRoute('!r:x', r'$e')]);
  });

  test('withdraw closes that room\'s notifications only', () async {
    final s = await serve(['actions', 'body']);
    final n = make();
    await n.show(_notice(room: '!a:x'));
    await n.show(_notice(room: '!b:x'));
    await n.show(_notice(room: '!a:x'));
    await n.withdraw('!a:x');
    expect(s.closed, unorderedEquals([1, 3]));
    await n.withdraw('!a:x');
    expect(s.closed, hasLength(2), reason: 'nothing left to close');
  });

  test('no server at all: nothing throws, and the chime still plays', () async {
    await make().show(_notice());
    expect(chime.plays, 1);
  });
}
```

- [ ] **Step 2: Run them to watch them fail.**

Run: `mise exec -- flutter test test/notify/fdo_notifications_test.dart`
Expected: a compile error: no `fdo_notifications.dart`.

- [ ] **Step 3: Implement.** Create `lib/notify/fdo_notifications.dart`:

```dart
/// Desktop notifications outside Flatpak: the freedesktop notification
/// server (GNOME Shell, Plasma, dunst, mako…) over the session bus.
library;

import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:matrix/matrix.dart' show Logs;

import '../ui/model/chime.dart';
import '../ui/model/desktop_notifications.dart';
import '../ui/model/message_route.dart';
import '../ui/model/notice.dart';

class FdoNotifications implements DesktopNotifications {
  FdoNotifications({
    required this.chime,
    required this.soundFile,
    DBusClient? bus,
    void Function(Object error)? log,
  }) : _bus = bus ?? DBusClient.session(),
       _log = log ?? ((e) => Logs().w('[loaf] notification failed', e));

  static const _name = 'org.freedesktop.Notifications';

  final Chime chime;

  /// The chime as a file the server can play: the app's bundled asset.
  final String soundFile;
  final DBusClient _bus;
  final void Function(Object error) _log;
  var _logged = false;

  late final _server = DBusRemoteObject(
    _bus,
    name: _name,
    path: DBusObjectPath('/org/freedesktop/Notifications'),
  );

  /// Asked once: a server doesn't change what it can do while it runs.
  Future<Set<String>>? _caps;

  /// Each notification up, by the id the server gave it.
  final _routes = <int, MessageRoute>{};
  final _clicks = StreamController<MessageRoute>.broadcast();
  StreamSubscription<DBusSignal>? _invoked;
  StreamSubscription<DBusSignal>? _closed;

  Future<Set<String>> _capabilities() => _caps ??= _server
      .callMethod(_name, 'GetCapabilities', const [], replySignature: DBusSignature('as'))
      .then((r) => r.returnValues.single.asStringArray().toSet());

  void _listen() {
    _invoked ??= DBusRemoteObjectSignalStream(
      object: _server,
      interface: _name,
      name: 'ActionInvoked',
      signature: DBusSignature('us'),
    ).listen((s) {
      final route = _routes[s.values[0].asUint32()];
      if (route != null && s.values[1].asString() == 'default') _clicks.add(route);
    });
    _closed ??= DBusRemoteObjectSignalStream(
      object: _server,
      interface: _name,
      name: 'NotificationClosed',
      signature: DBusSignature('uu'),
    ).listen((s) => _routes.remove(s.values[0].asUint32()));
  }

  void _fail(Object error) {
    if (_logged) return;
    _logged = true;
    _log(error);
  }

  static String _escape(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  @override
  Future<void> prepare() async {}

  @override
  Future<void> show(Notice notice) async {
    var sounded = false;
    try {
      _listen();
      final caps = await _capabilities();
      final serverSounds = caps.contains('sound');
      final reply = await _server.callMethod(_name, 'Notify', [
        const DBusString('Loaf Chat'),
        const DBusUint32(0),
        const DBusString('moe.loaf.chat'),
        DBusString(notice.title),
        DBusString(caps.contains('body-markup') ? _escape(notice.body) : notice.body),
        DBusArray.string(caps.contains('actions') ? const ['default', 'open'] : const []),
        DBusDict.stringVariant({
          'desktop-entry': const DBusString('moe.loaf.chat'),
          'category': const DBusString('im.received'),
          if (notice.sound && serverSounds) 'sound-file': DBusString(soundFile),
          if (!notice.sound) 'suppress-sound': const DBusBoolean(true),
          if (notice.avatarPath case final path?)
            'image-path': DBusString(Uri.file(path).toString()),
        }),
        const DBusInt32(-1),
      ], replySignature: DBusSignature('u'));
      _routes[reply.returnValues.single.asUint32()] = notice.route;
      sounded = notice.sound && serverSounds;
    } on Object catch (e) {
      _fail(e);
    }
    if (notice.sound && !sounded) await chime.play();
  }

  @override
  Future<void> withdraw(String roomId) async {
    final ids = [
      for (final MapEntry(key: id, value: route) in _routes.entries)
        if (route.roomId == roomId) id,
    ];
    for (final id in ids) {
      _routes.remove(id);
      try {
        await _server.callMethod(_name, 'CloseNotification', [DBusUint32(id)],
            replySignature: DBusSignature(''));
      } on Object catch (e) {
        _fail(e);
      }
    }
  }

  @override
  Stream<MessageRoute> get clicks {
    _listen();
    return _clicks.stream;
  }

  @override
  Future<bool> blocked() async => false;

  @override
  Future<void> openSystemSettings() async {}
}
```

When a server shows the notification but doesn't sound it, `sounded` stays false, and the app plays the chime. When `Notify` itself fails (no server), the chime still plays, which keeps Sound's promise. That's the last test.

- [ ] **Step 4: Run the tests to see them pass.**

Run: `mise exec -- flutter test test/notify/fdo_notifications_test.dart`
Expected: PASS. If "no server at all" hangs, `DBusClient` is waiting for a name that has no owner: the call fails with `org.freedesktop.DBus.Error.ServiceUnknown` on a real bus, and the private bus answers the same way. Debug it; don't skip the test.

- [ ] **Step 5: Commit.**

```nu
git branch --show-current
git add lib/notify/fdo_notifications.dart test/notify/fdo_notifications_test.dart
git commit -m "feat(notify): Linux notifications through org.freedesktop.Notifications

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 7: Linux inside Flatpak: the Notification portal, and a sealable memfd

**Files:**
- Create: `lib/notify/memfd.dart`, `lib/notify/portal_notifications.dart`
- Modify: `pubspec.yaml`, to add `ffi:` at the version `pubspec.lock` already resolves (`grep -A4 "^  ffi:" pubspec.lock`)
- Test: `test/notify/portal_notifications_test.dart`, `test/notify/memfd_test.dart`

**Interfaces:**
- Produces:
  - `Future<ResourceHandle?> memfdOf(File file)`.
  - `PortalNotifications({required Chime chime, required String soundFile, DBusClient? bus, Future<ResourceHandle?> Function(File) sealable = memfdOf, void Function(Object)? log})`.

- [ ] **Step 1: Write the failing tests.** Create `test/notify/memfd_test.dart`:

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/notify/memfd.dart';

void main() {
  test('a memfd copy reads back the file', () async {
    final dir = Directory.systemTemp.createTempSync('loaf-memfd');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/chime.wav')..writeAsBytesSync([1, 2, 3, 4]);
    final handle = await memfdOf(file);
    expect(handle, isNotNull);
    final copy = handle!.toFile();
    try {
      await copy.setPosition(0);
      expect(await copy.read(4), [1, 2, 3, 4]);
    } finally {
      await copy.close();
    }
  }, skip: !Platform.isLinux);

  test('off Linux there is none', () async {
    expect(await memfdOf(File('/nonexistent')), isNull);
  }, skip: Platform.isLinux);
}
```

Create `test/notify/portal_notifications_test.dart`, with the same private-bus scaffolding as Task 6. The fake object is at `/org/freedesktop/portal/desktop` under the name `org.freedesktop.portal.Desktop`. It answers `org.freedesktop.DBus.Properties.Get('org.freedesktop.portal.Notification', 'version')` with a settable `version`, records `AddNotification` and `RemoveNotification`, and emits `ActionInvoked(s id, s action, av parameter)`:

```dart
class _FakePortal extends DBusObject {
  _FakePortal(this.version) : super(DBusObjectPath('/org/freedesktop/portal/desktop'));
  final int version;
  final added = <(String, Map<String, DBusValue>)>[];
  final removed = <String>[];

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async =>
      interface == _iface && name == 'version'
      ? DBusGetPropertyResponse(DBusUint32(version))
      : DBusMethodErrorResponse.unknownProperty();

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface != _iface) return DBusMethodErrorResponse.unknownInterface();
    switch (call.name) {
      case 'AddNotification':
        added.add((call.values[0].asString(), call.values[1].asStringVariantDict()));
        return DBusMethodSuccessResponse();
      case 'RemoveNotification':
        removed.add(call.values[0].asString());
        return DBusMethodSuccessResponse();
    }
    return DBusMethodErrorResponse.unknownMethod();
  }

  Future<void> invoke(String id, List<String> target) => emitSignal(_iface, 'ActionInvoked', [
    DBusString(id),
    const DBusString('open'),
    DBusArray.variant([DBusArray.string(target)]),
  ]);
}
```

Tests. The `sealable` stub opens the file plainly, so they run on a Mac:

```dart
  Future<ResourceHandle?> plain(File f) async => ResourceHandle.fromFile(await f.open());

  test('version 2: the notice, its icon as bytes, the chime as a descriptor, and open', () async {
    final p = await serve(_FakePortal(2));
    final avatar = File('${dir.path}/ada.png')..writeAsBytesSync([9, 9]);
    final sound = File('${dir.path}/chime.wav')..writeAsBytesSync([1]);
    await make(sound.path, sealable: plain).show(_notice(avatar: avatar.path));
    final (id, fields) = p.added.single;
    expect(id, r'room:!r:x:$e');
    expect(fields['title'], const DBusString('Ada in #general · Loaf'));
    expect(fields['body'], const DBusString('hi'));
    expect(fields['default-action'], const DBusString('open'));
    expect(fields['default-action-target'], DBusVariant(DBusArray.string(['!r:x', r'$e'])));
    expect(fields['icon'], DBusStruct([const DBusString('bytes'), DBusVariant(DBusArray.byte([9, 9]))]));
    final soundValue = (fields['sound']! as DBusVariant).value as DBusStruct;
    expect(soundValue.children.first, const DBusString('file-descriptor'));
    expect(chime.plays, 0);
  });

  test('version 1: no sound field, and the app plays the chime', () async {
    final p = await serve(_FakePortal(1));
    await make('/x.wav', sealable: plain).show(_notice());
    expect(p.added.single.$2.containsKey('sound'), isFalse);
    expect(chime.plays, 1);
  });

  test('no memfd to be had: the app plays the chime', () async {
    final p = await serve(_FakePortal(2));
    await make('/x.wav', sealable: (_) async => null).show(_notice());
    expect(p.added.single.$2.containsKey('sound'), isFalse);
    expect(chime.plays, 1);
  });

  test('a click is a route, from the target even for a notice from a last run', () async {
    final p = await serve(_FakePortal(2));
    final n = make('/x.wav', sealable: plain);
    final clicks = <MessageRoute>[];
    n.clicks.listen(clicks.add);
    await p.invoke(r'room:!old:x:$z', ['!old:x', r'$z']);
    await pumpEventQueue();
    expect(clicks, [const MessageRoute('!old:x', r'$z')]);
  });

  test('withdraw removes that room\'s notices', () async {
    final p = await serve(_FakePortal(2));
    final n = make('/x.wav', sealable: plain);
    await n.show(_notice(room: '!a:x'));
    await n.show(_notice(room: '!b:x'));
    await n.withdraw('!a:x');
    expect(p.removed, [r'room:!a:x:$e']);
  });
```

`make(soundFile, {sealable})` returns `PortalNotifications(chime: chime, soundFile: soundFile, bus: appSide, sealable: sealable)`. In the first test, `make(sound.path, …)` must be given the real temp file. `DBusVariant` equality on structs may compare by identity: if it does, compare `.value` with `equals`.

- [ ] **Step 2: Run them to watch them fail.**

Run: `mise exec -- flutter test test/notify/portal_notifications_test.dart test/notify/memfd_test.dart`
Expected: a compile error.

- [ ] **Step 3: Implement `memfd.dart`.**

```dart
/// A copy of a file in a sealable memfd: what the Notification portal
/// takes a sound as. The portal seals its copy, so what plays is what was
/// sent.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:dbus/dbus.dart' show ResourceHandle;
import 'package:ffi/ffi.dart';

typedef _MemfdCreateC = Int32 Function(Pointer<Utf8> name, Uint32 flags);
typedef _MemfdCreate = int Function(Pointer<Utf8> name, int flags);
typedef _CloseC = Int32 Function(Int32 fd);
typedef _Close = int Function(int fd);

const _mfdCloexec = 0x1;
const _mfdAllowSealing = 0x2;

/// Null off Linux, or when the kernel or the copy refuses.
Future<ResourceHandle?> memfdOf(File file) async {
  if (!Platform.isLinux) return null;
  final libc = DynamicLibrary.process();
  final create = libc.lookupFunction<_MemfdCreateC, _MemfdCreate>('memfd_create');
  final close = libc.lookupFunction<_CloseC, _Close>('close');
  final name = 'loaf-chime'.toNativeUtf8();
  try {
    final fd = create(name, _mfdCloexec | _mfdAllowSealing);
    if (fd < 0) return null;
    try {
      // Opening the fd's /proc entry gives a Dart file over the same memfd;
      // the raw fd is closed once that one holds it.
      final copy = await File('/proc/self/fd/$fd').open(mode: FileMode.write);
      await copy.writeFrom(await file.readAsBytes());
      await copy.setPosition(0);
      return ResourceHandle.fromFile(copy);
    } finally {
      close(fd);
    }
  } on Object {
    return null;
  } finally {
    malloc.free(name);
  }
}
```

Check where `ResourceHandle` is exported from: `dart:io` exports it, and the portal test reaches it through `dart:io`. Import it from there if `dbus` doesn't re-export it.

- [ ] **Step 4: Implement `portal_notifications.dart`.**

```dart
/// Desktop notifications inside Flatpak: the Notification portal, which
/// needs no permission in the manifest.
library;

import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:matrix/matrix.dart' show Logs;

import '../ui/model/chime.dart';
import '../ui/model/desktop_notifications.dart';
import '../ui/model/message_route.dart';
import '../ui/model/notice.dart';
import 'memfd.dart';

class PortalNotifications implements DesktopNotifications {
  PortalNotifications({
    required this.chime,
    required this.soundFile,
    DBusClient? bus,
    this.sealable = memfdOf,
    void Function(Object error)? log,
  }) : _bus = bus ?? DBusClient.session(),
       _log = log ?? ((e) => Logs().w('[loaf] notification failed', e));

  static const _iface = 'org.freedesktop.portal.Notification';

  final Chime chime;
  final String soundFile;

  /// How the chime becomes a descriptor the portal will take.
  final Future<ResourceHandle?> Function(File file) sealable;
  final DBusClient _bus;
  final void Function(Object error) _log;
  var _logged = false;

  late final _portal = DBusRemoteObject(
    _bus,
    name: 'org.freedesktop.portal.Desktop',
    path: DBusObjectPath('/org/freedesktop/portal/desktop'),
  );

  /// The lower of the portal's and its backend's; 2 takes a sound.
  Future<int>? _version;
  final _shown = <String, MessageRoute>{};
  final _clicks = StreamController<MessageRoute>.broadcast();
  StreamSubscription<DBusSignal>? _invoked;

  Future<int> _portalVersion() => _version ??= _portal
      .getProperty(_iface, 'version', signature: DBusSignature('u'))
      .then((v) => v.asUint32(), onError: (Object _) => 1);

  void _listen() {
    _invoked ??= DBusRemoteObjectSignalStream(
      object: _portal,
      interface: _iface,
      name: 'ActionInvoked',
      signature: DBusSignature('ssav'),
    ).listen((s) {
      if (s.values[1].asString() != 'open') return;
      final route = _shown[s.values[0].asString()] ?? _target(s.values[2]);
      if (route != null) _clicks.add(route);
    });
  }

  /// The default action's target, [room, event]: how a click on a notice
  /// left from an earlier run still finds its message.
  static MessageRoute? _target(DBusValue parameter) {
    final params = parameter.asVariantArray();
    if (params.isEmpty) return null;
    final ids = params.first.asStringArray().toList();
    return ids.length == 2 ? MessageRoute(ids[0], ids[1]) : null;
  }

  void _fail(Object error) {
    if (_logged) return;
    _logged = true;
    _log(error);
  }

  static String _id(MessageRoute r) => 'room:${r.roomId}:${r.eventId}';

  @override
  Future<void> prepare() async {}

  @override
  Future<void> show(Notice notice) async {
    var sounded = false;
    try {
      _listen();
      final version = await _portalVersion();
      final avatar = notice.avatarPath;
      final sound = notice.sound && version >= 2 ? await sealable(File(soundFile)) : null;
      final id = _id(notice.route);
      await _portal.callMethod(_iface, 'AddNotification', [
        DBusString(id),
        DBusDict.stringVariant({
          'title': DBusString(notice.title),
          'body': DBusString(notice.body),
          'default-action': const DBusString('open'),
          'default-action-target': DBusArray.string([notice.route.roomId, notice.route.eventId]),
          if (version >= 2) 'category': const DBusString('im.received'),
          if (avatar != null)
            'icon': DBusStruct([
              const DBusString('bytes'),
              DBusVariant(DBusArray.byte(await File(avatar).readAsBytes())),
            ]),
          if (sound != null)
            'sound': DBusStruct([const DBusString('file-descriptor'), DBusVariant(DBusUnixFd(sound))]),
        }),
      ], replySignature: DBusSignature(''));
      _shown[id] = notice.route;
      sounded = sound != null;
    } on Object catch (e) {
      _fail(e);
    }
    if (notice.sound && !sounded) await chime.play();
  }

  @override
  Future<void> withdraw(String roomId) async {
    final ids = [
      for (final MapEntry(key: id, value: route) in _shown.entries)
        if (route.roomId == roomId) id,
    ];
    for (final id in ids) {
      _shown.remove(id);
      try {
        await _portal.callMethod(_iface, 'RemoveNotification', [DBusString(id)],
            replySignature: DBusSignature(''));
      } on Object catch (e) {
        _fail(e);
      }
    }
  }

  @override
  Stream<MessageRoute> get clicks {
    _listen();
    return _clicks.stream;
  }

  @override
  Future<bool> blocked() async => false;

  @override
  Future<void> openSystemSettings() async {}
}
```

The portal's v2 `category` list includes `im.received`. If xdg-desktop-portal's `supported_categories` in `notification.c` uses a different spelling, match it exactly: an unknown category without the `x-` prefix is **rejected**, which drops the whole notification. Check the scratch copy, or fetch the file again: `gh api repos/flatpak/xdg-desktop-portal/contents/desktop-portal/notification.c -H "Accept: application/vnd.github.raw" | grep -n -A12 supported_categories`.

Close the sound's `RandomAccessFile` once the call returns, in a `finally`, the way `OpenUriPortal.openFile` closes its file (`packages/loaf_media/lib/src/portal.dart:36-54`).

- [ ] **Step 5: Run the tests to see them pass.**

Run: `mise exec -- flutter test test/notify`
Expected: PASS on the Mac, where the memfd test is skipped. The Linux CI job runs the memfd test.

- [ ] **Step 6: Commit.**

```nu
git branch --show-current
git add lib/notify/memfd.dart lib/notify/portal_notifications.dart pubspec.yaml pubspec.lock test/notify
git commit -m "feat(notify): Flatpak notifications through the Notification portal

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 8: macOS and Windows in Dart: the `moe.loaf.chat/notify` channel

**Files:**
- Create: `lib/notify/channel_notifications.dart`
- Test: `test/notify/channel_notifications_test.dart`

**Interfaces:**
- Produces: `ChannelDesktopNotifications({required Chime chime, MethodChannel? channel, void Function(Object)? log})`.

**The channel contract.** Tasks 9 and 10 implement it natively, exactly as written here. Every call carries a map, even an empty one.

| Direction | Method | Arguments | Returns |
|---|---|---|---|
| Dart → native | `prepare` | `{}` | null |
| Dart → native | `show` | `{roomId, eventId, title, body, sender, senderId, place?, avatarPath?, sound: bool}` | `bool`: true if the native side attached the chime |
| Dart → native | `withdraw` | `{roomId}` | null |
| Dart → native | `blocked` | `{}` | `bool` |
| Dart → native | `openSettings` | `{}` | null |
| Dart → native | `ready` | `{}` | null. Clicks held from before now are sent. |
| native → Dart | `click` | `{roomId, eventId}` | null |

- [ ] **Step 1: Write the failing tests.**

```dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/notify/channel_notifications.dart';
import 'package:loaf_native/ui/model/chime.dart';
import 'package:loaf_native/ui/model/message_route.dart';
import 'package:loaf_native/ui/model/notice.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('moe.loaf.chat/notify');
  final calls = <MethodCall>[];
  Object? Function(MethodCall)? answer;
  late FakeChime chime;

  setUp(() {
    calls.clear();
    answer = null;
    chime = FakeChime();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return answer?.call(call);
        });
  });

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  Notice notice({bool sound = true}) => Notice(
    route: const MessageRoute('!r:x', r'$e'),
    sender: 'Ada',
    senderId: '@ada:x',
    place: '#general · Loaf',
    body: 'hi',
    avatarPath: '/tmp/a.png',
    sound: sound,
  );

  Future<void> fromNative(String method, Object? args) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
            (_) {},
          );

  test('show sends every field', () async {
    answer = (c) => true;
    await ChannelDesktopNotifications(chime: chime).show(notice());
    expect(calls.single.method, 'show');
    expect(calls.single.arguments, {
      'roomId': '!r:x',
      'eventId': r'$e',
      'title': 'Ada in #general · Loaf',
      'body': 'hi',
      'sender': 'Ada',
      'senderId': '@ada:x',
      'place': '#general · Loaf',
      'avatarPath': '/tmp/a.png',
      'sound': true,
    });
    expect(chime.plays, 0, reason: 'the platform sounded it');
  });

  test('a platform that could not sound it: the app plays the chime', () async {
    answer = (c) => false;
    await ChannelDesktopNotifications(chime: chime).show(notice());
    expect(chime.plays, 1);
    await ChannelDesktopNotifications(chime: chime).show(notice(sound: false));
    expect(chime.plays, 1);
  });

  test('a failing platform throws nothing, and the chime still plays', () async {
    answer = (c) => throw PlatformException(code: 'x');
    final logged = <Object>[];
    final n = ChannelDesktopNotifications(chime: chime, log: logged.add);
    await n.show(notice());
    await n.show(notice());
    expect(chime.plays, 2);
    expect(logged, hasLength(1));
  });

  test('blocked, withdraw, prepare and openSettings', () async {
    answer = (c) => c.method == 'blocked' ? true : null;
    final n = ChannelDesktopNotifications(chime: chime);
    expect(await n.blocked(), isTrue);
    await n.withdraw('!r:x');
    await n.prepare();
    await n.openSystemSettings();
    expect([for (final c in calls) c.method], ['blocked', 'withdraw', 'prepare', 'openSettings']);
    expect(calls[1].arguments, {'roomId': '!r:x'});
  });

  test('no plugin (a platform without one): blocked is false', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    expect(await ChannelDesktopNotifications(chime: chime).blocked(), isFalse);
  });

  test('the first listener says ready, and only then are held clicks wanted', () async {
    final n = ChannelDesktopNotifications(chime: chime);
    expect(calls, isEmpty);
    final clicks = <MessageRoute>[];
    n.clicks.listen(clicks.add);
    await pumpEventQueue();
    expect(calls.single.method, 'ready');
    await fromNative('click', {'roomId': '!r:x', 'eventId': r'$e'});
    await fromNative('click', {'roomId': 1});
    await pumpEventQueue();
    expect(clicks, [const MessageRoute('!r:x', r'$e')]);
  });
}
```

- [ ] **Step 2: Run them to watch them fail.**

Run: `mise exec -- flutter test test/notify/channel_notifications_test.dart`
Expected: a compile error.

- [ ] **Step 3: Implement.**

```dart
/// Desktop notifications on macOS and Windows: one channel, two native
/// ends. `macos/Runner/NotifyBridge.swift` (UNUserNotificationCenter) and
/// `packages/loaf_notify/windows` (toasts). The contract is in this
/// step's plan, Task 8.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart' show Logs;

import '../ui/model/chime.dart';
import '../ui/model/desktop_notifications.dart';
import '../ui/model/message_route.dart';
import '../ui/model/notice.dart';

class ChannelDesktopNotifications implements DesktopNotifications {
  ChannelDesktopNotifications({
    required this.chime,
    MethodChannel? channel,
    void Function(Object error)? log,
  }) : _channel = channel ?? const MethodChannel('moe.loaf.chat/notify'),
       _log = log ?? ((e) => Logs().w('[loaf] notification failed', e)) {
    _channel.setMethodCallHandler(_handle);
  }

  final Chime chime;
  final MethodChannel _channel;
  final void Function(Object error) _log;
  var _logged = false;

  /// A click can launch the app (macOS), before Dart listens: the native
  /// side holds it until told someone is.
  late final _clicks = StreamController<MessageRoute>.broadcast(
    onListen: () => unawaited(_call<void>('ready')),
  );

  Future<void> _handle(MethodCall call) async {
    if (call.method != 'click') return;
    if (call.arguments case {'roomId': final String room, 'eventId': final String event}) {
      _clicks.add(MessageRoute(room, event));
    }
  }

  Future<T?> _call<T>(String method, [Map<String, Object?> args = const {}]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on Object catch (e) {
      if (!_logged) {
        _logged = true;
        _log(e);
      }
      return null;
    }
  }

  @override
  Future<void> prepare() => _call<void>('prepare');

  @override
  Future<void> show(Notice notice) async {
    final sounded = await _call<bool>('show', {
      'roomId': notice.route.roomId,
      'eventId': notice.route.eventId,
      'title': notice.title,
      'body': notice.body,
      'sender': notice.sender,
      'senderId': notice.senderId,
      'place': notice.place,
      'avatarPath': notice.avatarPath,
      'sound': notice.sound,
    });
    if (notice.sound && sounded != true) await chime.play();
  }

  @override
  Future<void> withdraw(String roomId) => _call<void>('withdraw', {'roomId': roomId});

  @override
  Stream<MessageRoute> get clicks => _clicks.stream;

  @override
  Future<bool> blocked() async => await _call<bool>('blocked') ?? false;

  @override
  Future<void> openSystemSettings() => _call<void>('openSettings');
}
```

The test expects the map to contain `place` and `avatarPath` even when they're null? It sends both non-null, so a map with nulls is fine. Keep the null keys: the Swift and C++ ends read them as optional.

- [ ] **Step 4: Run the tests to see them pass.**

Run: `mise exec -- flutter test test/notify/channel_notifications_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit.**

```nu
git branch --show-current
git add lib/notify/channel_notifications.dart test/notify/channel_notifications_test.dart
git commit -m "feat(notify): the notify channel macOS and Windows answer

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 8b: The macOS bundle id becomes `moe.loaf.chat.ios` (branch `chore/macos-bundle-id`)

Chris decided on 2026-10-08: "Just change the damn identifier." Every macOS build (Debug, Profile and Release) becomes `moe.loaf.chat.ios`, the iOS App ID. **Nothing is moved.** The new id gets a new container, so the Mac app starts signed out once, and signing in plus the recovery key restores the account. This is its own branch, cut from `main` and merged before Task 9, and then `feat/desktop-notices` is rebased onto it.

**Facts the controller checked:**
- **Sparkle 2.10 updates across the id change.** It accepts an update when either the EdDSA signature or Apple code signing is valid (`SUUpdateValidator.m`), and it finds the new app by filename first (`SUInstaller.m:81`). `SUPublicEDKey` must stay as it is.
- **The SSO scheme stays `moe.loaf.native`.** It's a constant of its own (`lib/matrix/sso_browser.dart:40`), and `test/release/ios_identity_test.dart` pins it.

**Files:**
- Modify: `macos/Runner/Configs/AppInfo.xcconfig`, to set `PRODUCT_BUNDLE_IDENTIFIER = moe.loaf.chat.ios`
- Modify: `macos/Runner.xcodeproj/project.pbxproj`, to set the three RunnerTests configurations to `moe.loaf.chat.ios.RunnerTests`
- Create: `test/release/macos_identity_test.dart`

- [ ] **Step 1: Make the worktree.** Create `.claude/worktrees/macos-bundle-id` on `chore/macos-bundle-id`, branched from `origin/main`. Copy vodozemac into it and run `mise trust`.

- [ ] **Step 2: Write the failing test.** Create `test/release/macos_identity_test.dart`:

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the Mac app is moe.loaf.chat.ios, the same App ID as iOS', () {
    expect(File('macos/Runner/Configs/AppInfo.xcconfig').readAsStringSync(),
        contains('PRODUCT_BUNDLE_IDENTIFIER = moe.loaf.chat.ios\n'));
    final project = File('macos/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    expect(project.contains('moe.loaf.native'), isFalse);
  });
}
```

Run `mise exec -- flutter test test/release/macos_identity_test.dart`. Expected: FAIL.

- [ ] **Step 3: Change the ids** listed under Files.

- [ ] **Step 4: Run the checks.**
  - `mise exec -- flutter test`: everything passes, including `ios_identity_test` unchanged.
  - `mise exec -- flutter build macos --debug`, then read `CFBundleIdentifier` from the built app's `Info.plist`: expected `moe.loaf.chat.ios`.
  - `mise exec -- flutter analyze`.

- [ ] **Step 5: Commit.**

```nu
git branch --show-current   # chore/macos-bundle-id
git add macos test/release/macos_identity_test.dart
git commit -m "chore(macos): the bundle id becomes moe.loaf.chat.ios

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 6 (controller):**
  - Merge into `main` the same way as Part 0, and rebase `feat/desktop-notices` onto it.
  - Update the memory `debug-build-shares-data`: the shared id is now `moe.loaf.chat.ios`.
  - It ships with D's release. Tell Chris it signs him out once.

### Task 9: macOS: `NotifyBridge.swift`, communication notifications, and signing

**Files:**
- Create: `macos/Runner/NotifyBridge.swift`
- Modify:
  - `macos/Runner/MainFlutterWindow.swift`;
  - `macos/Runner/Info.plist`, to add `NSUserActivityTypes`;
  - `macos/Runner.xcodeproj/project.pbxproj`, to add `NotifyBridge.swift` to Sources, and `../assets/sounds/chime.wav` to the Runner's Copy Bundle Resources;
  - `tool/release/macos.sh`, `.github/workflows/release.yml`.

**Interfaces:**
- Consumes: the channel contract (Task 8).

- [ ] **Step 1: Write the bridge.** Create `macos/Runner/NotifyBridge.swift`:

```swift
import Cocoa
import FlutterMacOS
import Intents
import UserNotifications

/// Desktop notifications on macOS. Each message is donated as an incoming
/// INSendMessageIntent, so it shows as a communication notification with
/// the sender's picture. That needs Apple's communication entitlement:
/// debug builds carry it through their development profile, releases get
/// it at signing (`tool/release/macos.sh`). Without it the update fails and
/// the plain notification goes. The other end is
/// `lib/notify/channel_notifications.dart`.
final class NotifyBridge: NSObject, UNUserNotificationCenterDelegate {
  private let channel: FlutterMethodChannel
  private let center = UNUserNotificationCenter.current()

  /// Clicks from before Dart listened: a click on a notification left from
  /// the last run launches the app, and arrives before the shell is up.
  private var held: [[String: String]] = []
  private var ready = false

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "moe.loaf.chat/notify", binaryMessenger: messenger)
    super.init()
    // Made from awakeFromNib, before launch finishes: early enough for the
    // click that launched the app.
    center.delegate = self
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "prepare": self.prepare(result)
      case "show": self.show(args, result)
      case "withdraw": self.withdraw(args["roomId"] as? String ?? "", result)
      case "blocked": self.blocked(result)
      case "openSettings":
        self.openSettings()
        result(nil)
      case "ready":
        self.ready = true
        let waiting = self.held
        self.held = []
        waiting.forEach { self.channel.invokeMethod("click", arguments: $0) }
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private func prepare(_ result: @escaping FlutterResult) {
    center.getNotificationSettings { settings in
      guard settings.authorizationStatus == .notDetermined else {
        DispatchQueue.main.async { result(nil) }
        return
      }
      self.center.requestAuthorization(options: [.alert, .sound]) { _, error in
        if let error { NSLog("[loaf notify] permission: \(error)") }
        DispatchQueue.main.async { result(nil) }
      }
    }
  }

  private func show(_ args: [String: Any], _ result: @escaping FlutterResult) {
    guard let roomId = args["roomId"] as? String, let eventId = args["eventId"] as? String
    else {
      result(false)
      return
    }
    let content = UNMutableNotificationContent()
    content.title = args["title"] as? String ?? ""
    content.body = args["body"] as? String ?? ""
    content.threadIdentifier = roomId
    content.userInfo = ["roomId": roomId, "eventId": eventId]
    let sound = args["sound"] as? Bool ?? false
    if sound { content.sound = UNNotificationSound(named: UNNotificationSoundName("chime.wav")) }

    let intent = Self.intent(args, roomId: roomId)
    let interaction = INInteraction(intent: intent, response: nil)
    interaction.direction = .incoming
    interaction.donate { error in
      if let error { NSLog("[loaf notify] donate: \(error)") }
      let shown: UNNotificationContent
      do {
        shown = try content.updating(from: intent)
      } catch {
        NSLog("[loaf notify] plain notification: \(error)")
        shown = content
      }
      // Withdrawn by this prefix: an updated content may not keep the
      // thread id.
      let request = UNNotificationRequest(
        identifier: "\(roomId)|\(eventId)", content: shown, trigger: nil)
      self.center.add(request) { error in
        if let error { NSLog("[loaf notify] \(error)") }
        DispatchQueue.main.async { result(sound) }
      }
    }
  }

  private static func intent(_ args: [String: Any], roomId: String) -> INSendMessageIntent {
    let senderId = args["senderId"] as? String ?? ""
    let image = (args["avatarPath"] as? String)
      .flatMap { FileManager.default.contents(atPath: $0) }
      .map { INImage(imageData: $0) }
    let sender = INPerson(
      personHandle: INPersonHandle(value: senderId, type: .unknown),
      nameComponents: nil,
      displayName: args["sender"] as? String,
      image: image,
      contactIdentifier: nil,
      customIdentifier: senderId)
    let place = args["place"] as? String
    let intent = INSendMessageIntent(
      recipients: nil,
      outgoingMessageType: .outgoingMessageText,
      content: args["body"] as? String,
      speakableGroupName: place.map { INSpeakableString(spokenPhrase: $0) },
      conversationIdentifier: roomId,
      serviceName: nil,
      sender: sender,
      attachments: nil)
    if let image { intent.setImage(image, forParameterNamed: \.sender) }
    return intent
  }

  private func withdraw(_ roomId: String, _ result: @escaping FlutterResult) {
    center.getDeliveredNotifications { delivered in
      let ids = delivered.map(\.request.identifier).filter { $0.hasPrefix("\(roomId)|") }
      self.center.removeDeliveredNotifications(withIdentifiers: ids)
      DispatchQueue.main.async { result(nil) }
    }
  }

  private func blocked(_ result: @escaping FlutterResult) {
    center.getNotificationSettings { settings in
      DispatchQueue.main.async { result(settings.authorizationStatus == .denied) }
    }
  }

  private func openSettings() {
    let id = Bundle.main.bundleIdentifier ?? ""
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
    {
      NSWorkspace.shared.open(url)
    }
  }

  // MARK: UNUserNotificationCenterDelegate

  /// Dart shows one only while the app is not in front. If it is in front
  /// by the time this one lands, show it anyway: it was asked for.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list, .sound])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let info = response.notification.request.content.userInfo
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
      let roomId = info["roomId"] as? String, let eventId = info["eventId"] as? String
    else {
      completionHandler()
      return
    }
    let click = ["roomId": roomId, "eventId": eventId]
    DispatchQueue.main.async {
      if self.ready {
        self.channel.invokeMethod("click", arguments: click)
      } else {
        self.held.append(click)
      }
      completionHandler()
    }
  }
}
```

- [ ] **Step 2: Wire it in, and bundle the chime.**
  - In `MainFlutterWindow.swift`, add `private var notifyBridge: NotifyBridge?`, and after `updaterBridge = …` add `notifyBridge = NotifyBridge(messenger: flutterViewController.engine.binaryMessenger)`.
  - In `Info.plist`, add:

```xml
	<key>NSUserActivityTypes</key>
	<array>
		<string>INSendMessageIntent</string>
	</array>
```

  - In `project.pbxproj`, mirror the four `UpdaterBridge.swift` entries (the lines with `A1B2C3D4E5F60718293A4B01` and `…02`) for `NotifyBridge.swift`, with two fresh 24-hex ids. Use ids that `grep` finds nowhere in the file.
  - For the sound, add a `PBXFileReference` with `path = ../assets/sounds/chime.wav; sourceTree = SOURCE_ROOT; lastKnownFileType = audio.wav; name = chime.wav;`, a `PBXBuildFile` for it, the file ref in the Runner group's children, and the build file in the Runner target's `PBXResourcesBuildPhase`.
  - The checked-in WAV is the one source; nothing is copied.

- [ ] **Step 3: Sign debug builds with the entitlement.** This needs Step 5's App ID capability: run Step 5's first bullet, which is Chris's, before this step. Do it in `project.pbxproj`, on the **Runner target's Debug and Profile** build configurations only (the two that point at `Runner/DebugProfile.entitlements`):
  - set `CODE_SIGN_STYLE = Automatic;`, `DEVELOPMENT_TEAM = 6W2A5N37N3;` and `CODE_SIGN_IDENTITY = "Apple Development";`;
  - leave `PROVISIONING_PROFILE_SPECIFIER = "";` as it is;
  - don't touch the Release configuration, or the project-level `CODE_SIGN_IDENTITY = "-"` entries.

In `macos/Runner/DebugProfile.entitlements`, add:

```xml
	<key>com.apple.developer.usernotifications.communication</key>
	<true/>
```

On the first build, Xcode has to make the development profile and register this Mac. `flutter build` doesn't pass `-allowProvisioningUpdates`, so do it once by hand:

```nu
mise exec -- flutter build macos --debug --config-only
xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -allowProvisioningUpdates build
```

- [ ] **Step 4: Build and check the bundle and the signature.** Quit the installed app first (`pgrep -fl "Loaf Chat"`; Chris allows this for QA):

```nu
mise exec -- flutter build macos --debug
ls "build/macos/Build/Products/Debug/Loaf Chat.app/Contents/Resources/" | where name =~ chime
codesign -d --entitlements - --xml "build/macos/Build/Products/Debug/Loaf Chat.app" | str contains "usernotifications.communication"
ls "build/macos/Build/Products/Debug/Loaf Chat.app/Contents/" | where name =~ provisionprofile
```

Expected:
- the build succeeds;
- `chime.wav` sits in `Contents/Resources`;
- the entitlement is in the signature (`true`);
- `embedded.provisionprofile` is present.

Launch it once with `mise exec -- flutter run -d macos` to prove macOS accepts the profile: a mismatch kills the app at launch.

- [ ] **Step 5: Sign with the profile in releases.**
  - In `tool/release/macos.sh`, after the `PlistBuddy … Delete :com.apple.security.get-task-allow` line (line 32), and before anything is signed:

```sh
# Communication notifications (the sender's picture on a notification) need
# Apple's entitlement, which a Developer ID app may hold only with a
# Developer ID provisioning profile embedded. Without the profile the app
# is signed without it: notifications still show, without pictures.
if [ -n "${MACOS_PROVISION_PROFILE:-}" ]; then
  profile="$app/Contents/embedded.provisionprofile"
  echo "$MACOS_PROVISION_PROFILE" | base64 --decode > "$profile"
  security cms -D -i "$profile" > "$work/profile.plist"
  # A profile without the entitlement would have the app killed at launch.
  /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.usernotifications.communication' "$work/profile.plist" >/dev/null
  /usr/libexec/PlistBuddy -c 'Add :com.apple.developer.usernotifications.communication bool true' "$work/app.entitlements"
  /usr/libexec/PlistBuddy -c 'Add :com.apple.application-identifier string 6W2A5N37N3.moe.loaf.chat.ios' "$work/app.entitlements"
  /usr/libexec/PlistBuddy -c 'Add :com.apple.developer.team-identifier string 6W2A5N37N3' "$work/app.entitlements"
fi
```

    `set -e` (check the script has it) makes the `Print` fail the release when the profile lacks the key.
  - In `.github/workflows/release.yml`'s macOS signing step's `env:`, add `MACOS_PROVISION_PROFILE: ${{ secrets.MACOS_PROVISION_PROFILE }}`.
  - Run `bash -n tool/release/macos.sh` as a syntax check.

- [ ] **Step 6 (Chris, by hand): the capability, then the release profile.**
  1. **Before Step 3:** on developer.apple.com, go to Identifiers, open `moe.loaf.chat.ios`, tick **Communication Notifications**, and save.
  2. Go to Profiles, add one, and choose **Developer ID**. Pick App ID `moe.loaf.chat.ios` and the Developer ID Application certificate. Name it `Loaf Chat Developer ID`, then download it.
  3. In Nushell:

```nu
open --raw ~/Downloads/Loaf_Chat_Developer_ID.provisionprofile | encode base64 | gh secret set MACOS_PROVISION_PROFILE --env release
```

   If the secret is missing, the release still ships, without avatars.

- [ ] **Step 7: Commit.**

```nu
git branch --show-current
git add macos tool/release/macos.sh .github/workflows/release.yml
git commit -m "feat(notify): macOS notifications as communication notifications

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

The hand test is in Task 12.

### Task 10: Windows: `packages/loaf_notify` and the Rust crate `loaf_notify_win`

**Files:**
- Create:
  - `packages/loaf_notify/pubspec.yaml`, `packages/loaf_notify/lib/loaf_notify.dart`, `packages/loaf_notify/.gitignore`;
  - `packages/loaf_notify/windows/CMakeLists.txt`, `loaf_notify_plugin.cpp`, `loaf_notify_plugin.h`, `loaf_notify_plugin_c_api.cpp`, `include/loaf_notify/loaf_notify_plugin_c_api.h`, `include/loaf_notify/loaf_notify_win.h`;
  - `packages/loaf_notify/windows/rust/Cargo.toml`, `Cargo.lock`, and `src/lib.rs`, `src/toast.rs`, `src/notifier.rs`, `src/ffi.rs`.
- Modify: `pubspec.yaml`. Add `loaf_notify: path: packages/loaf_notify`, and the asset `- linux/packaging/moe.loaf.chat.png`, the icon Windows shows beside the app's name.
- Modify: `.github/workflows/ci.yml`. In the Linux job, after the `loaf_streams` cargo test line, add `cargo test --locked --manifest-path packages/loaf_notify/windows/rust/Cargo.toml` in the same style.

**Interfaces:**
- Consumes: the channel contract (Task 8).
- Produces, in `include/loaf_notify/loaf_notify_win.h`:

```c
typedef void (*loaf_notify_click_fn)(void* context, const char* room_id, const char* event_id);
void* loaf_notify_new(loaf_notify_click_fn click, void* context);  // null on failure
void loaf_notify_free(void* notifier);
int32_t loaf_notify_register(void);                                   // 0 ok
int32_t loaf_notify_show(void* notifier, const char* title, const char* body,
                         const char* room_id, const char* event_id,
                         const char* avatar /* nullable */);          // 0 ok
int32_t loaf_notify_withdraw(void* notifier, const char* room_id);    // 0 ok
int32_t loaf_notify_blocked(void);                                    // 1 blocked, 0 not, <0 error
```

- [ ] **Step 1: Write the failing Rust tests.** Create the crate. `Cargo.toml`:

```toml
[package]
name = "loaf_notify_win"
edition = "2024"
rust-version = "1.92"
publish = false

[lib]
crate-type = ["staticlib", "rlib"]

[target.'cfg(windows)'.dependencies]
windows-core = "0.62"
windows = { version = "0.62", features = [
  "Data_Xml_Dom",
  "Foundation",
  "UI_Notifications",
  "Win32_Foundation",
  "Win32_System_Registry",
  "Win32_UI_Shell",
  "Win32_UI_WindowsAndMessaging",
] }

[profile.release]
panic = "unwind"   # catch_unwind at the FFI edge needs unwinding
```

`src/lib.rs`:

```rust
//! The Windows half of `package:loaf_notify`: toasts through
//! `ToastNotificationManager`, under the AUMID the app registers for
//! itself. The C API the plugin calls is `ffi`
//! (`include/loaf_notify/loaf_notify_win.h`).

#![cfg_attr(
    not(test),
    deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)
)]

pub mod toast;

#[cfg(windows)]
pub mod notifier;

#[cfg(windows)]
pub mod ffi;
```

`src/toast.rs` holds the tests first, then the code that makes them pass (Step 3):

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn toast<'a>(body: &'a str, avatar: Option<&'a str>) -> Toast<'a> {
        Toast { title: "Ada in #general · Loaf", body, room_id: "!r:x", event_id: "$e", avatar }
    }

    #[test]
    fn text_is_escaped() {
        let xml = xml(&toast(r#"<b>"hi"</b> & 'co'"#, None));
        assert!(xml.contains("<text>&lt;b&gt;&quot;hi&quot;&lt;/b&gt; &amp; &apos;co&apos;</text>"));
    }

    #[test]
    fn control_characters_are_dropped() {
        assert_eq!(escape("a\u{1}b\u{1b}c\td\ne"), "abc\td\ne");
    }

    #[test]
    fn a_toast_is_silent_and_launches_its_message() {
        let xml = xml(&toast("hi", None));
        assert!(xml.contains(r#"<audio silent="true"/>"#));
        assert!(xml.starts_with(r#"<toast launch="!r:x $e">"#));
        assert!(!xml.contains("<image"));
    }

    #[test]
    fn the_avatar_is_a_round_logo_by_file_uri() {
        let xml = xml(&toast("hi", Some(r"C:\Users\Chris T\AppData\Local\Temp\a#1.png")));
        assert!(xml.contains(
            r#"<image placement="appLogoOverride" hint-crop="circle" src="file:///C:/Users/Chris%20T/AppData/Local/Temp/a%231.png"/>"#
        ));
    }

    #[test]
    fn launch_round_trips() {
        assert_eq!(parse_launch(&launch("!r:x", "$e")), Some(("!r:x", "$e")));
        assert_eq!(parse_launch("nothing"), None);
        assert_eq!(parse_launch(" $e"), None);
        assert_eq!(parse_launch("!r:x "), None);
    }

    #[test]
    fn keys_are_stable_and_fit_windows_limits() {
        let long = "!".repeat(300);
        assert_eq!(key(&long).len(), 16);
        assert_eq!(key("!r:x"), key("!r:x"));
        assert_ne!(key("!r:x"), key("!r:y"));
        // FNV-1a 64 of the empty string: pinned, so a build can't change it
        // and strand toasts from an earlier run.
        assert_eq!(key(""), "cbf29ce484222325");
    }

    #[test]
    fn a_long_body_still_makes_a_toast_under_5_kb() {
        // Dart cuts bodies at 400 characters; every one of them might
        // escape to six bytes.
        let body = "&".repeat(400);
        assert!(xml(&toast(&body, Some(r"C:\a.png"))).len() < 5 * 1024);
    }
}
```

- [ ] **Step 2: Run them to watch them fail.**

Run: `cargo test --manifest-path packages/loaf_notify/windows/rust/Cargo.toml`
Expected: a compile error: `Toast`, `xml` and the rest are undefined.

- [ ] **Step 3: Implement `toast.rs`.** Put this above the tests:

```rust
//! What a message's toast says, as Windows' toast XML. Pure, so it is
//! tested on any host.

/// One notification. [avatar] is a picture on disk, drawn as the toast's
/// round logo.
pub struct Toast<'a> {
    pub title: &'a str,
    pub body: &'a str,
    pub room_id: &'a str,
    pub event_id: &'a str,
    pub avatar: Option<&'a str>,
}

/// XML-escaped [text], without the characters XML 1.0 can't hold at all:
/// a message may carry any of them, and one would sink the toast.
pub fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            '\t' | '\n' | '\r' => out.push(c),
            c if c < ' ' || c == '\u{fffe}' || c == '\u{ffff}' => {}
            c => out.push(c),
        }
    }
    out
}

/// What a click hands back: the room and the event, split by a space,
/// which Matrix ids never contain.
pub fn launch(room_id: &str, event_id: &str) -> String {
    format!("{room_id} {event_id}")
}

pub fn parse_launch(args: &str) -> Option<(&str, &str)> {
    let (room, event) = args.split_once(' ')?;
    (!room.is_empty() && !event.is_empty() && !event.contains(' ')).then_some((room, event))
}

/// `C:\a b\c.png` as `file:///C:/a%20b/c.png`, the form a toast's image takes.
pub fn file_uri(path: &str) -> String {
    let mut uri = String::from("file:///");
    for c in path.chars() {
        match c {
            '\\' => uri.push('/'),
            ' ' => uri.push_str("%20"),
            '%' => uri.push_str("%25"),
            '#' => uri.push_str("%23"),
            '?' => uri.push_str("%3F"),
            c => uri.push(c),
        }
    }
    uri
}

/// A toast's group (by room) and tag (by event). Windows caps both at 64
/// characters, and a room id may be longer. FNV-1a 64 is stable across
/// runs and builds, so a toast left from an earlier run can still be
/// withdrawn.
pub fn key(id: &str) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in id.bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{hash:016x}")
}

pub fn xml(toast: &Toast) -> String {
    let image = toast
        .avatar
        .map(|path| {
            format!(
                r#"<image placement="appLogoOverride" hint-crop="circle" src="{}"/>"#,
                escape(&file_uri(path))
            )
        })
        .unwrap_or_default();
    format!(
        r#"<toast launch="{}"><visual><binding template="ToastGeneric"><text>{}</text><text>{}</text>{image}</binding></visual><audio silent="true"/></toast>"#,
        escape(&launch(toast.room_id, toast.event_id)),
        escape(toast.title),
        escape(toast.body),
    )
}
```

The launch argument escapes `$e` to `$e`, unchanged, which is why the test expects `launch="!r:x $e"`.

- [ ] **Step 4: Run the tests to see them pass.**

Run:

```nu
cargo test --manifest-path packages/loaf_notify/windows/rust/Cargo.toml
cargo generate-lockfile --manifest-path packages/loaf_notify/windows/rust/Cargo.toml
```

Expected: 7 tests pass, and `Cargo.lock` is written.

- [ ] **Step 5: Write `notifier.rs` (Windows only).** Check each WinRT signature against `windows` 0.62 first (see Global Constraints).

```rust
//! Toasts under the app's AUMID, each kept until withdrawn so its
//! Activated handler stays alive. Clicks arrive on a WinRT thread; the
//! callback must hand them to the platform thread itself.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use windows::Data::Xml::Dom::XmlDocument;
use windows::Foundation::TypedEventHandler;
use windows::UI::Notifications::{
    NotificationSetting, ToastActivatedEventArgs, ToastNotification, ToastNotificationManager,
};
use windows::Win32::System::Registry::{HKEY_CURRENT_USER, REG_SZ, RegSetKeyValueW};
use windows::core::{HSTRING, IInspectable, Interface, PCWSTR, Result};

use crate::toast::{Toast, key, parse_launch, xml};

pub const AUMID: &str = "moe.loaf.chat";

pub type Clicked = Arc<dyn Fn(&str, &str) + Send + Sync>;

pub struct Notifier {
    clicked: Clicked,
    shown: Mutex<HashMap<String, Vec<ToastNotification>>>,
}

impl Notifier {
    pub fn new(clicked: Clicked) -> Self {
        Self { clicked, shown: Mutex::new(HashMap::new()) }
    }

    pub fn show(&self, toast: &Toast) -> Result<()> {
        let doc = XmlDocument::new()?;
        doc.LoadXml(&HSTRING::from(xml(toast)))?;
        let notification = ToastNotification::CreateToastNotification(&doc)?;
        let group = key(toast.room_id);
        notification.SetGroup(&HSTRING::from(group.as_str()))?;
        notification.SetTag(&HSTRING::from(key(toast.event_id)))?;
        let clicked = self.clicked.clone();
        notification.Activated(&TypedEventHandler::<ToastNotification, IInspectable>::new(
            move |_, args| {
                // Check this closure's argument types against windows 0.62:
                // `windows_core::Ref<'_, IInspectable>` there, with
                // `.as_ref()` / `.ok()` to reach the value.
                if let Some(args) = args.as_ref() {
                    if let Ok(args) = args.cast::<ToastActivatedEventArgs>() {
                        let launch = args.Arguments()?.to_string();
                        if let Some((room, event)) = parse_launch(&launch) {
                            clicked(room, event);
                        }
                    }
                }
                Ok(())
            },
        ))?;
        ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(AUMID))?
            .Show(&notification)?;
        if let Ok(mut shown) = self.shown.lock() {
            shown.entry(group).or_default().push(notification);
        }
        Ok(())
    }

    pub fn withdraw(&self, room_id: &str) -> Result<()> {
        let group = key(room_id);
        ToastNotificationManager::History()?
            .RemoveGroupWithId(&HSTRING::from(group.as_str()), &HSTRING::from(AUMID))?;
        if let Ok(mut shown) = self.shown.lock() {
            shown.remove(&group);
        }
        Ok(())
    }
}

pub fn blocked() -> Result<bool> {
    let setting = ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(AUMID))?
        .Setting()?;
    Ok(setting != NotificationSetting::Enabled)
}

/// The name and icon Windows shows beside the app's toasts. An unpackaged
/// app may register these for itself under HKCU.
pub fn register(icon: &std::path::Path) -> Result<()> {
    let key = HSTRING::from(format!(r"Software\Classes\AppUserModelId\{AUMID}"));
    set(&key, "DisplayName", "Loaf Chat")?;
    set(&key, "IconUri", &icon.to_string_lossy())
}

fn set(key: &HSTRING, name: &str, value: &str) -> Result<()> {
    let wide: Vec<u16> = value.encode_utf16().chain(std::iter::once(0)).collect();
    let name = HSTRING::from(name);
    // SAFETY: every pointer is to a live, NUL-terminated wide string;
    // the length is the data's in bytes, NUL included.
    unsafe {
        RegSetKeyValueW(
            HKEY_CURRENT_USER,
            PCWSTR(key.as_ptr()),
            PCWSTR(name.as_ptr()),
            REG_SZ.0,
            Some(wide.as_ptr().cast()),
            u32::try_from(wide.len() * 2).unwrap_or(u32::MAX),
        )
        .ok()
    }
}

/// Where Flutter bundles the app icon asset for the running exe.
pub fn icon_path() -> Option<std::path::PathBuf> {
    let exe = std::env::current_exe().ok()?;
    Some(
        exe.parent()?
            .join("data")
            .join("flutter_assets")
            .join("linux")
            .join("packaging")
            .join("moe.loaf.chat.png"),
    )
}
```

- [ ] **Step 6: Write `ffi.rs` (Windows only).** Model it on `packages/loaf_media/windows/rust/src/ffi.rs`, with its `guard`, `string` and status constants, which you should copy:

```rust
//! The C API `loaf_notify_plugin.cpp` calls. Every entry point catches
//! panics; strings are UTF-8 and NUL-terminated.

use std::ffi::{CStr, CString, c_char, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Arc;

use crate::notifier::{self, Notifier};
use crate::toast::Toast;

const OK: i32 = 0;
const PANICKED: i32 = -1;
const BAD_STRING: i32 = -2;
const FAILED: i32 = -3;
const NULL: i32 = -4;

pub type ClickFn = unsafe extern "C" fn(context: *mut c_void, room_id: *const c_char, event_id: *const c_char);

/// The plugin's pointer, sent to the WinRT thread a click arrives on. The
/// plugin outlives the notifier, and its callback only posts a message.
struct Context(*mut c_void);
// SAFETY: see above; the pointer is never dereferenced here.
unsafe impl Send for Context {}
unsafe impl Sync for Context {}

fn guard(f: impl FnOnce() -> i32) -> i32 {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(PANICKED)
}

/// # Safety
/// [s] is null or a NUL-terminated string that outlives the call.
unsafe fn string<'a>(s: *const c_char) -> Result<&'a str, i32> {
    if s.is_null() {
        return Err(BAD_STRING);
    }
    // SAFETY: forwarded from this function's contract.
    unsafe { CStr::from_ptr(s) }.to_str().map_err(|_| BAD_STRING)
}

fn status(result: windows::core::Result<()>) -> i32 {
    match result {
        Ok(()) => OK,
        Err(_) => FAILED,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn loaf_notify_new(click: ClickFn, context: *mut c_void) -> *mut c_void {
    catch_unwind(|| {
        let context = Context(context);
        let clicked: notifier::Clicked = Arc::new(move |room, event| {
            let (Ok(room), Ok(event)) = (CString::new(room), CString::new(event)) else {
                return;
            };
            // SAFETY: the plugin's callback copies both strings before
            // returning; they live until then.
            unsafe { click(context.0, room.as_ptr(), event.as_ptr()) };
        });
        Box::into_raw(Box::new(Notifier::new(clicked))).cast::<c_void>()
    })
    .unwrap_or(std::ptr::null_mut())
}

/// # Safety
/// [notifier] came from `loaf_notify_new`, and is not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_notify_free(notifier: *mut c_void) {
    if notifier.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: forwarded from this function's contract.
        drop(unsafe { Box::from_raw(notifier.cast::<Notifier>()) });
    }));
}

#[unsafe(no_mangle)]
pub extern "C" fn loaf_notify_register() -> i32 {
    guard(|| match notifier::icon_path() {
        Some(icon) => status(notifier::register(&icon)),
        None => FAILED,
    })
}

/// # Safety
/// [notifier] came from `loaf_notify_new`; the strings follow `string`'s
/// contract; [avatar] may be null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_notify_show(
    notifier: *mut c_void,
    title: *const c_char,
    body: *const c_char,
    room_id: *const c_char,
    event_id: *const c_char,
    avatar: *const c_char,
) -> i32 {
    guard(|| {
        if notifier.is_null() {
            return NULL;
        }
        // SAFETY: forwarded from this function's contract.
        let fields = unsafe {
            (|| Ok::<_, i32>((string(title)?, string(body)?, string(room_id)?, string(event_id)?)))()
        };
        let (title, body, room_id, event_id) = match fields {
            Ok(f) => f,
            Err(e) => return e,
        };
        // SAFETY: as above; null means no picture.
        let avatar = if avatar.is_null() { None } else { unsafe { string(avatar) }.ok() };
        // SAFETY: forwarded from this function's contract.
        let notifier = unsafe { &*notifier.cast::<Notifier>() };
        status(notifier.show(&Toast { title, body, room_id, event_id, avatar }))
    })
}

/// # Safety
/// As `loaf_notify_show`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_notify_withdraw(notifier: *mut c_void, room_id: *const c_char) -> i32 {
    guard(|| {
        if notifier.is_null() {
            return NULL;
        }
        // SAFETY: forwarded from this function's contract.
        match unsafe { string(room_id) } {
            Ok(room_id) => status(unsafe { &*notifier.cast::<Notifier>() }.withdraw(room_id)),
            Err(e) => e,
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn loaf_notify_blocked() -> i32 {
    guard(|| match notifier::blocked() {
        Ok(true) => 1,
        Ok(false) => 0,
        Err(_) => FAILED,
    })
}
```

Check it:

```nu
with-env { PATH: ($env.PATH | prepend ($env.HOME | path join .rustup/toolchains/1.96.1-aarch64-apple-darwin/bin)) } {
  cargo check --target x86_64-pc-windows-msvc --manifest-path packages/loaf_notify/windows/rust/Cargo.toml
  cargo clippy --target x86_64-pc-windows-msvc --manifest-path packages/loaf_notify/windows/rust/Cargo.toml -- -D warnings
}
```

Expected: no errors and no warnings. Fix the WinRT signatures until it compiles; don't silence clippy.

- [ ] **Step 7: Write the plugin.** Copy `packages/loaf_media`'s Windows plugin scaffolding, renaming `loaf_media` to `loaf_notify` and `LoafMedia` to `LoafNotify`.

`packages/loaf_notify/pubspec.yaml`:

```yaml
name: loaf_notify
description: "Windows toasts for Loaf Chat's desktop notifications."
publish_to: none

environment:
  sdk: ^3.13.4
  flutter: '>=3.3.0'

dependencies:
  flutter:
    sdk: flutter

flutter:
  plugin:
    platforms:
      windows:
        pluginClass: LoafNotifyPluginCApi
```

`lib/loaf_notify.dart` holds only a library doc. The Dart end is `lib/notify/channel_notifications.dart` in the app:

```dart
/// Native only: Windows answers `moe.loaf.chat/notify`, whose Dart end is
/// the app's `lib/notify/channel_notifications.dart`.
library;
```

`.gitignore`: `/build/`, `/pubspec.lock`, `.dart_tool/`, `/windows/rust/target/`.

`windows/CMakeLists.txt`: as `loaf_media`'s, with the cargo block pointing at `windows/rust`, the library `loaf_notify_win.lib`, and the link line `kernel32 advapi32 ntdll userenv ws2_32 bcrypt synchronization ole32 oleaut32 runtimeobject shell32 user32`.

The plugin class (`loaf_notify_plugin.h/.cpp`) is the core of the C++. It has:
- a `Channel` named `moe.loaf.chat/notify`;
- `RegisterTopLevelWindowProcDelegate`, as `loaf_media` uses it;
- `const UINT kClickMessage = RegisterWindowMessageW(L"moe.loaf.chat.notify.click");`;
- a `notifier_` made in the constructor with `loaf_notify_new(&LoafNotifyPlugin::OnClick, this)`, and freed in the destructor before the window-proc delegate is unregistered.

```cpp
// On a WinRT thread: copy the ids and post them to the platform thread,
// where the channel may be used.
void LoafNotifyPlugin::OnClick(void* context, const char* room_id, const char* event_id) {
  auto* plugin = static_cast<LoafNotifyPlugin*>(context);
  auto* click = new std::pair<std::string, std::string>(room_id, event_id);
  if (plugin->window_ == nullptr ||
      !PostMessageW(plugin->window_, kClickMessage, 0, reinterpret_cast<LPARAM>(click))) {
    delete click;
  }
}

std::optional<LRESULT> LoafNotifyPlugin::HandleWindowProc(HWND, UINT message, WPARAM, LPARAM lparam) {
  if (message != kClickMessage) return std::nullopt;
  std::unique_ptr<std::pair<std::string, std::string>> click(
      reinterpret_cast<std::pair<std::string, std::string>*>(lparam));
  channel_->InvokeMethod("click", std::make_unique<EncodableValue>(EncodableMap{
      {EncodableValue("roomId"), EncodableValue(click->first)},
      {EncodableValue("eventId"), EncodableValue(click->second)},
  }));
  return 0;
}
```

`HandleMethodCall` answers each method in the contract:
- `prepare`: `loaf_notify_register()`, then `Success()`. A failure is logged with `OutputDebugStringA`, and still answered `Success()`: the toasts still show, just without the name and icon.
- `show`: reads the strings with `StringArg` (copy it from `loaf_media`), passing `nullptr` for a missing `avatarPath`. It calls `loaf_notify_show`, then answers `Success(EncodableValue(false))`, because Windows never attaches the chime. On a non-zero status it answers `Error("notify-failed", …)`, so Dart logs it and plays the chime.
- `withdraw`: calls `loaf_notify_withdraw`, and answers `Success()` or `Error`.
- `blocked`: answers `Success(EncodableValue(loaf_notify_blocked() == 1))`.
- `openSettings`: calls `ShellExecuteW(nullptr, L"open", L"ms-settings:notifications", nullptr, nullptr, SW_SHOWNORMAL)`, then `Success()`.
- `ready`: answers `Success()`. A toast's click arrives only in a running app, so nothing is ever held.
- Anything else answers `NotImplemented()`.

Add to the app `pubspec.yaml`:

```yaml
  loaf_notify:
    path: packages/loaf_notify
```

Under `flutter: assets:`, add `- linux/packaging/moe.loaf.chat.png`. Run `mise exec -- flutter pub get`. The C++ can't be built on this Mac: the first Windows build is the release run (Windows CI is `if: false`). Review it against `loaf_media_plugin.cpp` line by line.

- [ ] **Step 8: Run the checks.**

Run `mise exec -- flutter test` (expected: PASS, since the plugin has no Dart behaviour), the Rust tests, and the Windows `cargo check` and `clippy` from Step 6.

- [ ] **Step 9: Commit.**

```nu
git branch --show-current
git add packages/loaf_notify pubspec.yaml pubspec.lock .github/workflows/ci.yml
git commit -m "feat(notify): Windows toasts in packages/loaf_notify

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 11: Pick the implementation, and wire clicks to the shell

**Files:**
- Create: `lib/notify/pick_notifications.dart`
- Modify: `lib/main.dart`, `lib/ui/auth/session_root.dart`
- Test: `test/notify/pick_notifications_test.dart`

**Interfaces:**
- Produces:
  - `DesktopNotifications? pickDesktopNotifications({required Chime chime, TargetPlatform? platform, Map<String, String>? environment, String? executable})`.
  - `String bundledChime(String executable)`.
  - `Stream<MessageRoute> fronted(Stream<MessageRoute> clicks, {Future<void> Function()? front})`.
  - `SessionRoot({…, Stream<MessageRoute>? routes})`.

- [ ] **Step 1: Write the failing tests.**

```dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/notify/channel_notifications.dart';
import 'package:loaf_native/notify/fdo_notifications.dart';
import 'package:loaf_native/notify/pick_notifications.dart';
import 'package:loaf_native/notify/portal_notifications.dart';
import 'package:loaf_native/ui/model/chime.dart';
import 'package:loaf_native/ui/model/message_route.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final chime = FakeChime();

  Type? pick(TargetPlatform p, [Map<String, String> env = const {}]) =>
      pickDesktopNotifications(chime: chime, platform: p, environment: env, executable: '/app/loaf-chat')
          ?.runtimeType;

  test('each desktop gets its own; phones get none', () {
    expect(pick(TargetPlatform.macOS), ChannelDesktopNotifications);
    expect(pick(TargetPlatform.windows), ChannelDesktopNotifications);
    expect(pick(TargetPlatform.linux), FdoNotifications);
    expect(pick(TargetPlatform.linux, {'FLATPAK_ID': 'moe.loaf.chat'}), PortalNotifications);
    expect(pick(TargetPlatform.iOS), isNull);
    expect(pick(TargetPlatform.android), isNull);
  });

  test('the chime file sits in the bundle beside the exe', () {
    expect(bundledChime('/app/loaf-chat'), '/app/data/flutter_assets/assets/sounds/chime.wav');
  });

  test('a click brings the window forward before it is followed', () async {
    final clicks = StreamController<MessageRoute>();
    final order = <String>[];
    final routes = fronted(clicks.stream, front: () async => order.add('front'));
    routes.listen((r) => order.add(r.roomId));
    clicks.add(const MessageRoute('!r', r'$e'));
    await pumpEventQueue();
    expect(order, ['front', '!r']);
  });

  test('a window that cannot come forward still follows the click', () async {
    final clicks = StreamController<MessageRoute>();
    final got = <MessageRoute>[];
    fronted(clicks.stream, front: () async => throw StateError('no')).listen(got.add);
    clicks.add(const MessageRoute('!r', r'$e'));
    await pumpEventQueue();
    expect(got, hasLength(1));
  });
}
```

The `FdoNotifications` and `PortalNotifications` built in the test make D-Bus clients lazily. If constructing one connects at once, give both a lazy `_bus` (`late final`) so this test opens no socket.

- [ ] **Step 2: Run them to watch them fail.**

Run: `mise exec -- flutter test test/notify/pick_notifications_test.dart`
Expected: a compile error.

- [ ] **Step 3: Implement.**

```dart
/// Which desktop notifications this platform gets, and the clicks they
/// send, made to bring the window forward first.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:window_to_front/window_to_front.dart';

import '../ui/model/chime.dart';
import '../ui/model/desktop_notifications.dart';
import '../ui/model/message_route.dart';
import 'channel_notifications.dart';
import 'fdo_notifications.dart';
import 'portal_notifications.dart';

DesktopNotifications? pickDesktopNotifications({
  required Chime chime,
  TargetPlatform? platform,
  Map<String, String>? environment,
  String? executable,
}) {
  final exe = executable ?? Platform.resolvedExecutable;
  return switch (platform ?? defaultTargetPlatform) {
    TargetPlatform.macOS || TargetPlatform.windows => ChannelDesktopNotifications(chime: chime),
    TargetPlatform.linux when (environment ?? Platform.environment).containsKey('FLATPAK_ID') =>
      PortalNotifications(chime: chime, soundFile: bundledChime(exe)),
    TargetPlatform.linux => FdoNotifications(chime: chime, soundFile: bundledChime(exe)),
    _ => null,
  };
}

/// Where Flutter bundles the chime on Linux: `data/flutter_assets` beside
/// the exe, inside Flatpak and out.
String bundledChime(String executable) => [
  File(executable).parent.path,
  'data',
  'flutter_assets',
  chimeAsset,
].join(Platform.pathSeparator);

/// [clicks], each brought to the front before it is followed. One stream
/// for the app's life: a shell that opens later listens again.
Stream<MessageRoute> fronted(
  Stream<MessageRoute> clicks, {
  Future<void> Function()? front,
}) => clicks
    .asyncMap((route) async {
      try {
        await (front ?? WindowToFront.activate)();
      } on Object {
        // A window that can't come forward still opens the message.
      }
      return route;
    })
    .asBroadcastStream();
```

`chimeAsset` uses `/`. On Linux the separator is `/` too, which matches the test.

In `lib/main.dart`, build the chime once, pick the notifications, pass them to the controller, and pass routes to `SessionRoot`:

```dart
/// Where clicked notifications lead, for the app's life; null without them.
Stream<MessageRoute>? noticeRoutes;
```

In `main()`:

```dart
  final chime = NativeChime();
  final desktop = backend == 'mock' ? null : pickDesktopNotifications(chime: chime);
  notifications = await NotificationController.load(
    backend == 'mock'
        ? MemoryNotificationStore()
        : await FileNotificationStore.inSupportDirectory(),
    chime: chime,
    desktop: desktop,
  );
  noticeRoutes = desktop == null ? null : fronted(desktop.clicks);
```

Pass `routes: noticeRoutes` to `SessionRoot`. Then in `session_root.dart`, add the field below and pass `routes: widget.routes` to `AppShell`:

```dart
  /// Where clicked notifications lead; the shell follows them.
  final Stream<MessageRoute>? routes;
```

- [ ] **Step 4: Run the tests to see them pass.**

Run: `mise exec -- flutter test`
Expected: everything passes. Record the count in the ledger. Also run `mise exec -- flutter analyze` and `mise exec -- dart format lib test packages`.

- [ ] **Step 5: Commit.**

```nu
git branch --show-current
git add lib/notify/pick_notifications.dart lib/main.dart lib/ui/auth/session_root.dart test/notify/pick_notifications_test.dart
git commit -m "feat(notify): pick each desktop's notifications, and follow their clicks

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 12 (controller, not a subagent): hand test on macOS with mochi, then release

This follows the handoff's "Hand-testing D" steps. **Chris supplies a fresh mochi token. Never ask for or handle mochi's password.**

1. Rebuild the throwaway sender: an untracked `flutter test` file, with `openClient(databasePath: <scratchpad>/mochi.sqlite)`, `vod.init(libraryPath: 'build/vodozemac/')`, `client.init(newToken:, newUserID: '@hermes:loaf.moe', newDeviceID: <the token's device>, newHomeserver: Uri.parse('https://matrix.loaf.moe'))`, `client.updateUserDeviceKeys()`, and `room.sendTextEvent(…)` into `!brDPkxPs30Snk1wS0q:loaf.moe`.
2. The debug build is `moe.loaf.chat.ios` after Task 8b, with a fresh container. Its first launch needs Chris to sign in through SSO and enter the recovery key. Run `pgrep -fl "Loaf Chat"`, quit the installed copy through its menu, then run `mise exec -- flutter run -d macos` in the background, logging to the scratchpad. Get full-screen computer-use approval.
3. Check these, with screenshots of each:
   - On first open the permission prompt appears. Allow it.
   - Background the app, with another app frontmost, and send from mochi. A communication notification appears with mochi's picture and name, and its body is the text. The debug build carries the entitlement (Task 9, Step 3), so a plain banner with the app icon is a **failure**.
   - Click the banner. The app comes forward and opens the DM at that message, which glows.
   - Send two messages within a second while in the background. You hear one chime and see two banners.
   - Read the DM, on this device or on Chris's phone. The DM's banners leave Notification Center.
   - Turn **show message text** off. The body reads `new message`.
   - Turn **notifications** off. Nothing appears.
   - Deny permission in System Settings. Settings shows the blocked line, **open system settings** opens the right pane, and re-allowing it removes the line when you come back.
   - Quit the app with a banner still in Notification Center, then click it. The app launches and opens the message after its first sync.
4. Revert any temporary `NSLog`/`debugPrint`. Quit through the menu, run `open -a "/Applications/Loaf Chat.app"`, delete `mochi.sqlite`, and log out the mochi token (`POST /_matrix/client/v3/logout`).
5. Request the whole-branch review: Opus, `superpowers:requesting-code-review`. Then merge into `main` from a worktree, with the merge commit on top of `origin/main`, the full suite run on the merged tree, and a push to `main`.
6. Tag the next free version (`git tag --sort=-v:refname | first`; v0.1.17 is taken), push it, and watch the `release` run. It is the first build of the Windows plugin and of the profile-signed macOS app.
7. Once the release is out, check these on it:
   - The macOS DMG launches, which proves the release profile and entitlement match.
   - Windows and Linux: whatever Chris can try. Otherwise list them as unverified in the handoff, the way C's iOS checks were.
