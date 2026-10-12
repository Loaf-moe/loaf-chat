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
- Choosing the microphone and the speaker.
- Switching the microphone's echo cancellation, noise suppression,
  automatic gain and high-pass filter.
- Turning one person up or down.
- Linux and macOS desktop, and iOS.

**Out:**

| Deferred                                                | Why                                                                                                          |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Calls in encrypted rooms                                | Element Call encrypts media per participant there; a client without those keys can neither hear nor be heard |
| Camera and screen sharing                               | The Linux libwebrtc build encodes and decodes in software only; needs its own research                       |
| DM calls and ringing                                    | Roadmap phase 8                                                                                              |
| Windows, Android                                        | Each needs microphone permissions and its own check by hand                                                  |
| Calls whose members publish to another homeserver's SFU | loaf.moe has one SFU                                                                                         |
| Element Call's `matrix_2_0` mode                        | Needs sticky events (MSC4354), which the homeserver does not have                                            |

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

| Part       | File                                                                                          | Does                                                                     |
| ---------- | --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| Access     | `lib/matrix/call_access.dart`                                                                 | Finds the call server and gets the LiveKit address and token             |
| Membership | `lib/matrix/call_membership.dart`                                                             | Writes, refreshes and empties this device's membership                   |
| Media      | `CallMedia` in `lib/matrix/call_media.dart`, implemented by `lib/platform/livekit_media.dart` | Connects, sends the microphone, reports who is there, speaking and muted |

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

**Membership lifetime.** Loaf Chat's own membership lasts ten minutes and is
written again every five, so a device that dies without leaving is listed for
ten minutes at most. Each refresh sets `expires` to the time since the
membership began plus ten minutes. Element Call's rule adds a whole expiry per
refresh, which runs further ahead of the clock each time; its four-hour
memberships on loaf.moe reach sixteen and thirty-two hours that way. If the
homeserver takes no writes for more than five minutes, the membership lapses
and other clients stop listing this device until a write succeeds; a failed
refresh is tried again every fifteen seconds.

**Quitting leaves.** Closing the window, SIGINT and SIGTERM each leave the
call first, waiting at most three seconds before the app ends anyway.

**Participants.** The people shown in a call are the room's call memberships
(`callOccupancy`, already used for the channel list). Speaking and muted come
from the LiveKit participant with the matching identity.

**Mute and deafen.** Mute stops the microphone track being sent. Deafen stops
every remote audio track being played, and mutes.

**Sounds.** Going live in a call plays Element Call's join sound, and a live
call ending plays its leave sound. While live, the number of other people
rising or falling plays the same two. As in Element Call, nothing plays for a
change in a call of more than eight people, and the same sound plays at most
once in half a second. The app's one sound switch silences them. The files and
their licences are listed in `assets/SOURCES.md`.

**Connection.** A call that has gone live carries one small mark of signal
bars: after the channel's name in the call's top bar, and at the start of the
bar that follows you to other channels, in place of that bar's own icon. Full
bars are a good link (muted in the top bar, green on the bar); low bars in
amber a weak one; no bars in red one barely there; no bars in amber
reconnecting. The rating is LiveKit's own for this device. Hovering, or
tapping on a phone, says which.

**Devices.** Settings has a voice section listing the machine's microphones
and speakers, each under a "system default" entry. The choice is kept in
`voice.json` in the app's support directory, as the device's id and label. A
call opens the chosen microphone and plays on the chosen speaker, and a
choice made during a call is applied at once: an unmuted microphone is
reopened from the new device, a muted one when it is next unmuted. A chosen
device the machine does not have is listed as "not connected" and the call
uses the system default until it is back. The list is read again whenever
the section opens and, once it has been opened, whenever WebRTC reports a
change.

On desktop the call's own controls offer the same choice: a ⌄ beside the
microphone button lists the microphones and one beside deafen the speakers,
each read again as its menu opens.

A live call applies the choice again whenever WebRTC reports a change, so a
device that goes away mid-call gives way to the system default and one that
comes back is taken up. A speaker that cannot be set is logged and the call
plays on where it did. A microphone that does not open mutes you and shows
as blocked; the block lifts at the next choice or change of devices, and
unmuting is left to you.

On Linux a device's id is its name, so two identical devices cannot be told
apart, and a device the system renames reads as not connected. WebRTC lists
the system default there a second time as `default: <name>`; that entry is
left out of the list and is what "system default" opens.

On macOS the lists do not come from WebRTC. Its own has nothing but the
default until a call starts, and during one the echo canceller taps every
output, which makes each speaker an input as far as WebRTC can tell: a DAC
shows up as a microphone, and a USB microphone's headphone jack as a second
microphone of the same name. The Mac app lists its own from CoreAudio
(`AudioDevicesBridge.swift`, over `loaf/audio`). A microphone is a device
with an input stream whose terminal is not a speaker's or a headphone's: the
tap keeps the terminal of the output it is on. A speaker is a device with an
output stream. Aggregate devices are left out of both, a call's own among
them. A display's speakers (DisplayPort, HDMI) are left out too: WebRTC does
not list them, and told to play through one it never finishes starting,
after which every call into it waits for good. A device's id is its
CoreAudio UID in these lists and in WebRTC's, so what is chosen from one
opens in the other.

Changing the speaker goes through the same bridge on macOS. WebRTC rebuilds
its audio engine before it answers, which takes seconds, and the plugin
waits for that on the main thread, where Dart runs too: the app stopped and
the call's signalling with it. The bridge asks from a queue of its own, and
lists the devices from it as well.

While a call takes up what is chosen, it says so (`Calls.switchingAudio`):
the call's status reads "switching audio…", and in the voice section the
row chosen shows a spinner where its check goes. The microphone and the
speaker are taken up together, so both rows show it whichever was changed.

