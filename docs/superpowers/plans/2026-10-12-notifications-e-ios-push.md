# Notifications E: iOS Push Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When Loaf Chat on iPhone is in the background or closed, a message the push rules say should notify arrives as a notification. It is decrypted on the phone, is titled like a desktop notice, and plays the chime. Tapping it opens the message. Once the room is read, its notifications are withdrawn. A message the rules say should *not* notify is dropped on the phone, after it is decrypted, and never shown: in an encrypted room the server cannot tell a mention from anything else, so the phone decides.

> **Revised for the filtering entitlement.** Apple granted
> `com.apple.developer.usernotifications.filtering` (Chris, November 2026).
> The first draft of this plan was written without it and said so in its
> constraints: the extension evaluated no rules, could not drop a push, and
> the app worked around it by disabling `.m.rule.encrypted` alongside
> `.m.rule.message`, which left mentions in mentions-only encrypted channels
> unpushed. That workaround is gone. Tasks 1, 2 and 3 are done and unchanged.
> Tasks 3a, 3b and 5a are new; Tasks 6, 7, 11, 12 and 13 changed.
> **Execution order:** 1, 2, 3 (done), 3a, 3b, 4, 5, 5a, 6, 7, 8, 9, 10, 11, 12, 13.

**Architecture:**
- **Pusher.** Release builds register an `http` pusher with `event_id_only` under the one app id `moe.loaf.chat.ios`, sending to the Loaf Chat gateway `https://push.matrix.loaf.moe/_matrix/push/v1/notify`, a constant in the source as Element X and FluffyChat do.
- **Shared storage.** The SDK database, `notifications.json` and a new `names.json` move into the App Group `group.moe.loaf.chat`, so the extension can read them.
- **The extension.** A Notification Service Extension (Swift) reads the token and the room key from the database and fetches the event. It decrypts with `loaf_push`, a Rust `cdylib` wrapping vodozemac, then asks the same crate whether the account's push rules notify for the decrypted event, and delivers nothing when they do not. A Dart build hook builds `loaf_push` (the same pattern as `loaf_notify` on Windows), Flutter embeds it in the app's `Frameworks/`, and the extension loads it with `dlopen`/`dlsym`.
- **Testable Swift.** The extension's logic lives in a local Swift package, `ios/LoafPushCore`, tested with `swift test`, the same pattern as `LoafMediaCore`.

**Tech Stack:**
- Dart/Flutter: the `matrix` 13.0.0 SDK, `hooks`/`code_assets`, and `path_provider_foundation` (`getContainerPath`).
- Rust: `vodozemac` 0.10.0, the version `flutter_vodozemac` 0.8.1 pins.
- Swift: UserNotifications, SQLite3 (the system library) and Foundation.

**Spec:** `docs/superpowers/specs/2026-10-06-notifications-design.md`. The binding sections are "E. iOS push", "Settings" (iOS and "everywhere you're signed in") and "Testing" (the two iOS lines).

## Global Constraints

- **Decisions Chris made on 2026-10-12:**
  - **Apple account.** Chris has already set these up: the App Group `group.moe.loaf.chat`, the Push Notifications and App Groups capabilities on `moe.loaf.chat.ios`, and the app id `moe.loaf.chat.ios.notify`.
    - The macOS release still finds its "Loaf Chat Developer ID" profile ACTIVE (the v0.1.19 run). Nothing in this plan touches macOS signing.
    - **CI creates nothing new in Apple's account** beyond what the existing iOS cloud-signing export already does. If the first E release fails on a missing capability, stop and tell Chris. Don't add `-allowProvisioningUpdates` scope or new API calls.
  - **`loaf_push` gets into the extension through a Dart build hook plus `dlopen`.** There is no C header, no module map and no Xcode Run Script. Every new file is Dart, Rust or Swift (memory `dart-or-rust-only`).
    - Accepted cost: the iOS release job now compiles Rust for `aarch64-apple-ios`, and `mise.toml` gains the iOS Rust targets.
  - **The gateway is a constant** (Chris, 2026-10-12): `https://push.matrix.loaf.moe/_matrix/push/v1/notify`, used by every user on every homeserver, the way Element X uses matrix.org and FluffyChat uses push.fluffychat.im. The gateway is a separate Rust project (another session); the app only needs its URL.
  - **One app id, no `.dev`.** The pusher's `app_id` is always `moe.loaf.chat.ios`. Only release builds (`kReleaseMode`) register a pusher. Debug builds never do. Push is tested on TestFlight.
- **Decisions after Apple granted filtering (2026-11-09):**
- **The filtering entitlement is granted**, so the extension evaluates the
  push rules itself and drops what they silence. There is no build setting
  and no second code path: filtering is the only behaviour.
  - `.m.rule.encrypted` is left enabled, always. Every encrypted message
    reaches the phone and the phone decides. The Channels default writes
    `.m.rule.message` alone (Task 11).
  - **The evaluator is Rust, in `loaf_push`** (Aria's call, not Chris's).
    The alternative was Swift in `LoafPushCore`. CI runs one Ubuntu job:
    `cargo test` runs there on every PR, while the Swift package tasks say
    "needs a Mac" and run only by hand (`mise.toml`, `test:media:apple`). A
    Swift evaluator would be the one piece of notification logic that
    nothing pins, next to a Dart implementation whose 245 cases are pinned
    on every push. Rust also needs no new plumbing: the extension already
    `dlopen`s the crate for decryption, so this is a third symbol.
  - **Parity with the app is pinned by a shared corpus** (Task 3b), the
    same trick Task 2 uses for the storage format: the Dart rules test
    writes every case it already runs, and a Rust test must answer each the
    same way. Dart and Rust drifting apart fails CI on Linux.
  - **It fails open.** Where the extension cannot judge a message — no room
    key, a fetch that failed, `rules.json` missing or unreadable — it shows
    it rather than dropping it. A notification you did not need is a smaller
    harm than a mention you never saw, and a silent drop is invisible to
    the user (memory `honest-controls`).

- **Deviations from the spec, all in the direction of plain:**
  - **Device settings stay in `notifications.json`.** It moves into the App Group on iOS. Shared `UserDefaults` would be a second store holding the same three flags.
  - **The rules reach the extension through `rules.json`** in the App Group,
    written by the app whenever they change (Task 5a), holding the rules, your
    user id and your display name. The extension reads it and never writes:
    the app stays the only writer in the container, as it is for every other
    file there. Where the file is missing or older than an hour, the extension
    fetches `/pushrules/` with the token it already holds, uses that answer for
    this one push, and still writes nothing, which honours the spec's hour of
    freshness without racing the app.
  - **Member counts ride in `names.json`** (Task 5), the file the app already
    rewrites on every rooms change. The `room_member_count` conditions need
    them, and the extension has no cheap way to count a room itself.
  - **There is no `.dev` app id.**
- **Copy (lowercase, verbatim):**
  - The extension falls back to the desktop strings: `encrypted message` (no room key); `new message` (Show message text off, an expired or missing token, or a failed fetch).
  - Titles follow `Notice.title`: `sender` in a DM, otherwise `'$sender in $place'`. With no sender name, the title is `place`, or `loaf chat` when there's no place either.
  - Settings, the iOS OS-blocked line: `ios is blocking notifications from loaf chat.`, with the existing `open system settings` button.
  - Settings, Channels: the heading `channels`, with the options `all messages` and `mentions only`; the detail `for every channel without its own setting, on every device you're signed in on.`
  - Settings, Direct messages: `direct messages always notify.`
- **The method channel stays `moe.loaf.chat/notify`.** iOS gets its own native end. The Dart side reuses the methods `prepare`, `withdraw`, `blocked`, `openSettings`, `ready` and `click`, and adds `pushToken`.
- **App Group layout** (the extension reads exactly these):
  - `<group>/loaf.sqlite` (with `-wal` and `-shm`);
  - `<group>/names.json`;
  - `<group>/notifications.json`;
  - `<group>/rules.json`.
  - The media cache stays in Application Support.
- **The pickle key** is the SDK's `toPickleKey()`: the user id's UTF-16 code units, each truncated to one byte, then cut or zero-padded to 32 bytes. The libolm fallback key is `utf8.encode(userId)`.
- **Never** log a token, a pickle or decrypted text. The extension logs only outcomes: `decrypted`, `no-key`, `no-token`, `fetch-failed`.

## Review Focus

1. **The app suspended while it holds a lock on the shared database.** iOS kills the app (`0xdead10cc`) if it is suspended holding a file lock in an App Group container. Expected: going to the background never ends in a kill.
   - Task 4 puts the database in WAL mode and wraps backgrounding in a `beginBackgroundTask` that waits for the SDK's pending writes.
   - Task 12's hand test watches Console for `0xdead10cc`.
2. **An update from the old location.** A user whose `loaf.sqlite`, `-wal` and `-shm` are in Application Support upgrades. Expected: they stay signed in with all their keys, and a half-finished move never loses the database.
   - Task 4 tests a move that is interrupted after the first file.
3. **A non-ASCII or long user id.** Expected: the extension derives the same pickle key the SDK does.
   - Task 1 tests ids with `é` and ids over 32 characters against the Dart derivation's known bytes.
4. **A notification for a room read on another device while the phone slept.** Expected: once the app syncs, it's withdrawn. It must not be withdrawn before that sync, when the count is merely stale.
   - Task 9 tests a sweep that uses `settledBefore`.
5. **The resume catch-up re-announcing pushed messages.** Expected: after a resume, messages push already delivered don't chime again.
   - Task 10 tests arrivals stamped between pause and resume.
6. **The phone and the app disagreeing about a message.** Expected: the
   verdict the extension reaches is the one `PushRules.notifies` would reach
   in Dart, for every case the app's own suite covers.
   - Task 3b runs both over one corpus; Task 13 case 3 checks it by hand.
7. **A push that should have been dropped, shown anyway.** The extension gets
   about 30 seconds; if it crashes or runs out of time, iOS shows whatever
   alert the gateway sent, which for a dropped push is a notification the
   rules forbade. Expected: this is the only way a silenced message appears,
   and it is rare.
   - Nothing in the extension blocks on anything but the two fetches, both
     capped at 10 seconds; `serviceExtensionTimeWillExpire` delivers the
     gateway's alert, as it does today. Task 13 case 3 watches for it.
8. **Stale rules on a phone that has not synced.** A level changed on the Mac
   while the phone slept. Expected: the hour-old refresh in the extension
   catches it; a phone offline for longer judges by the last rules it saw,
   and corrects itself on the next sync.

---

## File Structure

