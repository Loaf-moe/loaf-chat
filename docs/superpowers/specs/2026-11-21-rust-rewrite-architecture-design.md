# Loaf Chat, native: architecture

Loaf Chat is being rewritten without Flutter: a Rust core that owns all
application state, a GPUI desktop app for Linux, macOS and Windows, and a
SwiftUI app for iOS. This spec fixes the architecture every feature is built
on. Features themselves are specced one at a time as they are ported.

## Why

The Dart build performs badly on Linux. Video from
calls goes through a CPU colour conversion and texture copy on every frame,
and in places falls back to software rendering. A like-for-like test
(`poc/gpui-video` on branch `poc/gpui-video`) measured the replacement path
against flutter_webrtc's:

| 2026-11-20, Ryzen 9 5900X, RX 9070, Wayland | GPUI CPU | Flutter CPU | GPUI GPU | Flutter GPU |
|---|---:|---:|---:|---:|
| 4 × 720p30 | 3.5 | 12.0 | 1.78 | 4.55 |
| 9 × 720p30 | 6.3 | 20.1 | 3.68 | 7.37 |
| 4 × 1080p30 | 5.7 | 20.6 | 2.19 | 7.55 |

CPU is % of one core, GPU the process's own engine time. The Flutter path also
renders BT.709 video with BT.601 colours.

## Ground rules

- **Features 1:1, architecture new.** Each feature reproduces main's behaviour
  exactly: defaults, copy, edge cases, failure handling (main's specs and code
  are the reference). How the code is organised is decided fresh; nothing of
  the Flutter structure is carried over.
- **Production grade.** Every change is specced, planned and reviewed.
- **Platforms:** Linux, macOS, Windows desktop; iOS. **Android is dropped**:
  no targets, seams or CI.
- **No migrations.** The apps are prerelease. The rewrite starts from a fresh
  sign-in; nothing is read from the Dart app's storage.
- **MSCs are spec.** Where Matrix has an MSC for something, it is used.
  Simplified sliding sync (MSC4186) is required of the homeserver.

## Stack

| Layer | Choice |
|---|---|
| Core | Rust, tokio |
| Matrix | matrix-rust-sdk and matrix-sdk-ui (`SyncService`, `RoomListService`, `Timeline`, `NotificationClient`) |
| Calls | livekit (Rust SDK) on every platform |
| Desktop | GPUI and gpui-component ("GPUIKit", gpui-kit.com), on the `gpui-pre` snapshot gpui-component pins; GPUI forked in-repo |
| iOS | SwiftUI over UniFFI bindings |
| iOS project | XcodeGen (`ios/project.yml`); the `.pbxproj` is generated, not committed |
| Tooling | `mise.toml` pins toolchains and defines tasks |

## Repository

```
rust branch
├─ Cargo.toml              workspace; [patch.crates-io] → vendor/
├─ mise.toml
├─ crates/
│  ├─ loaf-core/           state and services; no UI or FFI dependencies
│  ├─ loaf-ffi/            UniFFI surface → LoafCore Swift package
│  ├─ loaf-desktop/        GPUI app
│  └─ gpui-fork-tests/     tests for vendor/ (see "The GPUI fork")
├─ vendor/gpui-pre*/       the GPUI fork
├─ ios/                    project.yml; app; Notification Service Extension
└─ docs/superpowers/       specs, plans
```

## 1. The core

**One handle.** A shell calls `Core::start(CoreConfig { data_dir, platform })`
once; `platform` carries the platform-service implementations (section 5). It
returns `Arc<Core>` with one handle per area: `session()`, `rooms()`,
`timeline(room_id)`, `calls()`, `notifications()`, `settings()`.

**Commands in.** Every action is an `async fn` returning
`Result<T, AreaError>`, one `thiserror` enum per area. Errors are typed so a
shell can tell, say, a wrong password from an unreachable server without
parsing text.

**State out.** Single values (session state, call state) are `eyeball`
observables. Lists (rooms, timeline, participants) are `eyeball-im` vectors
emitting `VectorDiff`, so a new message is one `PushBack`. Values are
immutable view models the core defines (`RoomSummary`, `TimelineItem`,
`Participant`, …). No matrix-sdk or livekit type crosses the boundary.

**Runtime.** The core owns a tokio runtime. Each public `async fn` runs its
work on that runtime and returns a future any executor can await, so GPUI's
executor and Swift's concurrency never need tokio.

