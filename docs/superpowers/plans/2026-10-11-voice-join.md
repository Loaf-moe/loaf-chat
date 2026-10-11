# Voice Channels Implementation Plan

**Goal:** Join a voice channel from Loaf Chat on Linux, audio only, in the same call as Cinny users.

**Architecture:** The call UI reads a `Calls` interface. The mock `CallController` implements it for tests, previews and the debug levers. `MatrixCalls` implements it for real over three parts: `call_access.dart` (call server and token), `call_membership.dart` (this device's membership state), and a `CallMedia` interface whose LiveKit implementation lives in `lib/platform/`. `Rooms` hands out its `Calls`; `RoomAbility.calls` says whether there is one.

**Tech Stack:**
- Dart: Flutter 3.47.5 (pinned in `mise.toml`; run every command through `mise exec --`), `matrix` 13.0.0.
- New: `livekit_client` 2.13.1, which brings `flutter_webrtc` 1.6.2+hotfix.4 and a prebuilt libwebrtc.

**Spec:** `docs/superpowers/specs/2026-10-11-voice-design.md`. Read it first; the wire format is there and is not repeated here.

**Not rehearsed.** Unlike earlier plans in this directory, the tasks below were not run on a scratch copy first. Each is planned in detail when it starts.

## Global Constraints

- Two commits, in order. The first is a refactor: every existing test passes unchanged.
- `lib/ui/` imports neither `package:matrix` nor `package:livekit_client`.
- The SDK's `VoIP` module is not used.
- The mock backend keeps every call feature it has. A control the real backend cannot honour is not drawn there.
- Tests use no network and no native library. `MatrixCalls` is tested against the fake homeserver, a fake call server and an in-memory `CallMedia`.
- `lib/matrix/call_members.dart` (`callOccupancy`) stays the one reader of call memberships.

## Task 1: the call UI reads `Calls`

Commit: `refactor(call): the call UI reads a Calls interface`

**Files**

- New `lib/ui/call/calls.dart`: `abstract interface class Calls implements Listenable`, with the session types it speaks in (`CallSession`, `CallParticipant`, `CallPhase`), moved out of `call_controller.dart` and re-exported from it.
- `lib/ui/call/call_controller.dart`: `class CallController extends ChangeNotifier implements Calls`. Its debug levers, `rings`, `flags`, `connectDelay` and `ringTimeout` stay on the class.
- `lib/ui/call/call_view.dart`, `call_controls.dart`, `voice_channel_page.dart`, `dm_call_panel.dart`: take `Calls`.
- `lib/ui/call/call_tile.dart`, `incoming_call_card.dart`: import `calls.dart` for the types.

**What `Calls` holds:** what the widgets and the shell read, and nothing else.

- You: `me`.
- Call state: `session`, `incoming`, `inCall`, `pinned`, `spotlight`, `volumeOf`, `encrypted`.
- Your state: `muted`, `deafened`, `camera`, `route`, `micDevice`, `cameraDevice`, `sharing`, `micBlocked`, `cameraBlocked`.
- Joining and leaving: `joinVoice`, `startDirect`, `callAgain`, `leave`, `retry`, `accept`, `decline`.
- Controls: `toggleMute`, `toggleDeafen`, `toggleCamera`, `flipCamera`, `setRoute`, `setMicDevice`, `setCameraDevice`, `startScreenShare`, `stopScreenShare`, `pin`, `setVolume`.
- `lobbyState(memberId)`: how someone in a call you have not joined is set up, when known. The mock answers from its `flags`.

`app_shell.dart` is untouched: it still builds a `CallController`, which passes as a `Calls`.

**Verification**

- `mise exec -- dart format --set-exit-if-changed .`
- `mise exec -- flutter analyze`
- `mise exec -- flutter test`, with no test file changed.

## Task 2: joining a voice channel

Commit: `feat(call): join a voice channel and talk`

**Files**

- `pubspec.yaml`, `pubspec.lock`, the generated plugin lists under `linux/`, `windows/` and `macos/`: `livekit_client`.
- `lib/matrix/call_access.dart` and its test (written; held in the working tree until this commit).
- New `lib/matrix/call_membership.dart`: join, refresh on the 60-minute schedule, leave.
- New `lib/matrix/call_media.dart`: the `CallMedia` interface and its plain types.
- New `lib/platform/livekit_media.dart`: `CallMedia` over `livekit_client`.
- New `lib/matrix/matrix_calls.dart`: `MatrixCalls implements Calls`.
- `lib/ui/rooms/rooms.dart`: `Calls? get calls`: the backend's own calls, or null where the shell plays the mock's.
- `lib/ui/mock/mock_rooms.dart`: null. The shell keeps building the mock `CallController`, whose call records write into the shell's state.
- `lib/matrix/matrix_rooms.dart`: takes a `CallMedia`; given one, hands out `MatrixCalls` and claims `RoomAbility.calls`.
- `lib/ui/shell/app_shell.dart`: takes its `Calls` from the rooms, else the mock controller.
- `lib/ui/call/calls.dart` and the call widgets: `Calls` says which of camera, screen sharing, device menus, audio route, per-person volume and DM calls it has; a control for one it lacks is not drawn.
- `lib/main.dart`: gives `MatrixRooms` the LiveKit `CallMedia` on Linux.
- `linux/CMakeLists.txt`: `-Wno-error` for the two plugin targets, whose sources warn under newer clangs.
- `ios/Runner/Info.plist`, `macos/Runner/Info.plist`: microphone and camera usage strings, which Apple requires of a binary that links those APIs.
- `README.md`: what a Linux build fetches.
- `docs/superpowers/plans/2026-09-26-sdk-wiring-roadmap.md`: phase 7's row and deferred lines.

**Tests that change on purpose**

- `test/app_shell_rooms_test.dart`, `test/space_actions_test.dart`: `_FakeRooms` gains `calls`.

**New tests** (lists are written when the task is planned)

- `test/matrix/call_membership_test.dart`: the event as the spec gives it; the state key in both room-version cases; the refresh raising `expires` and carrying `created_ts`; leaving; a refused write.
- `test/matrix/matrix_calls_test.dart`: joining in the spec's order; each failure leaving nothing behind; an encrypted room refused; two clients seeing each other; mute, deafen, speaking; leaving; the room being left while in its call.
- An in-memory `CallMedia` beside them.

**Verification**

- The three commands of Task 1.
- `mise exec -- flutter build linux`, then by hand with a Cinny user in a voice channel:
  - each hears the other;
  - each sees the other listed, and sees the other's mute;
  - the speaking ring follows speech;
  - deafen silences them;
  - leaving removes the row in Cinny at once;
  - joining with the microphone muted sends nothing until unmuted.

## Deferred

Microphone and speaker choice with a voice settings section, per-person volume, calls in encrypted rooms, the other platforms, DM and plain-room occupancy, camera and screen sharing.