| File | Responsibility |
|---|---|
| `packages/loaf_push/pubspec.yaml`, `hook/build.dart` | The Dart package whose only job is to build `loaf_push` for iOS and bundle it |
| `packages/loaf_push/rust/` | The Rust crate: `loaf_push_decrypt`, `loaf_push_free`, `loaf_push_notifies`, the pickle key, the evaluator, tests and the fixtures |
| `test/matrix/push_rules_corpus_test.dart` | Writes `packages/loaf_push/rust/tests/fixtures/rules.json` from the cases the app's own rules suite runs |
| `lib/push/rules_file.dart` | Writes `rules.json`: the rules, your user id, your display name |
| `test/push/storage_pin_test.dart` | Writes and checks `packages/loaf_push/rust/tests/fixtures/sdk.json` from a real SDK database |
| `lib/push/app_group.dart` | The group path, the one-time move, and where the database and settings live |
| `lib/push/room_names.dart` | Writes `names.json` from the rooms |
| `lib/push/ios_push.dart` | The Dart end of the iOS channel: clicks, withdraw, blocked, the APNs token |
| `lib/push/pusher.dart` | Registers and removes the pusher |
| `lib/push/push_sweeper.dart` | Withdraws notifications for rooms that are read |
| `lib/ui/settings/channel_default.dart` | The Channels default over the push rules |
| `ios/LoafPushCore/` | A Swift package: the store reader, the names, the content builder, the decryptor seam |
| `ios/NotifyService/` | The extension target: `NotificationService.swift`, `Info.plist`, entitlements |
| `ios/Runner/NotifyBridge.swift`, `Runner.entitlements` | The app's end of the channel, and its entitlements |
| `tool/release/ios.sh`, `tool/release/ios-export-local.plist` | The entitlement gate |

---

### Task 1: The `loaf_push` crate

**Files:**
- Create: `packages/loaf_push/rust/Cargo.toml`, `packages/loaf_push/rust/src/lib.rs`
- Test: `packages/loaf_push/rust/src/lib.rs` (`#[cfg(test)]`)
- Modify: `mise.toml` (the `test:push` task, which also joins `test:all`)

**Interfaces:**
- Produces (C ABI, consumed by Task 7 through `dlsym`):
  - `loaf_push_decrypt(pickle: *const c_char, user_id: *const c_char, ciphertext: *const c_char) -> *mut c_char`: the plaintext event JSON, or null on any failure.
  - `loaf_push_free(p: *mut c_char)`.
- Produces (Rust): `pub fn pickle_key(user_id: &str) -> [u8; 32]` and `pub fn decrypt(pickle: &str, user_id: &str, ciphertext: &str) -> Option<String>`.

- [ ] **Step 1: The manifest**

```toml
[package]
name = "loaf_push"
version = "0.1.0"
edition = "2024"
publish = false

[lib]
# cdylib for the app's Frameworks (the extension dlopens it); rlib for tests.
crate-type = ["cdylib", "rlib"]

[dependencies]
# The version flutter_vodozemac 0.8.1 pins: the pickles it writes are the ones read here.
vodozemac = { version = "=0.10.0", features = ["libolm-compat"] }

[profile.release]
opt-level = "z"
lto = true
strip = true
panic = "abort"
```

- [ ] **Step 2: Write the failing tests**

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use vodozemac::megolm::{GroupSession, InboundGroupSession, SessionConfig};

    // Bytes from Dart: '@é:x'.toPickleKey(). é is U+00E9; one code unit, kept as 0xE9.
    #[test]
    fn pickle_key_truncates_code_units_like_dart() {
        let k = pickle_key("@é:x");
        assert_eq!(&k[..4], &[0x40, 0xE9, 0x3A, 0x78]);
        assert!(k[4..].iter().all(|b| *b == 0));
    }

    #[test]
    fn pickle_key_cuts_at_32() {
        let id = "@a-very-long-user-name-indeed:loaf.moe";
        assert_eq!(&pickle_key(id)[..], &id.as_bytes()[..32]);
    }

    #[test]
    fn astral_char_is_two_code_units() {
        // U+1F35E (🍞) is D83C DF5E in UTF-16; Dart keeps the low bytes 0x3C, 0x5E.
        assert_eq!(&pickle_key("🍞")[..2], &[0x3C, 0x5E]);
    }

    fn sealed(user: &str) -> (String, String) {
        let mut out = GroupSession::new(SessionConfig::version_1());
        let inbound = InboundGroupSession::new(&out.session_key(), SessionConfig::version_1());
        let pickle = inbound.pickle().encrypt(&pickle_key(user));
        let msg = out.encrypt(r#"{"type":"m.room.message","content":{"body":"hi"}}"#);
        (pickle, msg.to_base64())
    }

    #[test]
    fn decrypts_a_native_pickle() {
        let (pickle, ct) = sealed("@chris:loaf.moe");
        let plain = decrypt(&pickle, "@chris:loaf.moe", &ct).unwrap();
        assert!(plain.contains(r#""body":"hi""#));
    }

    #[test]
    fn wrong_user_is_none_not_a_panic() {
        let (pickle, ct) = sealed("@chris:loaf.moe");
        assert_eq!(decrypt(&pickle, "@mochi:loaf.moe", &ct), None);
    }

    #[test]
    fn garbage_is_none() {
        assert_eq!(decrypt("nope", "@a:b", "nope"), None);
    }

    #[test]
    fn c_abi_round_trip_and_null_inputs() {
        use std::ffi::{CStr, CString};
        let (pickle, ct) = sealed("@a:b");
        let (p, u, c) = (CString::new(pickle).unwrap(), CString::new("@a:b").unwrap(), CString::new(ct).unwrap());
        let out = unsafe { loaf_push_decrypt(p.as_ptr(), u.as_ptr(), c.as_ptr()) };
        assert!(!out.is_null());
        assert!(unsafe { CStr::from_ptr(out) }.to_str().unwrap().contains("hi"));
        unsafe { loaf_push_free(out) };
        assert!(unsafe { loaf_push_decrypt(std::ptr::null(), u.as_ptr(), c.as_ptr()) }.is_null());
    }
}
```

- [ ] **Step 3: Run the tests to watch them fail**

Run: `mise run test:push` (add the task first: `run = "cargo test --locked --manifest-path packages/loaf_push/rust/Cargo.toml"`, and add `{ task = "test:push" }` to `test:all`).
Expected: a compile error, because `pickle_key`, `decrypt` and `loaf_push_decrypt` don't exist yet.

- [ ] **Step 4: Implement**

```rust
//! Decrypts one Megolm message for the iOS Notification Service Extension,
//! from a room key as the matrix SDK pickles it into loaf.sqlite. The
//! extension dlopens this from the app's Frameworks; there is no header,
//! so the two C functions below are the whole contract.

use std::ffi::{CStr, CString, c_char};
use vodozemac::megolm::{InboundGroupSession, InboundGroupSessionPickle, MegolmMessage};

/// The SDK's `String.toPickleKey()`: Dart's UTF-16 code units, each kept
/// to its low byte by `Uint8List.fromList`, cut or zero-padded to 32.
pub fn pickle_key(user_id: &str) -> [u8; 32] {
    let mut key = [0u8; 32];
    for (slot, unit) in key.iter_mut().zip(user_id.encode_utf16()) {
        *slot = unit as u8;
    }
    key
}

fn unpickle(pickle: &str, user_id: &str) -> Option<InboundGroupSession> {
    if let Ok(p) = InboundGroupSessionPickle::from_encrypted(pickle, &pickle_key(user_id)) {
        return Some(InboundGroupSession::from_pickle(p));
    }
    // Keys stored before the SDK moved to vodozemac's format; the SDK reads
    // these with the user id's UTF-8 as the key, and so does this.
    InboundGroupSession::from_libolm_pickle(pickle, user_id.as_bytes()).ok()
}

pub fn decrypt(pickle: &str, user_id: &str, ciphertext: &str) -> Option<String> {
    let mut session = unpickle(pickle, user_id)?;
    let message = MegolmMessage::from_base64(ciphertext).ok()?;
    let plain = session.decrypt(&message).ok()?;
    String::from_utf8(plain.plaintext).ok()
}

unsafe fn arg<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(p) }.to_str().ok()
}

/// The plaintext event JSON, to be freed with [loaf_push_free]; null when
/// anything is missing or wrong. Never panics across the boundary: the
/// release profile aborts on panic, and nothing here unwraps.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_push_decrypt(
    pickle: *const c_char,
    user_id: *const c_char,
    ciphertext: *const c_char,
) -> *mut c_char {
    let plain = unsafe { (arg(pickle), arg(user_id), arg(ciphertext)) };
    let (Some(p), Some(u), Some(c)) = plain else { return std::ptr::null_mut() };
    decrypt(p, u, c)
        .and_then(|s| CString::new(s).ok())
        .map_or(std::ptr::null_mut(), CString::into_raw)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_push_free(p: *mut c_char) {
    if !p.is_null() {
        drop(unsafe { CString::from_raw(p) });
    }
}
```

Before relying on them, check the exact vodozemac 0.10.0 names (`InboundGroupSessionPickle::from_encrypted`, `from_pickle`, `from_libolm_pickle`, `DecryptedMessage::plaintext`) with `rustdoc-mcp-server`. If a name differs, adapt the code to it, not the tests.

- [ ] **Step 5: Run the tests to see them pass**

Run: `cargo generate-lockfile --manifest-path packages/loaf_push/rust/Cargo.toml && mise run test:push`
Expected: 7 passed.

- [ ] **Step 6: Commit**

```bash
git add packages/loaf_push/rust mise.toml
git commit -m "feat(push): loaf_push decrypts a room key as the SDK pickles it"
```

---

### Task 2: Pin the SDK's storage format

**Files:**
- Create: `test/push/storage_pin_test.dart`, `packages/loaf_push/rust/tests/fixtures/sdk.json`, `packages/loaf_push/rust/tests/fixture.rs`

**Interfaces:**
- Consumes: `cryptoClient(path:)` and `loadVodozemac()` from `test/matrix/crypto_harness.dart`.
- Produces: the fixture shape `{ "user_id", "client": {k: v}, "session_row": <v text>, "room_id", "event_content": {...}, "plaintext_body" }`. Task 6's Swift tests read this file.

- [ ] **Step 1: Write the Dart test**

It does two things. With `LOAF_PUSH_FIXTURE=write` set, it writes the fixture. Always, it checks that a fresh SDK database still has the shape the fixture records.

```dart
// The iOS extension reads loaf.sqlite without the SDK. This pins what it
// reads, so an SDK upgrade that moves it fails here rather than on a phone.
@Tags(['crypto'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/encryption/utils/pickle_key.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:vodozemac/vodozemac.dart' as vod;

import '../matrix/crypto_harness.dart';

const fixture = 'packages/loaf_push/rust/tests/fixtures/sdk.json';
const roomId = '!726s6s6q:example.com'; // an encrypted room in FakeMatrixApi

void main() {
  test('the store the extension reads', () async {
    final dir = await Directory.systemTemp.createTemp('pin');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/loaf.sqlite';
    final client = await cryptoClient(path: path);
    final room = client.getRoomById(roomId)!;
    final sent = await client.encryption!.encryptGroupMessagePayload(
      roomId,
      {'msgtype': 'm.text', 'body': 'pinned'},
    );
    await client.dispose(closeDatabase: true);

    final db = sqlite3.open(path, mode: OpenMode.readOnly);
    addTearDown(db.dispose);
    String? box(String table, String key) =>
        db.select('SELECT v FROM $table WHERE k = ?', [key]).firstOrNull?['v'] as String?;

    final clientRow = {
      for (final k in ['homeserver_url', 'token', 'token_expires_at', 'user_id'])
        k: box('box_client', k),
    };
    expect(clientRow['homeserver_url'], isNotNull);
    expect(clientRow['token'], isNotNull);
    expect(clientRow['user_id'], isNotNull);
    final sessionRow = box('box_inbound_group_session', sent['session_id'] as String);
    expect(sessionRow, isNotNull);
    final session = jsonDecode(sessionRow!) as Map<String, Object?>;
    expect(session.keys, containsAll(['room_id', 'session_id', 'pickle']));
    expect(session['room_id'], room.id);
    final userId = jsonDecode(clientRow['user_id']!) as String;
    // The key derivation the Rust crate mirrors.
    vod.InboundGroupSession.fromPickleEncrypted(
      pickle: session['pickle']! as String,
      pickleKey: userId.toPickleKey(),
    );

    if (Platform.environment['LOAF_PUSH_FIXTURE'] == 'write') {
      await File(fixture).writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'user_id': userId,
          'client': clientRow,
          'session_row': sessionRow,
          'room_id': room.id,
          'event_content': sent,
          'plaintext_body': 'pinned',
        }),
      );
    }
    final pinned = jsonDecode(await File(fixture).readAsString()) as Map;
    expect((pinned['client'] as Map).keys, clientRow.keys);
    expect((jsonDecode(pinned['session_row'] as String) as Map).keys.toSet(), session.keys.toSet());
  });
}
```

`sqlite3` is already a transitive dependency. Add it to `dev_dependencies` at the resolved version. If `box_client` stores its values JSON-encoded (`"\"https://…\""`), the test's `jsonDecode` proves it. Task 6's Swift reader must decode them the same way.

- [ ] **Step 2: Generate the fixture, then run the test without the variable**

Run: `LOAF_PUSH_FIXTURE=write mise exec -- flutter test test/push/storage_pin_test.dart`, then `mise run test -- test/push/storage_pin_test.dart`.
Expected: PASS both times, and `sdk.json` exists. On Linux, run `mise run vodozemac` first.

- [ ] **Step 3: Write the Rust fixture test**

```rust
// The fixture is written by test/push/storage_pin_test.dart from a real
// SDK database: if this fails after an SDK upgrade, so would the phone.
use std::fs;