**Inside.** Each area runs tasks that subscribe to SDK streams, apply Loaf's
own rules (unread state, mentions, the notifier's decision) and publish view
models. A task that fails publishes an error state; a view is never silently
stale.

**Lifecycle.** The shell reports `core.set_app_state(Foreground | Background)`.
The core uses it for sync and for the notifier.

## 2. Session and sync

One account per install, as in main.

**Signing in.** `core.session().begin_sign_in()` returns a `SignInFlow` that
starts discovering **loaf.moe** at once, so the screen opens on loaf.moe's
ways in: "continue with loaf.moe" (SSO through Kanidm), and the password form
behind a link because loaf.moe advertises `m.login.password`.

- **Another server** is `flow.set_server(input)`: a name, a URL, or a full
  user id of which only the domain is kept. A full id typed into the username
  field re-points the server after a debounce. The screen shows the name typed,
  never the delegated base URL. Three failures are told apart: nothing
  answered; not a Matrix server; `.well-known` points to a server that didn't
  answer.
- **Ways in** come from the server: OAuth 2.0 (MSC3861) where advertised; SSO
  with its identity providers; password only where `m.login.password` is
  offered.
- **The browser step** goes through `AuthBrowser`:
  `ASWebAuthenticationSession` on iOS and macOS; the system browser and a
  loopback listener on Linux and Windows, with "finish in your browser" while
  waiting.
- **Password errors** are typed: `M_FORBIDDEN` → wrong credentials;
  `M_LIMIT_EXCEEDED` carries `retry_after` for the countdown.
- **Stale answers are dropped.** Every flow and attempt has an identity. An
  answer arriving after cancel, a server change or a newer attempt changes
  nothing and never signs in.

**Keeping the session.** Access and refresh tokens are kept in the platform
keychain (`SecretStore`); on iOS in a keychain group shared with the
extension. matrix-sdk's SQLite store lives in the data directory (on iOS, the
App Group container), encrypted with a key also held in the keychain. A
stored session restores signed in with no network; sync retries.

**Token refresh** is matrix-sdk's. New tokens are persisted as soon as the SDK
reports them. The SDK's cross-process refresh lock is enabled so the app and
the iOS extension never race. A refresh in flight is never shown as signed
out.

**Session state**, one observable:

| State | Meaning |
|---|---|
| `SignedOut` | |
| `SigningIn(step)` | discovery, choosing a way in, browser wait, password busy |
| `SignedIn { user, device, trust }` | `trust` is `Unknown`, `Unverified` or `Verified`. `Unknown` while keys load is never read as "no identity", so recovery is never offered over a real identity |
| `SoftLoggedOut { user }` | `soft_logout: true`: the device's keys are kept; sign-in is locked to that account ("sign in again as …"). Signing out instead is a separate, confirmed command |
| `SessionRevoked` | the server ended the session; shown, then signed out |

**Signing out** removes this device's pusher, logs out on the server, then
wipes the store and keychain entries. The local wipe happens even when the
server can't be reached.

**Sync.** After sign-in or restore the core starts `SyncService`. Its state
(`Running`, `Offline` retrying with backoff, `Error`) is observable. Desktop
keeps syncing in the background. iOS stops sync when backgrounded, leaving it
to push, and resumes in the foreground.

**Rooms.** `RoomListService` entries and the space hierarchy are mapped into
`RoomSummary` and `Space`. Unread state and mentions follow main's rules,
computed by the core: unread follows messages, not push rules; mentions by
`m.mentions` with the body fallback; limited syncs filled from `/messages`
up to 99 events.

Verification and recovery are a later feature. This spec only requires that
`trust` is correct.

## 3. Desktop

`loaf-desktop` is one binary for Linux, macOS and Windows.

- **`app/`**: startup. Builds the platform implementations, starts the core,
  opens the window, routes session state to sign-in or the shell.
- **`bridge/`**: the only code that subscribes to the core. Each observable
  becomes a GPUI entity updated from a task on GPUI's executor, followed by
  `cx.notify()`; only views reading that entity re-render. `VectorDiff`s are
  applied to a local `Vec`; rooms and timelines render through GPUI's
  virtualized lists. Commands are spawned on the core's futures, errors routed
  to the view that asked.
- **`ui/`**: Loaf's design system over gpui-component: theme tokens for light
  and dark, Lora, Outfit and IBM Plex Mono embedded. Feature code uses these
  components only, never gpui-component directly.