**Processing.** The voice section has a switch each for echo cancellation,
noise suppression, automatic gain and the high-pass filter, kept in
`voice.json` with the devices. The first three start on and the filter off,
as `livekit_client` has them. They are WebRTC's own software processing. On
Linux they take effect only when a microphone is opened, so a switch made
during a call reopens the microphone as a change of device does: at once
when unmuted, at the next unmute when muted. `livekit_client` also asks for
typing-noise detection and voice isolation; the Linux plugin reads neither.

**Volume.** Someone's tile, and their row under a voice channel in the
channel list (a right-click, or a long press on a phone), offer a slider
from nothing to twice as loud as they are sent. The number is kept by user id in `voice.json`, so it holds
across calls and launches, and applies to every device that person is in
the call on, including one that joins later. `livekit_client` has no call
for it; the call goes to `flutter_webrtc`'s per-track volume, which is why
that package is a dependency of its own.

**In the channel list.** Under the voice channel whose call you are in,
once it is connected, each person's avatar rings green while they are heard,
a struck microphone sits beside anyone muted, and struck headphones beside
you when deafened. Nobody else's deafening is known: neither LiveKit nor the
membership event says. For a call this device is not connected to, only who
is in it is known, so those rows show names alone.

**Kicking.** The same row menu offers "kick from <channel>" where your
power level in that room reaches what a kick takes and the other person's is
below yours. It asks first, then kicks them from the room: a Matrix kick,
not a ban, so they may join again where the room's rules let them. They
drop off the channel's list at once, since being listed takes being in the
room, and Loaf Chat on their side leaves the call when it loses the room.

**Moderator mute and deafen.** The media server cannot be told to silence
anyone from a client: that goes through LiveKit's server API, which takes
the server's secret, and the call server only hands out tokens to join. So
this is honoured, not enforced. A moderator writes a state event in the
voice room and each Loaf Chat reads the entry about its own user and
silences itself:

```
type:      moe.loaf.call.moderation
state_key: _<user id>
content:   {"muted": true, "deafened": false}
```

`deafened` deafens and mutes; otherwise `muted` mutes; an emptied entry
lifts it. The key is not the bare user id because a state key that begins
with `@` may only be written by that user. Who may write it is the room's
own power levels (`events` for this type, else `state_default`), which the
homeserver checks; an entry binds its user whatever their level. A room
with no power-levels event lets anyone write state, and so anyone silence
anyone.

While an entry stands the person's microphone (and, deafened, their sound)
is off whatever they chose, the matching control is locked and says a
moderator did it, and lifting it returns them to their own choice. A toast
tells them when it is put on or lifted during a call. It shows
to everyone: on the person's row under the voice channel, in red, whether or
not you are in that call, and on their tile. The row menu offers "mute for
everyone" and "deafen for everyone", or their undoing, where the room lets
you write the entry. It stays until lifted, outlasting the call.

A client that does not read the entry (Element Call, anything modified) is
not bound by it; kicking is what binds everyone. Emptying someone's call
membership is no substitute: it takes them off lists only, their media
stays connected, and their client writes the membership back.

**Where it is switched on.** `MatrixRooms` claims `RoomAbility.calls` when
it is given a `CallMedia`, and `main.dart` gives it one where `hasCalls`
says so: Linux, macOS and iOS. On other platforms a voice channel still reads
"voice chat isn't available yet".

## Platform and build

- **Linux.** `flutter build linux` fetches libwebrtc during CMake configure
  and puts `libwebrtc.so` in the bundle's `lib/`. A build with no network
  needs the zip placed at the path under Findings first. The app starts
  WebRTC itself (`LiveKitClient.initialize`) before first use: left to
  start by itself, `flutter_webrtc` asks libwebrtc for a log level, and
  libwebrtc logs to stderr once asked for any.
- **macOS.** WebRTC comes as a Swift package binary. The app is sandboxed,
  and its release is signed for the hardened runtime; both refuse the
  microphone without the `com.apple.security.device.audio-input`
  entitlement, so both entitlements files carry it.
- **iOS.** WebRTC comes as a Swift package binary. The system routes sound
  there, from Control Center, so the voice section has no microphone or
  speaker to choose (`picksAudioDevices`) and the call follows the route.
  Checked in the simulator only so far. A call and an inline video share
  one audio session there. `loaf_media` sets it to playback while a video
  plays with its sound on and deactivates it when the video stops, either
  of which would take the call's sound; so the app tells it when a call has
  the session (`CallAudioHold`, `LoafMedia.callHoldsAudio`), and until the
  call is over a video leaves the session as the call set it. A video still
  making sound when the call ends takes the session back.
- **Windows.** Adding the dependency makes this build link WebRTC too (a
  downloaded DLL). Calls stay off there: `hasCalls` in
  `lib/ui/platform.dart` names where they are on.
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
  the homeserver has none. Loaf Chat leaves when it is quit, empties a
  membership its own device left behind (a crash, a kill, the power going)
  when it next launches, and writes memberships that run out in ten minutes
  either way.
- **One SFU.** Members who publish to a different call server are listed but
  not heard.
- **Device loss is unchecked by hand.** Moving playback to another speaker
  while someone is talking, and what WebRTC does on Linux when a device in
  use goes away (whether it reports the change at all), are written from
  `livekit_client` and `flutter_webrtc` source.
- **No reconnect UI beyond LiveKit's own.** A dropped connection shows
  "reconnecting…" while LiveKit retries, then "couldn't connect".

## Build order

1. `Calls` extracted from `CallController`. A refactor: every existing test
   passes unchanged.
2. Joining a voice channel, all of the above in one commit.