#[test]
fn decrypts_what_the_sdk_stored() {
    let raw = fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/sdk.json")).unwrap();
    let f: serde_json::Value = serde_json::from_str(&raw).unwrap();
    let row: serde_json::Value = serde_json::from_str(f["session_row"].as_str().unwrap()).unwrap();
    let plain = loaf_push::decrypt(
        row["pickle"].as_str().unwrap(),
        f["user_id"].as_str().unwrap(),
        f["event_content"]["ciphertext"].as_str().unwrap(),
    )
    .expect("the SDK's pickle decrypts");
    let event: serde_json::Value = serde_json::from_str(&plain).unwrap();
    assert_eq!(event["content"]["body"], f["plaintext_body"]);
    assert_eq!(event["room_id"], f["room_id"]);
}
```

Add `serde_json = "1"` under `[dev-dependencies]` only.

- [ ] **Step 4: Run it**

Run: `mise run test:push`
Expected: 8 passed.

- [ ] **Step 5: Commit**

```bash
git add test/push packages/loaf_push/rust pubspec.yaml pubspec.lock
git commit -m "test(push): pin the SDK's room-key storage the extension reads"
```

---

### Task 3: The build hook bundles `loaf_push` on iOS

**Files:**
- Create: `packages/loaf_push/pubspec.yaml`, `packages/loaf_push/hook/build.dart`, `packages/loaf_push/lib/loaf_push.dart` (a library comment only)
- Modify: `pubspec.yaml` (a path dependency), `mise.toml` (the Rust targets)

**Interfaces:**
- Produces: inside the built app, `Runner.app/Frameworks/<name>.framework/<name>`, where `<name>` is whatever Flutter derives from the code asset. **Step 4 records the real path** in the ledger, and Task 7's `dlopen` uses it.

- [ ] **Step 1: The Rust targets**

In `mise.toml`, change the Rust line to `rust = { version = "1.96.1", targets = "aarch64-apple-ios,aarch64-apple-ios-sim" }`. Then run `mise install` and `rustup target list --installed`.
Expected: both targets are listed. If mise ignores `targets`, stop and report it rather than adding a `rustup` step to CI.

- [ ] **Step 2: The hook**

```dart
/// Builds the Rust crate `loaf_push` for iOS and bundles it, so Flutter
/// embeds it in the app's Frameworks. No Dart calls it: the Notification
/// Service Extension dlopens it from there. Every other OS gets nothing.
library;

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

Future<void> main(List<String> args) => build(args, (input, output) async {
  if (!input.config.buildCodeAssets) return;
  final code = input.config.code;
  if (code.targetOS != OS.iOS) return;

  final triple = switch ((code.targetArchitecture, code.iOS.targetSdk)) {
    (Architecture.arm64, IOSSdk.iPhoneOS) => 'aarch64-apple-ios',
    (Architecture.arm64, IOSSdk.iPhoneSimulator) => 'aarch64-apple-ios-sim',
    final other => throw UnsupportedError('loaf_push: no Rust target for $other'),
  };
  final crate = input.packageRoot.resolve('rust/');
  final cargoDir = input.outputDirectoryShared.resolve('cargo/');
  final cargo = await Process.run('cargo', [
    'build', '--release', '--locked', '--target', triple,
    '--manifest-path', crate.resolve('Cargo.toml').toFilePath(),
    '--target-dir', cargoDir.toFilePath(),
  ], environment: {'IPHONEOS_DEPLOYMENT_TARGET': '${code.iOS.targetVersion}'});
  if (cargo.exitCode != 0) {
    throw Exception('cargo build of loaf_push failed:\n${cargo.stdout}\n${cargo.stderr}');
  }
  output.assets.code.add(
    CodeAsset(
      package: 'loaf_push',
      name: 'loaf_push.dart',
      linkMode: DynamicLoadingBundled(),
      file: cargoDir.resolve('$triple/release/libloaf_push.dylib'),
    ),
  );
  output.dependencies.addAll([
    crate.resolve('Cargo.toml'),
    crate.resolve('Cargo.lock'),
    for (final f in Directory.fromUri(crate.resolve('src/')).listSync())
      if (f is File) f.uri,
  ]);
});
```

`pubspec.yaml` mirrors `packages/loaf_notify/pubspec.yaml`: the same `hooks` and `code_assets` versions, and no Flutter plugin section. Check the `IOSSdk`, `targetSdk` and `targetVersion` names with `dart doc` or the package source in `~/.pub-cache` before running.

- [ ] **Step 3: Build for the simulator**

Run: `mise run build:ios:sim`
Expected: success.

- [ ] **Step 4: Prove it landed, and record where**

Run: `find build/ios/iphonesimulator/Runner.app/Frameworks -iname '*loaf_push*'` and `nm -gU <that binary> | grep loaf_push_`
Expected: one framework, exporting `_loaf_push_decrypt` and `_loaf_push_free`. Write the path into the ledger.
If nothing is bundled because no Dart references the asset: add one `@Native` declaration of `loaf_push_free` in `lib/loaf_push.dart`, never called, with a comment saying why. Rebuild and check again.

- [ ] **Step 5: Confirm the other platforms are untouched**

Run: `mise run build:macos && mise run test`
Expected: both succeed, and no cargo build of `loaf_push` appears in the macOS build output.

- [ ] **Step 6: Commit**

```bash
git add packages/loaf_push pubspec.yaml pubspec.lock mise.toml
git commit -m "build(push): a build hook bundles loaf_push in the iOS app"
```

---

### Task 3a: `loaf_push` evaluates the push rules

The same judgement `lib/matrix/push_rules.dart` makes in the app, in Rust, on
the decrypted event. Read that file and its doc comment first: it is 143 lines
and it is the specification for this task. It wraps the SDK's evaluator and
undoes three of its departures from the spec (the audit's F1, F4 and F6), and
those compensations are part of what must be reproduced here, because the
corpus in Task 3b is generated from it.

**Files:**
- Create: `packages/loaf_push/rust/src/rules.rs`, `packages/loaf_push/rust/tests/rules_test.rs`
- Modify: `packages/loaf_push/rust/src/lib.rs` (the third symbol), `packages/loaf_push/rust/Cargo.toml` (`serde_json`), `mise.toml` (fold `rules.rs` into the existing `test:push` task), `.github/workflows/ci.yml` (only if `test:push` is not already in the Linux job)

**Interfaces:**
- Produces, in Rust:

```rust
/// What the app wrote to rules.json: the rules, and the two things about
/// you the rules read.
pub struct Account {
    pub user_id: String,
    pub display_name: Option<String>,
    pub rules: PushRuleSet,
}