- **`features/<name>/`**: views per feature. No logic.
- **`platform/`**: the desktop implementations of section 5, each added with
  its feature: `keyring` for `SecretStore`; `ASWebAuthenticationSession` via
  objc2 or browser plus loopback for `AuthBrowser`; `UNUserNotificationCenter`,
  Windows toasts, the portal or `org.freedesktop.Notifications` (`zbus`) for
  `Notifications`; each platform's alert player for `Sound`.
- **Video** uses `surface(frame)`: I420 frames on Linux and Windows through
  the fork, `CVPixelBuffer` on macOS through stock GPUI.

Window chrome, single instance and deep links, and the self-updater are later
features within this structure.

### The GPUI fork

GPUI's wgpu renderer (Linux) declared a video pipeline but never drew it, and
`surface()` accepted only `CVPixelBuffer`. The fork:

- adds `VideoStream`, `VideoFrame` and `I420Planes` to `gpui-pre`. A frame
  wraps the decoder's buffer without copying and is validated when made, so the
  renderer cannot read out of bounds. `surface(frame)` and
  `Window::paint_video_frame` work off Apple platforms;
- implements the draw in `gpui-pre-wgpu` (`wgpu_video.rs`): three `R8Unorm`
  textures per stream, re-uploaded only on a new frame generation, the
  decoder's stride passed to `write_texture` as it is; per-draw bounds, clip
  and colour matrix in a dynamic-offset uniform; streams not painted in a frame
  evicted; YUV→RGB in the shader for BT.601 or BT.709, limited or full range.

It lives in `vendor/gpui-pre` and `vendor/gpui-pre-wgpu`, applied with
`[patch.crates-io]`, and is reviewed in the same PRs as the code using it.
Upstreaming is not a goal. Snapshots move only when gpui-component moves, all
`gpui-pre-*` crates together, by re-vendoring and replaying the patch, gated on
the patch tests and the colour check. The DirectX renderer (Windows) gets the
same primitive as part of the calls feature.

The vendored crates' own test targets cannot build outside Zed's monorepo
(they read its assets and dev-dependencies), so the fork's tests live in a
workspace crate of ours, `crates/gpui-fork-tests`: frame validation, naga
validation of the shaders the renderer compiles, and the colour check and
cost measurement brought over from the PoC (`tests/patch.rs`,
`tools/check_colours.py`, `tools/measure.py`).

## 4. iOS

**`loaf-ffi`** is UniFFI over `loaf-core`, with no logic of its own.
Commands become `async throws`; area errors become Swift error enums.
Subscriptions are `subscribe(listener) -> TaskHandle`, the listener a Swift
callback interface receiving values or `VectorDiff`s; dropping the handle
unsubscribes. It builds static libraries for `aarch64-apple-ios` and
`aarch64-apple-ios-sim`, packaged with the generated Swift as the local Swift
package `LoafCore`.

**`ios/`**, generated from `project.yml` (`mise run ios:project`), keeps
main's identifiers: app `moe.loaf.chat.ios`, extension
`moe.loaf.chat.ios.notify`, App Group `group.moe.loaf.chat`, team
`6W2A5N37N3`. Entitlements: push, the App Group, a shared keychain group, and
notification filtering.

**Swift:** `Stores/` holds `@MainActor` `@Observable` classes that own
`TaskHandle`s; they are the only Swift that talks to `LoafCore`. `UI/` holds
Loaf's tokens and components. `Features/<name>/` holds SwiftUI views,
mirroring the desktop's features.

**Calls** run through the core's livekit on iOS too, so call state has one
source of truth. Swift owns only the CallKit and `AVAudioSession` glue, driven
through `CallSystem`.

**Notification Service Extension.** It links `LoafCore` but starts only the
notification entry point, `notification(room_id, event_id)`, which opens the
shared store through `NotificationClient` under the cross-process lock,
fetches and decrypts the event (syncing for missing room keys if needed),
judges it with the same push-rule evaluator as the app, and returns
`Show { title, body, thread, route }` or `Drop` (the filtering entitlement).
Fallbacks are main's: "Encrypted message" with no key, "New message" when the
fetch fails. The extension's memory limit is about 24 MB, so this entry point
starts none of the app's services, and its peak memory is tested.

The push gateway URL is a build setting, `LOAF_PUSH_GATEWAY`, as in main.

## 5. Platform services

Defined in `loaf-core::platform`, handed to `Core::start` as
`Arc<dyn Trait + Send + Sync>`. Each is a small async trait, added only when
the feature needing it is ported.

