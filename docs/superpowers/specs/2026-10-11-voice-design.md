# Loaf Chat — Voice channels

Loaf Chat lists who is in a voice channel but cannot join one. This spec makes
joining real: audio only, in the same call as people using the Cinny client,
whose calls run in an embedded Element Call. The call UI already exists
(`2026-09-24-calls-design.md`); this spec is what goes behind it.

Roadmap phase 7. Camera, screen sharing, DM ringing and encrypted calls are
separate work.

## Scope

**In:**

- Joining and leaving a voice channel's call.
- Sending and hearing audio.
- Mute, deafen, who is speaking, who is muted.
- The call staying joined while you look at other channels.
- Linux desktop.

**Out:**

| Deferred | Why |
|---|---|
| Calls in encrypted rooms | Element Call encrypts media per participant there; a client without those keys can neither hear nor be heard |
| Camera and screen sharing | The Linux libwebrtc build encodes and decodes in software only; needs its own research |
| DM calls and ringing | Roadmap phase 8 |
| macOS, iOS, Windows, Android | Each needs microphone permissions and its own check by hand; iOS also needs the audio session shared with `loaf_media` |
| Choosing microphone and speaker, voice settings | Follows once joining is solid |
| Per-person volume | `livekit_client` has no volume call; `flutter_webrtc` has one per track |
| Calls whose members publish to another homeserver's SFU | loaf.moe has one SFU |
| Element Call's `matrix_2_0` mode | Needs sticky events (MSC4354), which the homeserver does not have |

## Findings (checked 2026-10-11)

Sources: matrix-js-sdk 41.9.0 (the version in the Element Call fork's lock
file), the Element Call fork at `28da7a19`, the Cinny fork at
`desktop-v4.12.707-beta.1`, `livekit_client` 2.13.1, `flutter_webrtc`
1.6.2+hotfix.4, the `libwebrtc.m150.7871.03` Linux x64 release, and
loaf.moe's own answers.

**The other end**

- Cinny embeds Element Call as a widget
  (`@element-hq/element-call-embedded`, vendored from the fork). Element Call
  writes the call's events; Cinny reads occupancy from matrix-js-sdk's
  `matrixRTC.getRoomSession(room).memberships`.
- Element Call has three wire modes (`src/config/ConfigOptions.ts`): `legacy`,
  `compatibility` and `matrix_2_0`. Memberships in loaf.moe rooms have
  per-device state keys and `focus_selection: "multi_sfu"`, which is
  `compatibility`.
- Element Call encrypts media per participant when the room has an
  `m.room.encryption` state event, and not otherwise
  (`src/e2ee/sharedKeyManagement.ts`).

**The SDK**

- `matrix` 13.0.0's `VoIP` module writes `com.famedly.call.member` with a
  `memberships` list and exchanges keys as
  `com.famedly.call.member.encryption_keys`. Element Call reads neither. The
  module is not used.

**The homeserver (Tuwunel 1.9.1)**

- `.well-known/matrix/client` names one LiveKit focus,
  `https://livekit.loaf.moe`. `/sfu/get` and `/get_token` both exist there.
- `/versions` advertises `org.matrix.msc4143`. It does not advertise
  `org.matrix.msc4140` (delayed events) or MSC4354 (sticky events).

**The media library**

- `livekit_client` depends on `flutter_webrtc`, which links libwebrtc on every
  platform.
- On Linux and Windows, `flutter_webrtc`'s CMake downloads a prebuilt
  libwebrtc at configure time into its own package directory
  (`third_party/downloads/libwebrtc-linux-x64-release.zip`). A zip already at
  that path is used as it is. No checksum is checked.
- The Linux `libwebrtc.so` is 25 MB. It needs `libX11`, `libXcomposite`,
  `libXdamage`, `libXext`, `libXfixes`, `libXrandr`, `libgbm` and `libdrm` at
  load time, and opens PulseAudio or ALSA at run time.
- Its video encoders are libvpx, OpenH264 and libaom; its decoders libvpx,
  dav1d and ffmpeg's H.264. None uses the GPU.
- `livekit_client`'s `Room` is a concrete class. Its tests fake the signalling
  socket and the peer connection through classes that are not exported.
- Echo cancellation, noise suppression and gain control are set when the
  microphone track is made. On Linux they cannot be changed on a live track.

## The wire

Everything here is what Element Call does in `compatibility` mode. Loaf Chat
does the same, so that either client's users see and hear the other's.

**Finding the call server.** The first entry of
`org.matrix.msc4143.rtc_foci` in the homeserver's
`.well-known/matrix/client` with `type: "livekit"`. Its
`livekit_service_url` is the call server.

**Getting in.** A fresh OpenID token from the homeserver
(`POST /user/{userId}/openid/request_token`), then:

```
POST {livekit_service_url}/sfu/get
{ "room": "<room id>", "openid_token": { … }, "device_id": "<device id>" }
→ { "url": "<LiveKit address>", "jwt": "<token>" }
```

An OpenID token is used once.

**Saying you are in.** A state event in the room:

- Type `org.matrix.msc3401.call.member`.
- State key `_{userId}_{deviceId}_m.call`. The leading underscore is left off
  in room versions named `org.matrix.msc3757…` or `org.matrix.msc3779…`.
- Content:

```json
{
  "application": "m.call",
  "call_id": "",
  "scope": "m.room",
  "device_id": "<device id>",
  "membershipID": "<userId>:<deviceId>",
  "expires": 14400000,
  "m.call.intent": "audio",
  "focus_active": { "type": "livekit", "focus_selection": "multi_sfu" },
  "foci_preferred": [
    {
      "type": "livekit",
      "livekit_service_url": "<call server>",
      "livekit_alias": "<room id>"
    }
  ]
}
```

**Staying in.** The event is sent again 60 minutes after joining, less five
seconds, and every 60 minutes after that. Each resend raises `expires` by
another four hours and carries `created_ts`, the time of the first event.
Readers count a membership as expired at `created_ts + expires`, with
`created_ts` falling back to the event's own time and `expires` to four
hours.

**Leaving.** The same state key with content `{}`.

**Who is who.** A member's LiveKit identity is `{userId}:{deviceId}`. A
LiveKit participant with no membership behind it is not shown.

**Audio.** Element Call publishes audio with DTX on and RED off, at LiveKit's
`music` preset. Joining muted publishes no microphone track; the track is
published on the first unmute.

## Design

**One interface for the call UI.** `Calls` (`lib/ui/call/calls.dart`) is what
the shell and the call widgets read: the session, your own mute and deafen,
and join and leave. `CallController` implements it as the mock, keeping its
debug levers and fixture inputs to itself. `Rooms` hands out its `Calls`, as
it does `devices` and `profile`, and `RoomAbility.calls` says whether there is
one.

**The real one.** `MatrixCalls` (`lib/matrix/matrix_calls.dart`) implements
`Calls` over three parts:

| Part | File | Does |
|---|---|---|
| Access | `lib/matrix/call_access.dart` | Finds the call server and gets the LiveKit address and token |
| Membership | `lib/matrix/call_membership.dart` | Writes, refreshes and empties this device's membership |
| Media | `CallMedia` in `lib/matrix/call_media.dart`, implemented by `lib/platform/livekit_media.dart` | Connects, sends the microphone, reports who is there, speaking and muted |

`CallMedia` is an interface so that `MatrixCalls` runs under test against an
in-memory one. `lib/platform/` is the directory the first design spec names
for native glue; this phase creates it.

**Joining, in order.** Each step undoes nothing that others can see until the
last:

1. Refuse an encrypted room.
2. Find the call server and get access.
3. Connect to LiveKit.
4. Write the membership.

A failure at 2 or 3 ends in "couldn't connect" with nothing written. A failure
at 4 disconnects.

**Leaving, in order.** Empty the membership, then disconnect. If the
membership cannot be emptied, the disconnect still happens and the membership
runs out at its `expires`.

**Quitting leaves.** Closing the window, SIGINT and SIGTERM each leave the
call first, waiting at most three seconds before the app ends anyway.

**Participants.** The people shown in a call are the room's call memberships
(`callOccupancy`, already used for the channel list). Speaking and muted come
from the LiveKit participant with the matching identity.

**Mute and deafen.** Mute stops the microphone track being sent. Deafen stops
every remote audio track being played, and mutes.

**Where it is switched on.** `MatrixRooms` claims `RoomAbility.calls` when
it is given a `CallMedia`, and `main.dart` gives it one on Linux. On other
platforms a voice channel still reads "voice chat isn't available yet".

## Platform and build

- **Linux.** `flutter build linux` fetches libwebrtc during CMake configure
  and puts `libwebrtc.so` in the bundle's `lib/`. A build with no network
  needs the zip placed at the path under Findings first.
- **macOS, iOS, Windows.** Adding the dependency makes these builds link
  WebRTC too (a Swift package binary on Apple platforms, a downloaded DLL on
  Windows). Calls stay off there.
- **Flatpak** already has `--socket=pulseaudio` and `--device=all`.

## Testing

- `call_access.dart`, `call_membership.dart` and `MatrixCalls` are tested
  against the fake homeserver, a fake call server and the in-memory
  `CallMedia`.
- The in-memory `CallMedia` is a call server several clients can connect to,
  so a test with two `MatrixCalls` sees each through the other.
- `lib/platform/livekit_media.dart` has no automated test: it is a thin
  mapping onto a native library, and is checked by hand against a Cinny user.
- The call UI's tests keep running on the mock, unchanged.

## Known limitations

- **Ghosts.** A client that dies without emptying its membership stays listed
  until `expires`. Element Call leans on delayed events to clear these, and
  the homeserver has none. Loaf Chat leaves when it is quit, and empties a
  membership its own device left behind (a crash, a kill, the power going)
  when it next launches.
- **One SFU.** Members who publish to a different call server are listed but
  not heard.
- **No reconnect UI beyond LiveKit's own.** A dropped connection shows
  "reconnecting…" while LiveKit retries, then "couldn't connect".

## Build order

1. `Calls` extracted from `CallController`. A refactor: every existing test
   passes unchanged.
2. Joining a voice channel, all of the above in one commit.