/// Whether the rules notify for `event` in a room of `members` people.
/// `power` is the room's `m.room.power_levels` content, which the `@room`
/// rules' `sender_notification_permission` condition needs. `None` for
/// either means it could not be read, and the condition then holds.
/// `None` for the verdict when it cannot be reached: a ruleset that is not
/// an object, or an event with no `content`. The caller shows the message.
pub fn notifies(
    account: &Account,
    event: &Value,
    members: Option<u64>,
    power: Option<&Value>,
) -> Option<bool>;
```

- And across the C ABI, beside the two symbols Task 1 wrote:

```rust
/// 1 notify, 0 drop, -1 undecidable. `rules_json` is the whole file;
/// `members` is negative for unknown; `power_json` is the room's
/// `m.room.power_levels` content, or null when it could not be read.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_push_notifies(
    rules_json: *const c_char,
    event_json: *const c_char,
    members: i64,
    power_json: *const c_char,
) -> i32;
```

**The order of judgement**, which is Loaf's and not the SDK's:

1. `override`, in order, then the `content` rules **as overrides**, each
   rewritten to an `event_match` on `content.body` with the rule's pattern.
   This is F4: the spec puts content ahead of room, the SDK does not.
2. `room`, then `sender`, then `underride`.
3. A disabled rule is skipped. The first rule whose every condition holds
   decides, and it notifies when its actions contain `notify`. No rule
   matching means no notification.
4. When the event's `content` has an `m.mentions` key at all, whatever its
   shape, the three legacy rules are dropped before any of this:
   `.m.rule.contains_display_name`, `.m.rule.contains_user_name`,
   `.m.rule.roomnotif`. This is F6, and it is what Synapse does.
5. Every `room_member_count` condition is decided against `members`. With
   `members` unknown the condition **holds**, because the one default rule a
   count guards is the DM rule, and dropping it would turn a DM silent — the
   fail-open direction. This is F1: the count comes from the room summary the
   app recorded, never from members in memory. `is` is a number with an
   optional `==`, `<`, `<=`, `>` or `>=`; bare means equal; unparsable never
   holds.

**The conditions** to implement, all five the SDK knows:

- `event_match`: a glob (`*`, `?`) over a dotted key path into the
  **flattened** event, case-insensitive. On `content.body` it matches on word
  boundaries — the SDK builds `(^|\W)pattern($|\W)` — and on every other
  field it matches the whole value (`^pattern$`). A field whose value is not
  a string never matches. `\.` in a key is unescaped first, so
  `content.m\.mentions.room` and the flattened `content.m.mentions.room` are
  the same field.
- `event_property_is` and `event_property_contains`: the modern intentional
  mention rules (`.m.rule.is_user_mention`, `.m.rule.is_room_mention`) are
  built from these, so they are not optional. `is` compares for equality and
  requires the key to be **present** (null is a value); `contains` requires an
  array holding the value. A value that is not a string, number, bool or null
  makes the rule unusable.
- `contains_display_name`: your display name in `content.body` on word
  boundaries, case-insensitive, escaped as a literal rather than a glob. No
  name, or no body, means it never holds.
- `room_member_count`: above.
- `sender_notification_permission`: the sender's power against the room's
  `notifications[key]` (spec defaults: 0 for a user, 50 for `room`). The power
  levels arrive as the `power` argument, not inside the event, so that an
  injected key can never be matched by an `event_match`. With `power`
  unknown the condition holds, for the same reason an unknown count does.

An unknown condition kind makes the rule unusable, and an unusable rule is
skipped entirely rather than treated as matching — the SDK drops it while
building its evaluator, and the effect must be the same.

**Where the spec and the SDK disagree, the corpus in Task 3b decides**, and the
corpus comes from Dart. Do not implement the spec from memory and argue with
the fixture.

- [ ] **Step 1: Write the failing tests**

In `tests/rules_test.rs`, one case each, hand-built, so a failure names the
rule it broke rather than a case number:
- a `content` rule on your localpart beats a `room` rule with no actions (F4);
- a message with `"m.mentions": {}` is not matched by
  `.m.rule.contains_display_name`, and the same message without the key is
  (F6);
- `.m.rule.room_one_to_one` holds at `members == 2` and is dropped at 3 (F1);
- an `override` rule with no actions silences everything after it (mute);
- `.m.rule.master` enabled silences everything (do not disturb);
- a disabled rule is skipped;
- a glob `*foo*` matches `barfoobar`, and `?` matches one character;
- `contains_display_name` matches `ada` in `hi ada!` and not in `adalovelace`;
- unparsable rules JSON gives `None`, not `false`.

- [ ] **Step 2: Run the tests to watch them fail**

Run: `mise run test:push`
Expected: a compile failure, then failures.

- [ ] **Step 3: Implement**

`serde_json::Value` throughout; no new dependency beyond `serde_json`. Keep
`notifies` free of I/O and of the C ABI so the corpus test can call it
directly. The C wrapper parses, calls, and maps to `1` / `0` / `-1`; it must
not panic across the boundary, so wrap the body in
`std::panic::catch_unwind` and return `-1` on a panic.

- [ ] **Step 4: Run the tests to see them pass**

Run: `mise run test:push`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add packages/loaf_push mise.toml .github/workflows/ci.yml
git commit -m "feat(push): loaf_push judges a message by the account's push rules"
```

---

### Task 3b: one corpus, two implementations

`test/matrix/matrix_arrivals_rules_test.dart` already runs 245 cases: every
account level, room level, room kind and shape of mention, with an oracle
(`_expected`) that encodes what the spec says each should do. This task makes
that table the shared truth, so the phone and the app cannot drift.

**Files:**
- Create: `test/matrix/rules_cases.dart`, `test/matrix/push_rules_corpus_test.dart`, `packages/loaf_push/rust/tests/corpus_test.rs`
- Modify: `test/matrix/matrix_arrivals_rules_test.dart` (import the cases it used to hold)

**Interfaces:**
- `test/matrix/rules_cases.dart` holds what both tests need, moved out of the
  arrivals test unchanged: the `Account`, `RoomRule`, `Kind` and `Mention`
  enums, the `expected(...)` oracle, and the builders that turn a case into a
  `PushRuleSet` and an event. The arrivals test keeps driving the whole client
  stack; only the table moves.
- `test/matrix/push_rules_corpus_test.dart` runs every case through
  `PushRules.notifies` directly, asserts it equals `expected(...)`, and, with
  `LOAF_WRITE_CORPUS=1`, writes
  `packages/loaf_push/rust/tests/fixtures/rules.json`:

```json
[{"name": "all/mentionsOnly/group/bodyLocalpart",
  "account": {"user_id": "@ada:example.com", "display_name": "ada", "rules": {}},
  "event": {}, "members": 5, "notify": true}]
```

- `corpus_test.rs` reads that file and asserts `notifies` returns
  `Some(case.notify)` for every case, naming the case on failure.

- [ ] **Step 1: Move the table, and write the Dart corpus test**

The move must not change a single expectation: run
`mise run test -- test/matrix/matrix_arrivals_rules_test.dart` before and
after and compare the counts. Then write the corpus test over the moved table.

Run: `mise run test -- test/matrix/`
Expected: PASS, with the arrivals test's count unchanged.

- [ ] **Step 2: Write the fixture, then run the Rust test**

```bash
LOAF_WRITE_CORPUS=1 mise run test -- test/matrix/push_rules_corpus_test.dart
mise run test:push
```

Expected: the second fails, with the cases Rust gets wrong. Fix `rules.rs`
until it passes. If a case looks wrong in Dart, stop: that is the app
misbehaving on a real phone too, and it is a finding, not a fixture to edit.

- [ ] **Step 3: Make the fixture's staleness visible**

The corpus test without the variable checks the committed fixture still
matches what Dart answers today, the way Task 2's storage pin does. An SDK
change, or a change to `push_rules.dart`, then fails in the Dart lane with a
message saying to regenerate.

Run: `mise run test -- test/matrix/push_rules_corpus_test.dart`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add test/matrix packages/loaf_push/rust/tests
git commit -m "test(push): Dart and Rust judge one corpus of rules the same way"
```

---

### Task 4: Shared storage — the App Group, the move, WAL

**Files:**
- Create: `lib/push/app_group.dart`, `test/push/app_group_test.dart`, `ios/Runner/Runner.entitlements`
- Modify: `lib/matrix/client_factory.dart` (the default path, plus `onConfigure` for WAL), `lib/ui/settings/notification_settings.dart` (`inSupportDirectory` → `inDataDirectory`), `lib/main.dart`, `ios/Runner.xcodeproj/project.pbxproj` (`CODE_SIGN_ENTITLEMENTS` for the Runner configs), `ios/Runner/AppDelegate.swift` (the background task), `pubspec.yaml` (`path_provider_foundation`)

**Interfaces:**
- Produces:
  - `const appGroupId = 'group.moe.loaf.chat';`
  - `Future<Directory> dataDirectory()`: the group container on iOS, Application Support everywhere else.
  - `Future<void> moveIntoGroup({required Directory from, required Directory to})`: moves `loaf.sqlite`, `loaf.sqlite-wal`, `loaf.sqlite-shm` and `notifications.json`. Idempotent.

- [ ] **Step 1: Write the failing tests**

```dart
void main() {
  late Directory from, to;
  setUp(() async {
    from = await Directory.systemTemp.createTemp('support');
    to = await Directory.systemTemp.createTemp('group');
  });
  tearDown(() async { await from.delete(recursive: true); await to.delete(recursive: true); });

  Future<void> put(Directory d, String name, String body) => File('${d.path}/$name').writeAsString(body);
  String? read(Directory d, String name) {
    final f = File('${d.path}/$name');
    return f.existsSync() ? f.readAsStringSync() : null;
  }

  test('moves the database, its journal and the settings', () async {
    await put(from, 'loaf.sqlite', 'db');
    await put(from, 'loaf.sqlite-wal', 'wal');
    await put(from, 'notifications.json', '{}');
    await moveIntoGroup(from: from, to: to);
    expect(read(to, 'loaf.sqlite'), 'db');
    expect(read(to, 'loaf.sqlite-wal'), 'wal');
    expect(read(to, 'notifications.json'), '{}');
    expect(read(from, 'loaf.sqlite'), isNull);
  });

  test('a fresh install has nothing to move', () async {
    await moveIntoGroup(from: from, to: to);
    expect(to.listSync(), isEmpty);
  });

  test('never overwrites a database already in the group', () async {
    await put(from, 'loaf.sqlite', 'old');
    await put(to, 'loaf.sqlite', 'new');
    await moveIntoGroup(from: from, to: to);
    expect(read(to, 'loaf.sqlite'), 'new');
  });

  test("never lays the old database's journal beside the live one", () async {
    await put(from, 'loaf.sqlite', 'old');
    await put(from, 'loaf.sqlite-wal', 'old wal');
    await put(to, 'loaf.sqlite', 'new');
    await moveIntoGroup(from: from, to: to);
    expect(read(to, 'loaf.sqlite-wal'), isNull);
  });

  test('finishes a move interrupted after the database', () async {
    // Killed after the first rename: the db is in the group, its WAL is not.
    await put(to, 'loaf.sqlite', 'db');
    await put(from, 'loaf.sqlite-wal', 'wal');
    await moveIntoGroup(from: from, to: to);
    expect(read(to, 'loaf.sqlite-wal'), 'wal');
  });
}
```

- [ ] **Step 2: Run the tests to watch them fail**

Run: `mise run test -- test/push/app_group_test.dart`
Expected: FAIL, because `moveIntoGroup` isn't defined.

- [ ] **Step 3: Implement**

```dart
/// Where the data the iOS Notification Service Extension reads lives: the
/// App Group container, which the app and the extension share. Elsewhere,
/// Application Support, as before.
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:path_provider_foundation/path_provider_foundation.dart';

const appGroupId = 'group.moe.loaf.chat';

/// The database first, then its journal: SQLite treats a -wal beside the
/// wrong database as garbage, but one left behind is merely moved next run.
const _moved = ['loaf.sqlite', 'loaf.sqlite-wal', 'loaf.sqlite-shm', 'notifications.json'];

Future<Directory> dataDirectory() async {
  final support = await getApplicationSupportDirectory();
  if (!Platform.isIOS) return support;
  final group = await PathProviderFoundation().getContainerPath(appGroupIdentifier: appGroupId);
  // Without the entitlement there is no container: carry on where the data
  // already is rather than lose it. The extension then falls back to the gateway's alert.
  if (group == null) return support;
  final to = Directory(group);
  await moveIntoGroup(from: support, to: to);
  return to;
}