| Trait | Calls | Arrives with |
|---|---|---|
| `SecretStore` | `get`, `set`, `delete` | sign-in |
| `AuthBrowser` | `authenticate(url, callback) -> Result<Url, AuthCancelled>` | sign-in |
| `Notifications` | `permission() -> Granted / Denied / NotApplicable`, `show(Notice)`, `withdraw(room)`, `open_settings()` | notifications |
| `Sound` | `chime()` | notifications |
| `PushRegistration` | `register() -> Option<PushToken>`, `unregister()` | iOS push |
| `CallSystem` | `report_incoming`, `report_connected`, `report_ended`, `set_audio_route` | calls |
| `Updater` | `check()`, `apply(update)` | desktop updates |

- **The core decides; traits execute.** No policy lives in a trait. `Notice`
  is finished text and a route.
- **Answers come back as commands:** a notification tap is `core.open(route)`,
  a CallKit answer `core.calls().answer(id)`, a new push token
  `core.push().token_changed(token)`. Traits never call into the core.
- **Differences are values:** Linux has no notification permission, so
  `permission()` is `NotApplicable` and settings hide that line, as in main.
  Core logic has no `#[cfg]`.
- **Failures are typed, never fatal.** A failed `show` is logged. A failed
  `SecretStore::set` fails sign-in rather than leave a session that cannot be
  restored.
- Swift implements them as UniFFI foreign traits
  (`#[uniffi::export(with_foreign)]`); desktop in `loaf-desktop/platform/`.
- `loaf-core` ships fakes for each, so every decision is tested headless.

## 6. Errors, tests and gates

**Errors and logs.** SDK errors are mapped into area enums at the boundary.
`loaf-core` and `loaf-ffi` deny `clippy::unwrap_used`, `expect_used`, `panic`
and `indexing_slicing` outside tests; UniFFI turns a panic that escapes into an
error rather than a Swift crash. Logging is `tracing`, a span per area, to
rotating files in the data directory. Message bodies, tokens and keys are never
logged, and a test checks it.

**Tests.**

1. Core unit tests: pure logic, platform fakes, controllable time.
2. Core integration tests against Synapse in Docker with simplified sliding
   sync, driven by real matrix-sdk clients: sign-in (password; SSO and OAuth
   through `FakeAuthBrowser`), offline restore, soft logout, sync, rooms, E2EE
   between two clients, `NotificationClient` decrypt and filter.
3. Parity suites: main's tests define "1:1". Each feature's plan names the
   main tests it ports (the 245-case push-rules table as is; others rewritten
   to the new API). A feature is done when they pass.
4. Desktop view tests on GPUI's `TestAppContext`.
5. iOS: XCTest over stores and bindings; the extension tested with a peak
   memory assertion.

**Gates.**

| Gate | Threshold |
|---|---|
| Desktop idle | 0% CPU when nothing changes |
| Linux video | colour check passes; 4 × 720p30 ≤ 6% of one core and ≤ 3% GPU on the reference machine |
| iOS extension | peak memory ≤ 20 MB |

Features that cost something add their own (cold start to a restored room
list, for one). GPU gates run on a Linux machine with a real GPU.

**CI** (GitHub Actions). Every PR: `cargo fmt --check`, `cargo clippy -D
warnings`, all tests, `cargo deny` (licences compatible with AGPL-3.0,
advisories, no duplicate SDK versions), and **rust-doctor** over `crates/`
(not `vendor/`). rust-doctor's version is pinned in `mise.toml`. Its gate: no
new findings in changed files (`--diff`), and the workspace score never drops;
the score after slice one is the floor, raised as it improves. Each
suppression carries its reason on the same line. Its SARIF is uploaded for
inline PR annotations. Advisories are left to `cargo deny` so a CVE fails CI
once.

Jobs: Linux (all of the above, Synapse integration, desktop build); macOS
(desktop build, XCFramework, iOS build and XCTest); Windows (desktop build).
Changes under `vendor/` also need the patch tests and the colour check.

## Order of work

Each feature gets its own spec, plan and PR.

1. **Workspace and CI**, with sign-in and session (section 2). Brings
   `SecretStore` and `AuthBrowser`, the sign-in screens on desktop and iOS,
   and the CI above.
2. **Sync and the room list:** spaces, channels, unread state.
3. Then main's features in its own order: timeline; E2EE and verification;
   media; notifications and iOS push; calls (with the Windows video port);
   window chrome; desktop updates; releases.

## Out of scope

| | Why |
|---|---|
| Android | Dropped |
| Reading the Dart app's data | No migrations |
| Homeservers without simplified sliding sync | MSC4186 is required |
| Hardware video decode and dmabuf import | A later optimisation; the CPU copy left is wgpu's upload staging |
