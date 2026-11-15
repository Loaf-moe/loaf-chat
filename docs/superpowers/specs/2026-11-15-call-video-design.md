# Loaf Chat — Video in calls

Loaf Chat joins a voice channel's call with sound only. This spec adds the
camera, on Linux: yours sent, everyone else's seen, and other people's
screen shares seen. The call UI already has the button, the menu and the
tiles (`2026-09-24-calls-design.md`); voice is what is behind them so far
(`2026-10-11-voice-design.md`). This is what goes behind the camera.

## Scope

**In:**

- Turning your camera on and off in a voice channel's call.
- Seeing the cameras of everyone else in it, whichever client they use.
- Seeing someone else's screen share.
- Choosing which camera.
- Linux.

**Out:**

| Deferred                                  | Why                                                                       |
| ----------------------------------------- | ------------------------------------------------------------------------- |
| Sharing your own screen                   | Capturing a screen under Wayland goes through the portal; its own spec    |
| macOS, Windows, iOS                       | Each needs its camera permission and a check by hand                      |
| Calls in encrypted rooms                  | As for voice: still refused                                               |
| Seeing your camera in the lobby           | The lobby's toggle chooses how you join; the picture starts when you do   |
| Encoding and decoding on the graphics card | See "Software video" below                                               |
| DM calls and ringing                      | Roadmap phase 8                                                           |

## Findings (checked 2026-11-15)

Sources: the Element Call fork at `28da7a19` (`src/livekit/options.ts`),
`livekit_client` 2.13.1, `flutter_webrtc` 1.6.2+hotfix.4, and the motion
budget spec (`2026-11-02-motion-budget-design.md`).

**The other end**

- Element Call sends its camera as VP8 at 720p, with two smaller copies
  beside it at 180p and 360p (simulcast). The media server chooses which
  copy each viewer gets.
- It turns on LiveKit's `adaptiveStream` and `dynacast`. With the first, a
  viewer tells the server how large each picture is drawn, and whether it
  is drawn at all, and is sent the copy that fits or nothing. With the
  second, a sender stops encoding copies nobody is being sent.
- `m.call.intent` in the membership says what kind of call it is, for a
  client that presents the two differently. It does not follow the camera.
  Loaf Chat's stays `audio`.

**The media library**

- `flutter_webrtc`'s Linux plugin opens cameras and draws video, both
  through code it shares with Windows (`common/cpp`).
- It draws through a pixel-buffer texture: each frame is copied in memory
  and handed to Flutter, not passed as a texture the graphics card already
  holds.
- The bundled libwebrtc encodes and decodes on the processor (voice spec,
  Findings).
- `livekit_client` has a widget, `VideoTrackRenderer`, that draws one
  track into whatever box it is given, and is what reports the box's size
  and visibility for `adaptiveStream`. It draws nothing else: no border,
  no controls.
- `Hardware.instance.videoInputs()` lists cameras, and
  `LocalParticipant.setCameraEnabled` opens and sends one.

**Drawing**

- Every frame Flutter draws on Linux redraws the whole window, and under
  X11 passes through the processor again on its way to the screen (motion
  budget spec). A picture at thirty frames a second is thirty such frames,
  whatever the codec costs.

## What you see

Nothing in the call's layout changes. The camera button, its ⌄ menu, the
tiles, the grid and the spotlight are as the calls spec has them; the
placeholder a tile draws for a camera or a screen is where the picture goes.

- **Your camera.** The button turns it on and off. Your own tile shows it
  mirrored.
- **Theirs.** A tile shows its person's camera while they send one.
- **A screen share.** A tile shows its person's screen while they share
  one, in place of their camera, and takes the spotlight unless a tile is
  pinned. Of two shares the newest is spotlit.
- **Fit.** A camera fills its tile, cropped. A screen is shown whole, with
  bars where its shape differs from the tile's.
- **Someone on two devices.** One tile, as now. It shows the first of
  their devices that sends a camera, and the first that shares a screen.
- **Choosing a camera.** The ⌄ beside the camera button lists the
  machine's cameras under "system default", read again as it opens. The
  voice section in settings has the same list under the microphone and the
  speaker. The choice is kept in `voice.json` beside them, as the device's
  id and label. One made while the camera is on reopens it from the new
  device, and since the camera is closed and opened again, everyone else
  sees your tile go back to your avatar for a moment while it does. A
  camera chosen that the machine does not have is listed as "not
  connected" and the default is used.
- **A camera that does not open.** The camera is off, and the button shows
  as blocked, as the microphone's does. Clicking the blocked button tries
  the camera again. The block also lifts at the next choice or change of
  devices; turning it back on is then left to you.
- **Leaving turns it off.** A call that ends, however it ends, leaves the
  camera off. The next call starts without it unless the lobby's toggle
  was switched on first. The lobby's toggle cannot be switched while you
  are in another call: it would switch that call's camera.
- **Deafen** leaves pictures alone.
- **Moderator mute and deafen** leave the camera alone.

## Design

**Sending.** As Element Call does, so that every client is sent the same
kinds of picture: VP8, 720p, simulcast with 180p and 360p beside it, and
`dynacast` on. The camera is opened when it is first turned on and closed
when it is turned off, so its light goes out.