/// Each file moves on its own and only when the group lacks it, so a move
/// killed half way finishes on the next launch and never overwrites.
Future<void> moveIntoGroup({required Directory from, required Directory to}) async {
  // A database in both places: the group's is the live one, and the old
  // one's journal must never be laid beside it. A database only in the
  // group, with its journal still behind, is a move cut short: finish it.
  final both = File('${to.path}/loaf.sqlite').existsSync() &&
      File('${from.path}/loaf.sqlite').existsSync();
  for (final name in _moved) {
    final src = File('${from.path}/$name');
    final dst = File('${to.path}/$name');
    if (!src.existsSync() || dst.existsSync()) continue;
    if (both && name.startsWith('loaf.sqlite')) continue;
    try {
      await src.rename(dst.path);
    } on FileSystemException {
      // Another volume: copy, then remove the original only once it's there.
      await src.copy(dst.path);
      await src.delete();
    }
  }
}
```

In `client_factory.dart`, the default path becomes `'${(await dataDirectory()).path}${Platform.pathSeparator}loaf.sqlite'`. The media directory stays in Application Support. Add `onConfigure: (db) => db.rawQuery('PRAGMA journal_mode=WAL')` to the `OpenDatabaseOptions`, with a comment: the extension reads while the app writes. `FileNotificationStore.inSupportDirectory` becomes `inDataDirectory` and uses `dataDirectory()`. Update its one caller in `main.dart`.

- [ ] **Step 4: Run the tests to see them pass, then the suite**

Run: `mise run test -- test/push/app_group_test.dart && mise run test`
Expected: PASS everywhere.

- [ ] **Step 5: Entitlements, plus the background task**

`ios/Runner/Runner.entitlements` (Swift isn't involved; it's a plist that Xcode reads):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>aps-environment</key>
	<string>development</string>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.moe.loaf.chat</string>
	</array>
</dict>
</plist>
```

Set `CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;` on all three Runner build configurations in `project.pbxproj`. The App Store export rewrites `aps-environment` to `production`, and Task 11's gate checks that it did.

In `AppDelegate.swift`, on `applicationDidEnterBackground`, begin a `UIApplication.shared.beginBackgroundTask(withName: "loaf.db")` and end it after 3 s. The comment says why: it gives the SDK's in-flight writes time to commit, so that no transaction is open when iOS suspends us, because a lock held in an App Group container at suspension is `0xdead10cc`.

- [ ] **Step 6: Simulator build**

Run: `mise run build:ios:sim`
Expected: success.

- [ ] **Step 7: Commit**

```bash
git add lib/push/app_group.dart test/push/app_group_test.dart lib/matrix/client_factory.dart lib/ui/settings/notification_settings.dart lib/main.dart ios/Runner pubspec.yaml pubspec.lock ios/Runner.xcodeproj/project.pbxproj
git commit -m "feat(push): the database and device settings move into the App Group on iOS"
```

---

### Task 5: `names.json`

**Files:**
- Create: `lib/push/room_names.dart`, `test/push/room_names_test.dart`
- Modify: `lib/ui/shell/app_shell.dart` (start it on iOS once there are real rooms)

**Interfaces:**
- Consumes: `noticePlace` from `lib/ui/model/notice.dart`.
- Produces:
  - `Map<String, Object> roomNames(List<Space> spaces, List<Channel> homeRooms)`: `{roomId: {"place": String?, "dm": bool, "members": int?}}`, over every joined channel.
    - `members` is the joined-member count the push rules judge against, and
      `Channel` does not carry it yet: add a nullable `memberCount` to
      `Channel` in `lib/ui/model/models.dart` and fill it in `MatrixRooms`
      from `room.summary.mJoinedMemberCount`, the one source
      `lib/matrix/push_rules.dart` reads. `Invite` already has such a field,
      filled the same way at `matrix_rooms.dart:882`; follow it.
  - `class RoomNamesWriter { RoomNamesWriter(Rooms rooms, File file); void dispose(); }`: writes on each rooms change, only when the content changed, to a temporary file that is then renamed.

- [ ] **Step 1: Write the failing tests**

There are three:
- **The DM has no place:** a DM yields `{"place": null, "dm": true, "members": 2}`.
- **A space channel:** a channel in space `Pack` named `general` yields `{"place": "#general · Pack", "dm": false, "members": 12}`.
- **A channel whose count the server never sent** yields `"members": null`.
- **The writer writes once per change:** using `MockRooms` and a temp file, two notifications with equal names produce one write, as seen by the file's modified time and a counter on an injected `write`.

```dart
test('a DM has no place, a space channel names both', () {
  final names = roomNames(
    [Space(id: 's', name: 'Pack', channels: [Channel(id: '!g', name: 'general', joined: true)])],
    [Channel(id: '!d', name: 'mochi', kind: ChannelKind.direct, joined: true)],
  );
  expect(names['!d'], {'place': null, 'dm': true, 'members': 2});
  expect(names['!g'], {'place': '#general · Pack', 'dm': false, 'members': 12});
});
```

Use the real constructors from `lib/ui/model/models.dart`. Read them first; the arguments above are illustrative of the fields, and the test must compile against the real ones.

- [ ] **Step 2: Run, watch it fail; implement; run, watch it pass**

Implementation: iterate `homeRooms` and each space's `allChannels` (joined only), and call `noticePlace`. The writer keeps the last JSON string and skips writing when it's equal. It writes to `names.json.tmp`, then renames to `names.json`, so the extension never reads half a file. In `app_shell.dart`, create it in `didChangeDependencies` only when `Platform.isIOS && widget.rooms != null`, with `File('${(await dataDirectory()).path}/names.json')`, and dispose it with the shell.

Run: `mise run test -- test/push/room_names_test.dart`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add lib/push/room_names.dart test/push/room_names_test.dart lib/ui/shell/app_shell.dart lib/ui/model/models.dart lib/matrix/matrix_rooms.dart
git commit -m "feat(push): the app keeps room names where the extension can read them"
```

---

### Task 5a: `rules.json`

The rules themselves, plus the two things about you they read. Same shape as
Task 5: one writer, atomic, only on change.

**Files:**
- Create: `lib/push/rules_file.dart`, `test/push/rules_file_test.dart`
- Modify: `lib/ui/shell/app_shell.dart` (start it on iOS beside the names writer)

**Interfaces:**
- Produces:
  - `Map<String, Object?> rulesFile({required String userId, required String? displayName, required PushRuleSet rules, required DateTime now})`:
    `{"user_id": …, "display_name": …, "written_at": <ms since epoch>, "rules": <the ruleset as the server sends it>}`.
  - `class RulesWriter { RulesWriter(Client client, File file); void dispose(); }`.
- The rules go in **as the server sends them**, untouched: the compensations
  (F1, F4, F6) belong to whoever evaluates, and Task 3a reproduces them. Do
  not write a pre-chewed ruleset; the Rust side and `push_rules.dart` must see
  the same input, or the corpus in Task 3b proves nothing.

- [ ] **Step 1: Write the failing tests**

- **The shape:** `rulesFile(...)` round-trips through `jsonEncode` and holds
  the four keys, with `rules` deep-equal to `client.globalPushRules!.toJson()`.
- **Writes on a rules change:** with `FakeMatrixApi`, new `m.push_rules`
  account data writes the file once; the same rules arriving again write
  nothing (compare the counter, as the names test does).
- **Writes on a display-name change:** your profile name changing rewrites it,
  because `contains_display_name` reads it.
- **Atomic:** the file is written as `rules.json.tmp` and renamed.
- **No rules yet:** `client.globalPushRules == null` writes nothing at all,
  rather than a file holding an empty ruleset. An empty ruleset silences
  everything, and the extension must not be handed that (it fails open only
  on a *missing* file).

- [ ] **Step 2: Run, watch them fail; implement; run, watch them pass**

Watch `client.onSync` for `m.push_rules` in account data, and the same profile
source `lib/matrix/matrix_profile.dart` uses for your display name. Keep the
last JSON string and skip an equal one, like `RoomNamesWriter`. Start it in
`app_shell.dart` next to the names writer, under the same
`Platform.isIOS && widget.rooms != null` guard.

Run: `mise run test -- test/push/rules_file_test.dart`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add lib/push/rules_file.dart test/push/rules_file_test.dart lib/ui/shell/app_shell.dart
git commit -m "feat(push): the app keeps the push rules where the extension can read them"
```

---

### Task 6: `LoafPushCore`, the extension's logic in a Swift package

**Files:**
- Create: `ios/LoafPushCore/Package.swift`, `ios/LoafPushCore/Sources/LoafPushCore/{Store.swift,Names.swift,Rules.swift,Content.swift}`, `ios/LoafPushCore/Tests/LoafPushCoreTests/{StoreTests.swift,ContentTests.swift,RulesTests.swift}`
- Modify: `mise.toml` (the `test:push:apple` task: `swift test --package-path ios/LoafPushCore`)

**Interfaces:**
- Produces:

```swift
public struct Session { public let homeserver: URL; public let token: String; public let expiresAt: Date?; public let userId: String }
public struct RoomKey { public let roomId: String; public let pickle: String }
public final class Store {           // read-only over loaf.sqlite
  public init?(path: String)
  public func session() -> Session?
  public func roomKey(sessionId: String) -> RoomKey?
}
public struct RoomName: Decodable { public let place: String?; public let dm: Bool }
public func loadNames(_ url: URL) -> [String: RoomName]
public struct DeviceSettings: Decodable { public var notifications = true, sound = true, showText = true }
public func loadSettings(_ url: URL) -> DeviceSettings
public struct Rules { public let json: Data; public let writtenAt: Date? }
public func loadRules(_ url: URL) -> Rules?            // nil: missing or unreadable
public func isStale(_ rules: Rules?, now: Date) -> Bool // nil, or written over an hour ago
/// The verdict. nil when it cannot be reached; the caller then shows the
/// message. Task 3a's `loaf_push_notifies` behind a seam, as `Decrypt` is.
public typealias Notifies = (_ rules: Data, _ event: [String: Any], _ members: Int?, _ power: [String: Any]?) -> Bool?
public typealias Decrypt = (_ pickle: String, _ userId: String, _ ciphertext: String) -> String?
public struct Shown: Equatable { public let title: String; public let body: String; public let outcome: String; public let drop: Bool }
public func content(roomId: String, event: [String: Any]?, senderName: String?, names: [String: RoomName],
                    settings: DeviceSettings, store: Store?, decrypt: Decrypt,
                    rules: Rules?, power: [String: Any]?, notifies: Notifies,
                    now: Date) -> Shown
```

- [ ] **Step 1: The package**

Use `swift-tools-version:5.9`, platforms `.iOS(.v15), .macOS(.v13)` (macOS so that `swift test` runs on the Mac), and link `SQLite3` from the system: `linkerSettings: [.linkedLibrary("sqlite3")]`, with `import SQLite3`.

- [ ] **Step 2: Write the failing tests**

`StoreTests` builds a sqlite file in a temp directory with `box_client(k TEXT PRIMARY KEY, v TEXT)` and `box_inbound_group_session(...)`. It fills them **from `packages/loaf_push/rust/tests/fixtures/sdk.json`**, located via `#filePath`, so the Swift side reads exactly the shape the Dart pin recorded. The cases:
- `session()` returns the fixture's user id and homeserver, decoding the JSON-encoded values;
- `roomKey(sessionId:)` returns the room id and pickle;
- an unknown session id gives nil;
- a missing file gives `Store(path:) == nil`.

`ContentTests` uses a fake `Decrypt`:
- **Encrypted with a key:** returns `{"type":"m.room.message","room_id":"!d","content":{"msgtype":"m.text","body":"hi"}}`. The DM gives `("mochi", "hi", "decrypted")`.
- **No key:** gives `("mochi", "encrypted message", "no-key")`.
- **A key for a different room:** the fake returns plaintext whose `room_id` is `!other`. This gives `"encrypted message"`: a key from another room is never trusted.
- **No event (fetch failed):** with `!g` in names as `#general · Pack`, this gives `("#general · Pack", "new message", "fetch-failed")`.
- **Show text off:** the body is `new message`.
- **A picture:** the body is `sent a picture`.
- **A file:** `m.file`, `m.video` and `m.audio` give `sent a file`.
- **Long text:** 401 characters is cut to 400 plus `…`, by `Character`.
- **A sender in a channel:** the title is `mochi in #general · Pack`.

And the verdict, with a fake `Notifies`:
- **The rules say no:** `drop == true`, outcome `dropped`, and the title and
  body are empty. The fake records what it was handed: the **decrypted**
  event, never the `m.room.encrypted` wrapper, and the room's `members` from
  `names.json`.
- **The rules say yes:** `drop == false`, and the text is as above.
- **No rules file:** the fake is never called, `drop == false`, outcome
  `no-rules`. It fails open.
- **The verdict is nil:** `drop == false`, outcome `undecided`.
- **No room key:** the fake is never called, `drop == false`, outcome
  `no-key`. A message we could not read is a message we cannot judge.
- **The fetch failed:** the fake is never called, `drop == false`, outcome
  `fetch-failed`.
- **Notifications off in settings:** `drop == true`, outcome `off`. The
  pusher is supposed to be gone (Task 11), so this is belt and braces for a
  push already in flight.

- [ ] **Step 3: Run, watch them fail**

Run: `mise run test:push:apple`
Expected: a compile failure, because nothing is defined yet.

- [ ] **Step 4: Implement**

`Store` opens with `sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)` and runs `PRAGMA query_only=1`. It reads `SELECT v FROM box_client WHERE k=?`, then decodes each `v` with `JSONSerialization` (`.fragmentsAllowed`), since the values are JSON-encoded. `token_expires_at` is decoded however Task 2's fixture shows it (milliseconds, number or string). The `content` function follows the spec's fallback order:
1. `settings.notifications == false` → `drop`, outcome `off`;
2. no `event` → `fetch-failed`, shown;
3. `m.room.encrypted` → look up the key, check the key's `roomId == roomId`, decrypt, check the plaintext's `room_id == roomId`, and on any failure fall back to `no-key`, shown;
4. **the verdict**, on the event as read (decrypted where it was encrypted):
   no `rules` → `no-rules`, shown; `notifies` nil → `undecided`, shown;
   `false` → `dropped`; `true` → carry on;
5. body from `msgtype`, with the desktop's strings and 400-character clip;
6. `showText == false` → `new message`.

Steps 2 and 3 come before the verdict and win it: every path that could not
read the message shows it. Only a message we read and judged is dropped.

Keep the strings in one `enum Copy` at the top of `Content.swift`.

- [ ] **Step 5: Run, watch them pass**

Run: `mise run test:push:apple`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add ios/LoafPushCore mise.toml
git commit -m "feat(push): LoafPushCore reads the store, judges the rules, and builds the text"
```

---

### Task 7: The Notification Service Extension target

**Files:**
- Create: `ios/NotifyService/NotificationService.swift`, `ios/NotifyService/Info.plist`, `ios/NotifyService/NotifyService.entitlements`
- Modify: `ios/Runner.xcodeproj/project.pbxproj` (the new target, embedded in Runner, depending on the local package `LoafPushCore`)

**Interfaces:**
- Consumes: Task 6's API, Task 1's two C symbols, and Task 3's recorded framework path.

- [ ] **Step 1: Add the target in Xcode**

Do this through Xcode's UI, not by hand-editing the pbxproj. Use computer use with Chris's grant for Xcode. Open `ios/Runner.xcworkspace`, then File › New › Target › Notification Service Extension, and set:
- Product Name `NotifyService`;
- Team `6W2A5N37N3`;
- language Swift;
- embed in `Runner`;
- "Activate scheme": **Don't activate**.

Then, on the `NotifyService` target, set:
- bundle id `moe.loaf.chat.ios.notify`;
- iOS Deployment Target 15.0;
- `CODE_SIGN_STYLE = Automatic`;
- `CODE_SIGN_ENTITLEMENTS = NotifyService/NotifyService.entitlements`;
- `MARKETING_VERSION = $(FLUTTER_BUILD_NAME)` and `CURRENT_PROJECT_VERSION = $(FLUTTER_BUILD_NUMBER)`, matching Runner. App Store Connect rejects an extension whose version differs from the app's.

Under Frameworks and Libraries, add the local package `ios/LoafPushCore` (product `LoafPushCore`). Delete the Objective-C or template files Xcode generates. Quit Xcode, then confirm with `git diff --stat` that only `project.pbxproj` and the `ios/NotifyService/` files changed.

The entitlements file holds two keys: `com.apple.security.application-groups`
= `[group.moe.loaf.chat]`, and
`com.apple.developer.usernotifications.filtering` = `true`. Without the
second, delivering an empty content shows an empty notification instead of
suppressing one, so every drop would become a blank alert.

**Before starting this task, confirm with Chris** that filtering is switched
on for the `moe.loaf.chat.ios.notify` app id in the developer portal, and that
the profile automatic signing fetches carries it. This plan's rule is that CI
creates nothing new in Apple's account; a profile without the entitlement
fails Task 12's gate, and that is the one failure in this plan that cannot be
fixed from the repository.

- [ ] **Step 2: `NotificationService.swift`**

```swift
import Foundation
import LoafPushCore
import UserNotifications
import os

/// Decrypts and titles each push before iOS shows it. Reads what the app
/// left in the App Group; never writes, never refreshes the token. If it
/// runs out of time, iOS shows whatever alert the gateway sent.
final class NotificationService: UNNotificationServiceExtension {
  private static let log = Logger(subsystem: "moe.loaf.chat.ios.notify", category: "push")
  private var deliver: ((UNNotificationContent) -> Void)?
  private var best: UNMutableNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    deliver = contentHandler
    let out = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
    best = out
    let info = request.content.userInfo
    guard let roomId = info["room_id"] as? String, let eventId = info["event_id"] as? String,
      let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.moe.loaf.chat")
    else { return finish(out) }

    let settings = loadSettings(group.appendingPathComponent("notifications.json"))
    let names = loadNames(group.appendingPathComponent("names.json"))
    let store = Store(path: group.appendingPathComponent("loaf.sqlite").path)
    let cached = loadRules(group.appendingPathComponent("rules.json"))
    out.threadIdentifier = roomId
    out.userInfo = ["roomId": roomId, "eventId": eventId]
    out.sound = settings.sound ? UNNotificationSound(named: UNNotificationSoundName("chime.caf")) : nil

    Task {
      let session = store?.session()
      let (event, sender) = await Self.fetch(session, roomId: roomId, eventId: eventId)
      let power = await Self.state(session, roomId: roomId, type: "m.room.power_levels")
      // Stale or missing: ask the server, for this push only. Nothing in
      // the container is ever written from here.
      let rules =
        isStale(cached, now: Date())
        ? await Self.rules(session, keeping: cached) ?? cached
        : cached
      let shown = content(
        roomId: roomId, event: event, senderName: sender, names: names,
        settings: settings, store: store, decrypt: LoafPush.decrypt,
        rules: rules, power: power, notifies: LoafPush.notifies, now: Date())
      Self.log.info("\(shown.outcome, privacy: .public)")
      if shown.drop { return self.suppress() }
      out.title = shown.title
      out.body = shown.body
      self.finish(out)
    }
  }

  override func serviceExtensionTimeWillExpire() {
    if let best { finish(best) }
  }

  private func finish(_ content: UNNotificationContent) {
    deliver?(content)
    deliver = nil
  }

  /// Show nothing: the rules silenced this message. An empty content is how
  /// a filtering extension drops a push.
  private func suppress() { finish(UNNotificationContent()) }

  /// The event and its sender's display name; nil, nil when the token is
  /// missing or expired or either request fails.
  private static func fetch(_ s: Session?, roomId: String, eventId: String) async -> ([String: Any]?, String?) {
    guard let s, (s.expiresAt ?? .distantFuture) > Date() else { return (nil, nil) }
    func get(_ path: String) async -> [String: Any]? {
      var req = URLRequest(url: s.homeserver.appendingPathComponent(path))
      req.setValue("Bearer \(s.token)", forHTTPHeaderField: "Authorization")
      req.timeoutInterval = 10
      guard let (data, resp) = try? await URLSession.shared.data(for: req),
        (resp as? HTTPURLResponse)?.statusCode == 200
      else { return nil }
      return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    let room = roomId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? roomId
    let ev = eventId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventId
    guard let event = await get("_matrix/client/v3/rooms/\(room)/event/\(ev)") else { return (nil, nil) }
    let sender = (event["sender"] as? String) ?? ""
    let who = sender.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sender
    let member = await get("_matrix/client/v3/rooms/\(room)/state/m.room.member/\(who)")
    return (event, (member?["displayname"] as? String) ?? sender)
  }

  /// The account's rules, for a cache that is missing or over an hour old.
  /// `/pushrules/` answers `{"global": {...}}` and knows nothing about your
  /// display name, so the ruleset is unwrapped and the cached name carried
  /// over: without it `contains_display_name` would stop matching on exactly
  /// the pushes that took this path.
  private static func rules(_ s: Session?, keeping cached: Rules?) async -> Rules? {
    guard let s, (s.expiresAt ?? .distantFuture) > Date() else { return nil }
    var req = URLRequest(url: s.homeserver.appendingPathComponent("_matrix/client/v3/pushrules/"))
    req.setValue("Bearer \(s.token)", forHTTPHeaderField: "Authorization")
    req.timeoutInterval = 10
    guard let (data, resp) = try? await URLSession.shared.data(for: req),
      (resp as? HTTPURLResponse)?.statusCode == 200,
      let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let global = body["global"]
    else { return nil }
    var file: [String: Any] = ["user_id": s.userId, "rules": global]
    if let cached, let old = try? JSONSerialization.jsonObject(with: cached.json),
      let name = (old as? [String: Any])?["display_name"]
    {
      file["display_name"] = name
    }
    guard let wrapped = try? JSONSerialization.data(withJSONObject: file) else { return nil }
    return Rules(json: wrapped, writtenAt: nil)
  }
}