**Receiving.** `adaptiveStream` on. A tile off screen (scrolled out of the
filmstrip, or the call not on screen at all) is sent nothing; a small tile
is sent a small copy. This is what keeps a full grid affordable without
the graphics card.

**Only what is visible plays.** A picture is drawn, and asked of the
server, only while its tile is on screen. A tile scrolled out of the
filmstrip, a call you are not looking at (the connected-call bar only) and
a minimised window draw none and are sent none. A window that is open but
not focused keeps playing: Linux does not say whether such a window can be
seen (motion budget spec, "Unfocused is not hidden"), and a call left open
beside other work is the usual case.

**The media interface** (`lib/matrix/call_media.dart`). `CallPeer` gains
`camera` and `screen`: whether that device sends each. `CallConnection`
gains:

| Member                                   | Does                                                                              |
| ---------------------------------------- | --------------------------------------------------------------------------------- |
| `setCamera(bool on)`                     | Starts or stops sending the camera. Throws `CameraUnavailable` when none opens    |
| `setCameraDevice(String? id)`            | Takes the camera from this device from now on; reopens one being sent             |
| `camera`                                 | The device the camera is open from, as `microphone` has it                        |
| `video(String? identity, {bool screen})` | A widget drawing that device's camera or screen; null identity is this device. Null when it sends none |

A widget crosses this interface because the library's own is what reports
size and visibility to the server; drawing the texture ourselves would
mean writing that again. The in-memory `CallMedia` returns a plain box.

**LiveKit** (`lib/platform/livekit_media.dart`). Still the one file that
touches `livekit_client`. It sets the room's options as above, implements
the four members, and lists cameras through `videoInputs()`. The camera is
published when it is turned on and unpublished when it is turned off,
which is also how a change of camera is made; `VideoTrackRenderer` draws
the pictures.

**Devices.** `AudioDevices` gains `cameras()`, and `VoiceSettings` a
`camera` beside `microphone` and `speaker`. The names stay: a rename to
fit a third kind of device is not worth the diff.

**The call's interface** (`lib/ui/call/calls.dart`). `Calls` gains
`video(String memberId, {bool screen})`, a widget or null. `CallController`
(the mock) returns null, and a tile with no widget draws the placeholder it
draws now, so the mock and its tests are as they were. `cameraDevice` and
`setCameraDevice` go: the choice lives in the voice settings, as the
microphone's does, and the ⌄ menu reads and writes it there in place of
`mockCameras`.

**The real one** (`lib/matrix/matrix_calls.dart`).

- Claims `CallFeature.camera` and `CallFeature.cameraDevices` when it is
  told video is on, which `main.dart` does where `hasCallVideo` says so:
  Linux.
- `toggleCamera` flips its own flag and brings the connection in line, in
  the same queue that applies mute and deafen, so the two never overlap. A
  `CameraUnavailable` turns the flag off and sets `cameraBlocked`.
- A participant's `camera` is true when any of their devices sends one,
  and `screen` likewise.
- `spotlight` is the pinned tile, else whoever most recently began sharing
  a screen.
- Ending a call clears the flag.

**The tile** (`lib/ui/call/call_tile.dart`). Takes the widget from
`Calls.video` for its person and draws it under the name chip where the
placeholder is: the screen's when they share one, else the camera's.

**Flatpak** already has `--device=all`, which covers cameras.

## Software video

Everything here runs on the processor: encoding your camera, decoding
everyone else's, and copying each frame to Flutter. Nothing in this design
depends on that. Which codec runs where is libwebrtc's business and how a
frame reaches Flutter is the plugin's, both below `livekit_client`; a
libwebrtc built with hardware codecs, or a plugin that hands over
textures, would slot in under the same Dart.

## Testing

- `MatrixCalls` against the in-memory `CallMedia`: the camera turning on
  and off reaches the connection; a peer's camera and screen show on their
  participant, from any of their devices; the newest share is spotlit and
  a pin overrides it; a camera that does not open ends off and blocked,
  and the block lifts on a change of devices; a call that ends leaves the
  camera off; a camera chosen in the settings reaches the connection;
  no feature is claimed where video is off.
- The tile: draws the widget it is given, and the placeholder without one.
- The ⌄ menu and the voice section: list what the machine has, mark the
  one chosen, and "not connected" for one that is gone.
- `lib/platform/livekit_media.dart` has no automated test, as before.

**By hand on loaf.moe**, against someone on Cinny: each sees the other's
camera; a share from Cinny shows and takes the spotlight; changing camera
mid-call; unplugging the camera in use; a grid of several cameras, and
its processor use under both X11 and Wayland.

## Known limitations

- **Processor use grows with the window.** Each frame of video redraws the
  whole window, and under X11 copies it through the processor.
- **Two identical cameras** cannot be told apart if Linux gives them the
  same id, as with microphones.
- **One tile per person.** A second device's camera is not shown while the
  first sends one.
- **Linux does not say when a camera comes or goes.** WebRTC's Linux
  plugin raises a change of devices for microphones and speakers only. A
  blocked camera's block lifts when its button is clicked, when another
  camera is chosen, or when the call ends; plugging one in does not lift
  it, and the settings list a newly plugged camera only when next opened. A camera unplugged, or held
  by another program, while it is being sent may go on showing as on with
  no picture.

## Order

1. Camera on and off through `MatrixCalls`, with seeing everyone else's
   and their screen shares.
2. Choosing a camera, in the menu and the settings.