/// The two C functions of loaf_push, found in the app's Frameworks at run
/// time: there is no header, by choice (Rust, Dart and Swift only).
enum LoafPush {
  private typealias DecryptFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
  private typealias FreeFn = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
  private typealias NotifiesFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int64, UnsafePointer<CChar>?) -> Int32

  private static let fns: (DecryptFn, FreeFn, NotifiesFn)? = {
    // <appex>/../../Frameworks: the app's, as Task 3 recorded the name.
    let lib = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Frameworks/loaf_push.framework/loaf_push").path
    guard let h = dlopen(lib, RTLD_NOW), let d = dlsym(h, "loaf_push_decrypt"),
      let f = dlsym(h, "loaf_push_free"), let n = dlsym(h, "loaf_push_notifies")
    else { return nil }
    return (
      unsafeBitCast(d, to: DecryptFn.self), unsafeBitCast(f, to: FreeFn.self),
      unsafeBitCast(n, to: NotifiesFn.self)
    )
  }()

  static func decrypt(_ pickle: String, _ userId: String, _ ciphertext: String) -> String? {
    guard let fns else { return nil }
    guard let out = fns.0(pickle, userId, ciphertext) else { return nil }
    defer { fns.1(out) }
    return String(cString: out)
  }

  /// nil when the library is missing or the verdict is undecidable: the
  /// caller shows the message.
  static func notifies(
    _ rules: Data, _ event: [String: Any], _ members: Int?, _ power: [String: Any]?
  ) -> Bool? {
    guard let fns, let rulesText = String(data: rules, encoding: .utf8),
      let eventData = try? JSONSerialization.data(withJSONObject: event),
      let eventText = String(data: eventData, encoding: .utf8)
    else { return nil }
    let powerText = power
      .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
      .flatMap { String(data: $0, encoding: .utf8) }
    switch fns.2(rulesText, eventText, Int64(members ?? -1), powerText) {
    case 1: return true
    case 0: return false
    default: return nil
    }
  }
}
```

Replace `Frameworks/loaf_push.framework/loaf_push` with the path Task 3 recorded, if it differs.

- [ ] **Step 3: Build for the simulator, and check the appex is embedded with the library next to it**

Run: `mise run build:ios:sim && ls build/ios/iphonesimulator/Runner.app/PlugIns/`
Expected: `NotifyService.appex`.

- [ ] **Step 4: Commit**

```bash
git add ios/NotifyService ios/Runner.xcodeproj/project.pbxproj
git commit -m "feat(push): the Notification Service Extension decrypts and titles each push"
```

---

### Task 8: The iOS channel end, plus the pusher

**Files:**
- Create: `ios/Runner/NotifyBridge.swift`, `lib/push/ios_push.dart`, `lib/push/pusher.dart`, `test/push/ios_push_test.dart`, `test/push/pusher_test.dart`
- Modify: `ios/Runner/AppDelegate.swift` (create the bridge once the engine exists, and forward `didRegisterForRemoteNotificationsWithDeviceToken` / `didFail…`), `lib/main.dart` (on iOS, `IosPush` supplies `noticeRoutes`; start `Pusher` after sign-in)

**Interfaces:**
- Produces:
  - `class IosPush { IosPush({MethodChannel? channel}); Stream<MessageRoute> get clicks; Future<void> prepare(); Future<String?> pushToken(); Future<void> withdraw(String roomId, {DateTime? before}); Future<bool> blocked(); Future<void> openSystemSettings(); }`
  - `const pushGateway = 'https://push.matrix.loaf.moe/_matrix/push/v1/notify';` (one Loaf Chat gateway serves every homeserver; a comment says so)
  - `class Pusher { Pusher({required Client client, required IosPush push, required bool Function() enabled, bool release = kReleaseMode, String gateway = pushGateway}); Future<void> sync(); }`. `sync()` sets the pusher when enabled, and deletes this device's pusher when disabled.
- The channel contract (new or changed):
  - `pushToken` → `String?`: the hex APNs token, or nil after a 20 s timeout or a failure. It calls `registerForRemoteNotifications`.
  - `withdraw {roomId, before: int? (ms since epoch)}`: removes delivered notifications with `threadIdentifier == roomId`, and when `before` is set, only those whose `date` is before it.

- [ ] **Step 1: Write the failing Dart tests**

`ios_push_test.dart` mocks the channel with `TestDefaultBinaryMessengerBinding`, mirroring the existing `channel_notifications` tests. The cases:
- **Clicks:** an incoming `click {roomId, eventId}` comes out of `clicks` as `MessageRoute`.
- **Ready:** listening sends `ready`.
- **Withdraw:** `withdraw('!r', before: DateTime.fromMillisecondsSinceEpoch(5))` sends `{roomId: '!r', before: 5}`.
- **No native end:** `MissingPluginException` makes `pushToken()` return null.

`pusher_test.dart` uses `FakeMatrixApi`, recording `POST /_matrix/client/v3/pushers/set` bodies. The cases:
- **Release, enabled, token `ab12`:** posts `{"app_id": "moe.loaf.chat.ios", "pushkey": "ab12", "kind": "http", "app_display_name": "Loaf Chat", "data": {"url": <gateway>, "format": "event_id_only"}, ...}`.
- **Not release:** posts nothing.
- **Enabled → disabled:** after a sync with a token, sets `kind: null` for the same `app_id` and `pushkey` (the Matrix way to delete).
- **No token:** `pushToken` returns null, and nothing is posted.

The gateway URL in tests is `https://push.example/_matrix/push/v1/notify`. Never use a real one.

- [ ] **Step 2: Run, watch them fail**

Run: `mise run test -- test/push/ios_push_test.dart test/push/pusher_test.dart`
Expected: FAIL, because nothing is defined yet.

- [ ] **Step 3: Implement the Dart side**

`IosPush` follows `ChannelDesktopNotifications`' pattern: the broadcast controller sends `ready` on listen, and `MissingPluginException` is swallowed. `Pusher.sync()`:

```dart
Future<void> sync() async {
  if (!release) return;
  final token = await push.pushToken();
  if (token == null) return;
  final id = PusherId(appId: 'moe.loaf.chat.ios', pushkey: token);
  try {
    if (enabled()) {
      await client.postPusher(
        Pusher(
          appId: id.appId,
          pushkey: token,
          appDisplayName: 'Loaf Chat',
          deviceDisplayName: client.deviceName ?? 'iPhone',
          kind: 'http',
          lang: 'en',
          data: PusherData(url: Uri.parse(gateway), format: 'event_id_only'),
        ),
        append: false,
      );
    } else {
      await client.deletePusher(id);
    }
  } on Object catch (e) {
    // Push is a convenience; the app works without it. Tried again next launch.
    Logs().w('[loaf] pusher', e);
  }
}
```

Check `deletePusher`'s body in the SDK (`matrix_api.dart:162`) to confirm it sends `kind: null`; the test pins it. In `main.dart` on iOS (not mock), set `noticeRoutes = IosPush().clicks`. In the shell, call `Pusher.sync()` once after the first sync, and again whenever the Notifications toggle changes. Sign-out needs nothing: the homeserver deletes a device's pushers when that device logs out (Matrix spec, `POST /logout`). Write that as a comment where sign-out lives.

- [ ] **Step 4: The Swift side**

`NotifyBridge.swift` on iOS is a cut-down copy of the macOS bridge (read `macos/Runner/NotifyBridge.swift` first). It has the same `held`/`ready` click logic and the same `prepare` and `blocked`. Then:
- `openSettings` uses `UIApplication.openNotificationSettingsURLString` on iOS 16 and later, and falls back to `UIApplication.openSettingsURLString`.
- `withdraw` filters delivered notifications by `request.content.threadIdentifier == roomId` and, when given, by `date < before`.
- `pushToken` keeps the pending `FlutterResult`, calls `UIApplication.shared.registerForRemoteNotifications()`, and answers from `AppDelegate`'s callbacks, or with nil after 20 s.
- `willPresent` calls `completionHandler([])`: in front, the notifier and the chime handle it.
- `didReceive` reads `roomId` and `eventId` from `userInfo`. The extension wrote both keys there; when the extension didn't run, it falls back to the gateway's top-level `room_id` and `event_id`.
- It is created in `didInitializeImplicitFlutterEngine` with `engineBridge.applicationRegistrar.messenger()`. Check the exact name on `FlutterImplicitEngineBridge` in the Flutter engine headers under `ios/Flutter` or `~/.pub-cache` / the Flutter SDK. Set `UNUserNotificationCenter.current().delegate` in `didFinishLaunching`, before `super`, so that a tap that launched the app isn't lost.

- [ ] **Step 5: Run the tests, then build**

Run: `mise run test -- test/push && mise run build:ios:sim`
Expected: PASS, and the build succeeds.

- [ ] **Step 6: Commit**

```bash
git add ios/Runner lib/push lib/main.dart lib/ui/shell/app_shell.dart test/push
git commit -m "feat(push): iOS registers a pusher and opens the message a push was about"
```

---

### Task 9: Withdraw on read

**Files:**
- Create: `lib/push/push_sweeper.dart`, `test/push/push_sweeper_test.dart`
- Modify: `lib/ui/rooms/rooms.dart` (`DateTime? get settledBefore`), `lib/matrix/matrix_rooms.dart`, `lib/ui/mock/mock_rooms.dart` (returns null), `lib/ui/shell/app_shell.dart`

**Interfaces:**
- Produces:
  - `Rooms.settledBefore`: every event sent before this time is in the room counts. It is the completion time of the sync *before* the latest one, because each sync's request starts when the previous one completes. It is null until two syncs have completed.
  - `class PushSweeper { PushSweeper({required Rooms rooms, required Future<void> Function(String roomId, {DateTime? before}) withdraw}); void dispose(); }`

- [ ] **Step 1: Write the failing tests**

All use a fake `Rooms` with settable channels and `settledBefore`:
- **Null `settledBefore`:** a room at 0 unread withdraws nothing.
- **Read room:** with `settledBefore = T`, a room at 0 unread and 0 mentions calls `withdraw('!r', before: T)` once. A second notification with the same `T` doesn't call it again.
- **Unread room:** never withdrawn.
- **`T` advances:** the same read room is withdrawn again with the new `before`, which catches a notice delivered after the first sweep.
- **The two `MatrixRooms` syncs:** after two `onSync` events at known clock times `c1` and `c2`, `settledBefore == c1`. This one uses an injected `now`.

- [ ] **Step 2: Run, fail; implement; run, pass**

The sweeper listens to `rooms`. When `settledBefore` is non-null and differs from the last swept value, it withdraws every read room (any joined channel with `unread == 0 && mentions == 0`) with `before: settledBefore`. The native side is a no-op for a room with nothing delivered. In `app_shell.dart`, create it on iOS only, with `IosPush.withdraw`.

Run: `mise run test -- test/push/push_sweeper_test.dart test/matrix`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add lib/push/push_sweeper.dart test/push/push_sweeper_test.dart lib/ui/rooms/rooms.dart lib/matrix/matrix_rooms.dart lib/ui/mock lib/ui/shell/app_shell.dart test/matrix
git commit -m "feat(push): a room read anywhere takes its notifications back"
```

---

### Task 10: No second chime for what push already announced

**Files:**
- Modify: `lib/matrix/matrix_arrivals.dart`, `test/matrix/matrix_arrivals_test.dart`, `lib/ui/shell/app_shell.dart` (lifecycle hook, iOS only)

**Interfaces:**
- Produces: `MatrixArrivals.pushedUntil(DateTime t)`: from now on, an event with `originServerTs` before `t` is not an arrival.

- [ ] **Step 1: Write the failing test**

```dart
test('after a resume, messages sent while backgrounded are not arrivals', () async {
  // started at t0; paused at t1; resumed at t2 → pushedUntil(t2)
  // event at t1+1s arrives in the catch-up sync → no arrival
  // event at t2+1s → an arrival
});
```

Fill in the test using the existing harness in `test/matrix/matrix_arrivals_test.dart`, with the same fake-clock pattern it uses for `_startedAt`.

- [ ] **Step 2: Run, fail; implement; run, pass**

`pushedUntil` raises the `_startedAt` floor to `t`: the same filter, moved later. In `app_shell.dart`, on iOS, an `AppLifecycleListener(onResume: …)` calls it with `DateTime.now()`, **only when a pusher is active** (`Pusher` exposes `bool get registered`). Without push, nothing announced those messages, and the chime is right.

Run: `mise run test -- test/matrix/matrix_arrivals_test.dart`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add lib/matrix/matrix_arrivals.dart test/matrix/matrix_arrivals_test.dart lib/ui/shell/app_shell.dart lib/push/pusher.dart
git commit -m "fix(notify): on iOS a resume doesn't chime for messages push delivered"
```

---

### Task 11: Settings

**Files:**
- Create: `lib/ui/settings/channel_default.dart`, `test/ui/settings/channel_default_test.dart`
- Modify: the Notifications settings section widget (find it with `git grep -n "show message text" lib/ui/settings`), and its widget test

**Interfaces:**
- Produces: `enum ChannelDefault { all, mentions }`, plus `ChannelDefault readDefault(PushRuleSet rules)` and `Future<void> writeDefault(Client client, ChannelDefault d)`.
  - Writing `all` enables `.m.rule.message`. Writing `mentions` disables it.
  - Reading returns `mentions` when `.m.rule.message` is disabled, and `all` otherwise.
  - **`.m.rule.encrypted` is never disabled**, at either setting. It is what
    carries an encrypted message to the phone, where the extension decrypts it
    and applies the real rules. Disabling it would hand the decision back to a
    server that cannot see inside the message.
  - Plus `Future<void> repairEncryptedRule(Client client)`: enables
    `.m.rule.encrypted` when it is disabled, once, at sign-in and on the first
    sync of an upgrade. The shipped build disabled it alongside
    `.m.rule.message`, so a user who chose mentions-only before this release
    has it off on the server, and without the repair their encrypted channels
    would push nothing at all and the extension would never run.

- [ ] **Step 1: Write the failing tests**

- **Writes:** using `FakeMatrixApi` (which records requests), `writeDefault(mentions)` sends `PUT …/pushrules/global/underride/.m.rule.message/enabled {"enabled": false}` and **nothing else**: assert on the recorded request list, so a future edit that touches `.m.rule.encrypted` again fails here. The DM rules (`.m.rule.room_one_to_one`, `.m.rule.encrypted_room_one_to_one`) and the mention overrides are never touched either, which is what keeps DMs and unencrypted mentions notifying.
- **The repair:** with `.m.rule.encrypted` disabled, `repairEncryptedRule` sends `PUT …/pushrules/global/underride/.m.rule.encrypted/enabled {"enabled": true}`; with it already enabled, it sends nothing.
- **Reads:** `readDefault` reads them back.
- **Widget, on iOS (`debugDefaultTargetPlatformOverride`):**
  - Notifications, Sound and Show message text show.
  - With `blocked() == true`, `ios is blocking notifications from loaf chat.` and `open system settings` show.
  - The Channels choice shows on every platform.
  - `direct messages always notify.` shows as plain text.

- [ ] **Step 2: Run, fail; implement; run, pass**

On iOS, Notifications, Sound and Show message text are now honest: push uses all three. Lift step D's `isDesktop` gate for them (memory `honest-controls`). Toggling Notifications calls `Pusher.sync()`. Call `repairEncryptedRule` where the client finishes its first sync, beside the rules writer from Task 5a.

The Settings copy does not change, and it is now true on iOS without a caveat: a mentions-only encrypted channel pushes a mention and nothing else.

Run: `mise run test -- test/ui/settings`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add lib/ui/settings test/ui/settings
git commit -m "feat(notify): Settings sets the channel default everywhere, and push on iOS"
```

---

### Task 12: Release wiring, plus the entitlement gate

**Ask Chris before committing this task** (memory `ask-before-ci-risk`). Show them the diff of `ios.sh`.

**Files:**
- Modify: `tool/release/ios.sh`
- Create: `tool/release/ios-export-local.plist`

- [ ] **Step 1: The entitlement gate, before the upload**

The archive is unsigned, and the export both signs and uploads. Nothing yet proves that `aps-environment` and the App Group survive that path. So first export once to a local folder, with the same cloud signing and nothing new created. Then check the signed result, and only then run the existing upload export unchanged.

Create `tool/release/ios-export-local.plist`, a copy of `ios-export.plist` with `destination` set to `export`. In `ios.sh`, before the upload block:

```bash
# The archive is unsigned; export signs it. Prove the signed app and its
# extension carry push and the App Group before anything reaches Apple.
xcodebuild -exportArchive -archivePath "$work/Runner.xcarchive" \
  -exportOptionsPlist tool/release/ios-export-local.plist \
  -exportPath "$work/check" -allowProvisioningUpdates \
  -authenticationKeyPath "$work/key.p8" \
  -authenticationKeyID "$NOTARY_KEY_ID" \
  -authenticationKeyIssuerID "$NOTARY_ISSUER_ID"
unzip -q "$work/check/"*.ipa -d "$work/ipa"
app="$work/ipa/Payload/Runner.app"
ents() { codesign -d --entitlements - --xml "$1" 2>/dev/null | plutil -convert json -o - -- -; }
for target in "$app" "$app/PlugIns/NotifyService.appex"; do
  ents "$target" | grep -q '"group.moe.loaf.chat"' \
    || { echo "::error::$(basename "$target") lacks the App Group"; exit 1; }
done
ents "$app" | grep -q '"aps-environment":"production"' \
  || { echo "::error::Runner.app lacks aps-environment=production"; exit 1; }
ents "$app/PlugIns/NotifyService.appex" | grep -q '"com.apple.developer.usernotifications.filtering":true' \
  || { echo "::error::NotifyService.appex lacks the filtering entitlement"; exit 1; }
ls "$app/Frameworks" | grep -qi loaf_push \
  || { echo "::error::loaf_push is not in the app's Frameworks"; exit 1; }
```

This adds roughly a minute to the iOS job. If the gate fails on the first E release, **stop and tell Chris** with the job log. Don't change signing to get past it.

- [ ] **Step 2: Commit (after Chris's yes), merge, and tag**

Follow the handoff's process: merge onto `origin/main` from the worktree, run `mise run test:all` on the merged tree, push, and tag the next free version. Watch the run (memory `release-test-via-ci`).

---

### Task 13: Hand test on TestFlight

This needs Chris's phone. Ask what they saw for anything a screenshot can't show.

1. **Install and permission.** Install from TestFlight, then sign in. The permission prompt appears, and Settings shows Notifications on.
2. **An encrypted DM with the phone locked.** mochi sends `hello`, using the throwaway sender in the handoff. Expected: `mochi` / `hello` with the chime. If it shows `encrypted message`, the phone's session lacks the key: verify it with the recovery key and retry.
3. **Mentions only, in an encrypted channel.** This is what the entitlement bought, and it is the case to spend time on. With Channels set to mentions only: mochi's plain message shows nothing, and mochi's mention of you shows a notification with the message in it. Then set the channel itself to mute and check the mention shows nothing. In an unencrypted channel, both still behave the same way.
   - A push that arrives and is dropped looks exactly like a push that never came, so check the extension ran: attach the phone, and in Console.app filter on `moe.loaf.chat.ios.notify`. A drop logs `dropped`; nothing at all means the gateway or the pusher, not the rules.
   - A **blank** notification, rather than none, means the filtering entitlement is missing from the signed appex. Task 12's gate should have caught it; say so if it did not.
   - Compare against the Mac for each case: the two must agree, and they are the same corpus (Task 3b).
4. **A level changed on another device while the phone sleeps.** Mute the channel on the Mac, wait a minute, then have mochi message it. The phone shows nothing: the extension's hour-old refresh fetched the new rules. Then with the phone awake and synced, the same holds from the cache.
5. **Tap with the app backgrounded.** It opens the DM at the message, which glows.
6. **Tap with the app killed** (a cold start). It opens the message after the first sync.
7. **Read on the Mac.** The phone's notification disappears after the phone's next sync.
8. **Show message text off.** The notification says `new message`.
9. **Notifications off.** No push, and the server's pusher list (`GET /_matrix/client/v3/pushers` with mochi's harness, or Chris's client) no longer lists the phone.
10. **Background for 5 minutes, then open.** Console.app on the Mac, with the phone attached: no `0xdead10cc` termination for `moe.loaf.chat.ios`.
11. **Update over v0.1.19** (the old database location). The app stays signed in, and older encrypted messages still read.
12. **Update with mentions-only chosen on the old build.** Set Channels to mentions only on v0.1.19 first, then update: `.m.rule.encrypted` is back on (check it in Settings on the Mac, or `GET /_matrix/client/v3/pushrules/`), and an encrypted mention pushes. Without the repair in Task 11 this is the case that silently stays broken.

When testing ends, clean up as the handoff says: log mochi's token out, and delete `mochi.json`, `mochi.sqlite` and `mochi-media`.
