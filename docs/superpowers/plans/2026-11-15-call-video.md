# Video in Calls (Linux) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In a voice channel's call on Linux, your camera can be sent, everyone else's cameras and screen shares are seen, and the camera can be chosen.

**Architecture:** The call UI and its `Calls` interface already model the camera; `MatrixCalls` stubs it. The media interface (`CallConnection`) gains camera on/off, camera choice, per-peer `camera`/`screen` flags and a method returning a video widget. `livekit_media.dart` implements those over `livekit_client` (its `VideoTrackRenderer`, with `adaptiveStream` and `dynacast` on); `MatrixCalls` drives them; the tile draws the widget where its placeholder is. The camera choice lives in `VoiceSettings` beside the microphone and the speaker.

**Tech Stack:** Flutter 3.47.5 (via mise), `livekit_client` 2.13.1, `flutter_webrtc` (the Loaf-moe fork pinned in `pubspec.yaml`), `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-11-15-call-video-design.md`. Read it, and `docs/superpowers/specs/2026-10-11-voice-design.md` for how voice is built.

## Global Constraints

- Camera is claimed on **Linux only** (`hasCallVideo`). macOS, Windows, iOS and Android stay voice-only.
- `lib/platform/livekit_media.dart` stays the **one file that imports `livekit_client`**.
- No new dependencies.
- Sending: **VP8, 720p, simulcast with 180p and 360p, `dynacast` on**. Receiving: **`adaptiveStream` on**.
- `m.call.intent` stays `audio`. Encrypted rooms stay refused.
- The names `AudioDevice`, `AudioDevices`, `VoiceSettings`, `VoiceController` and `voice.json` stay, though they now cover cameras.
- A call that ends leaves the camera off.
- Comments follow the codebase: short, plain, saying why. No comment restating the code.
- Before each commit: `mise run check` passes (analyze, and `dart format` clean). Format with `mise run format`.
- Tests run with `flutter test <path>`; the whole suite with `mise run test`.
- Work on the branch `feat/call-video`.

## File Structure

| File | Change |
| --- | --- |
| `lib/ui/platform.dart` | `hasCallVideo` |
| `lib/ui/settings/voice_settings.dart` | `VoiceSettings.camera`, `AudioDevices.cameras()`, `VoiceController.cameras` / `camera` / `chooseCamera` |
| `lib/ui/mock/mock_audio_devices.dart` | `mockCameraDevices`, `MemoryAudioDevices(cameras:)` |
| `lib/platform/system_audio_devices.dart` | `cameras()` answering none |
| `lib/ui/settings/voice_section.dart` | Camera rows where `hasCallVideo` |
| `lib/matrix/call_media.dart` | `CallPeer.camera` / `.screen`, `CameraUnavailable`, four `CallConnection` members |
| `lib/platform/livekit_media.dart` | Room options, camera, video widget, cameras list, minimised window |
| `test/matrix/in_memory_call_media.dart` | The fake's camera, screen and video |
| `lib/ui/call/calls.dart` | `Calls.video`; `cameraDevice` and `setCameraDevice` removed |
| `lib/ui/call/call_controller.dart`, `test/voice_only_calls.dart` | Follow the interface |
| `lib/ui/call/call_tile.dart`, `lib/ui/call/call_view.dart` | The tile draws the widget |
| `lib/ui/call/call_controls.dart` | The camera ⌄ menu reads the voice settings |
| `lib/matrix/matrix_calls.dart`, `lib/matrix/matrix_rooms.dart`, `lib/main.dart` | The camera for real, switched on for Linux |

---

### Task 1: The camera in voice settings

**Files:**
- Modify: `lib/ui/platform.dart`
- Modify: `lib/ui/settings/voice_settings.dart`
- Modify: `lib/ui/mock/mock_audio_devices.dart`
- Modify: `lib/platform/system_audio_devices.dart`
- Modify: `lib/platform/livekit_media.dart` (`LiveKitAudioDevices` only)
- Modify: `lib/ui/settings/voice_section.dart`
- Test: `test/platform_test.dart`, `test/voice_settings_test.dart`, `test/voice_section_test.dart`
- Modify (fakes that implement `AudioDevices`): `test/voice_settings_test.dart`, `test/call_controls_devices_test.dart`

**Interfaces:**
- Produces:
  - `bool get hasCallVideo` in `lib/ui/platform.dart`
  - `VoiceSettings({AudioDevice? camera, ...})`, `VoiceSettings.camera`, `copyWith(camera: AudioDevice? Function()?)`, JSON key `'camera'`
  - `Future<List<AudioDevice>> AudioDevices.cameras()`
  - `VoiceController.cameras` (`List<AudioDevice>`), `VoiceController.camera` (`AudioDevice?`), `VoiceController.chooseCamera(AudioDevice? device)`
  - `const mockCameraDevices` and `MemoryAudioDevices({List<AudioDevice> Function()? cameras, ...})`

- [ ] **Step 1: Write the failing tests**

In `test/platform_test.dart`, add (import `package:flutter/foundation.dart` and `package:loaf_native/ui/platform.dart` if the file lacks them):

```dart
  test('only Linux has video in calls', () {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    for (final platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      expect(hasCallVideo, platform == TargetPlatform.linux, reason: '$platform');
    }
  });
```

In `test/voice_settings_test.dart`, add inside `main()` (import `dart:convert` and `package:loaf_native/ui/mock/mock_audio_devices.dart` if the file lacks them):

```dart
  group('the camera', () {
    const cam = AudioDevice('c920', 'HD Pro Webcam C920');

    test('is kept beside the microphone and the speaker', () {
      const settings = VoiceSettings(microphone: _rode, camera: cam);

      final read = VoiceSettings.fromJson(
        jsonDecode(jsonEncode(settings.toJson())),
      );

      expect(read.camera, cam);
      expect(read, settings);
    });

    test('alone makes two settings differ', () {
      expect(
        const VoiceSettings(camera: cam),
        isNot(const VoiceSettings()),
      );
    });

    test('is chosen, and given back to the system default', () {
      final controller = VoiceController(
        store: MemoryStore<VoiceSettings>(),
        devices: MemoryAudioDevices(),
      );
      addTearDown(controller.dispose);

      controller.chooseCamera(cam);
      expect(controller.camera, cam);
      expect(controller.settings.value.camera, cam);

      controller.chooseCamera(null);
      expect(controller.camera, isNull);
    });

    test('is among what the machine is asked for', () async {
      final controller = VoiceController(
        store: MemoryStore<VoiceSettings>(),
        devices: MemoryAudioDevices(cameras: () => const [cam]),
      );
      addTearDown(controller.dispose);

      await controller.refresh();

      expect(controller.cameras, [cam]);
    });
  });
```

In `test/voice_section_test.dart`, give `_pump` a `cameras` parameter and pass it on:

```dart
const _cam = AudioDevice('c920', 'HD Pro Webcam C920');
```

```dart
  List<AudioDevice> Function()? cameras,
```

```dart
    devices: MemoryAudioDevices(
      microphones: microphones ?? () => const [_rode, _sony],
      speakers: speakers ?? () => const [_desk],
      cameras: cameras ?? () => const [_cam],
      changes: changes,
    ),
```

and add inside `main()` (import `package:flutter/foundation.dart` if the file lacks it):

```dart
  const linux = TargetPlatformVariant({TargetPlatform.linux});

  testWidgets('on Linux, lists the cameras under the speakers', variant: linux, (
    tester,
  ) async {
    await _pump(tester);

    expect(_titles(tester), [
      'system default',
      'RODE NT-USB',
      'WH-1000XM3',
      'system default',
      'Desk Speakers',
      'system default',
      'HD Pro Webcam C920',
    ]);
  });

  testWidgets('tapping a camera chooses it', variant: linux, (tester) async {
    final controller = await _pump(tester);

    await tester.tap(find.text('HD Pro Webcam C920'));
    await tester.pumpAndSettle();

    expect(controller.camera, _cam);
  });
```

The existing test `lists the system default and every device, for each` runs on the default test platform, which is not Linux, and still expects five rows: it is the check that other platforms list no cameras. Leave it as it is.

- [ ] **Step 2: Run them to see them fail**

Run: `flutter test test/platform_test.dart test/voice_settings_test.dart test/voice_section_test.dart`
Expected: compile errors — `hasCallVideo`, `camera`, `chooseCamera`, `cameras` are not defined.

- [ ] **Step 3: `hasCallVideo`**

Append to `lib/ui/platform.dart`:

```dart
/// Whether a call has cameras and shows screen shares. Each platform needs
/// its camera permission and a check by hand before it joins Linux here;
/// see "Scope" in the call video design spec.
bool get hasCallVideo => defaultTargetPlatform == TargetPlatform.linux;
```

- [ ] **Step 4: `VoiceSettings.camera`**

In `lib/ui/settings/voice_settings.dart`:

Change the file's first doc line and `AudioDevice`'s to cover cameras:

```dart
/// Which microphone, speaker and camera a call uses, what is done to the
/// microphone's sound, and how loud each person is played.
```

```dart
/// A microphone, a speaker or a camera, as the system names it.
```

In `VoiceSettings`: add the constructor parameter `this.camera,` after `this.speaker,`; in `fromJson` add after the speaker line:

```dart
      camera: AudioDevice.fromJson(json['camera']),
```

add the field after `speaker`:

```dart
  final AudioDevice? camera;
```

in `copyWith` add the parameter `AudioDevice? Function()? camera,` after `speaker`, and the argument:

```dart
    camera: camera == null ? this.camera : camera(),
```

in `toJson` add after the speaker line:

```dart
    'camera': ?camera?.toJson(),
```

in `operator ==` add `other.camera == camera &&` after the speaker line, and in `hashCode` add `camera,` after `speaker,`.

- [ ] **Step 5: `AudioDevices.cameras()` and the controller**

In the same file, `AudioDevices` becomes:

```dart
/// The machine's microphones, speakers and cameras.
abstract interface class AudioDevices {
  Future<List<AudioDevice>> microphones();

  Future<List<AudioDevice>> speakers();

  Future<List<AudioDevice>> cameras();

  /// An event whenever a device may have come or gone.
  Stream<void> get changes;
}
```

In `VoiceController`, add under `speakers`:

```dart
  List<AudioDevice> cameras = const [];
```

add under the `speaker` getter:

```dart
  AudioDevice? get camera => settings.value.camera;
```

replace the body of `refresh` from `final (ins, outs)` to `speakers = outs;` with:

```dart
    final (ins, outs, seen) = await (
      _devices.microphones(),
      _devices.speakers(),
      _devices.cameras(),
    ).wait;
    // Overtaken: a later asking has the newer answer.
    if (asked != _asked) return;
    microphones = ins;
    speakers = outs;
    cameras = seen;
```

and add under `chooseSpeaker`:

```dart
  void chooseCamera(AudioDevice? device) =>
      _update(settings.value.copyWith(camera: () => device));
```

- [ ] **Step 6: Everything that implements `AudioDevices`**

`lib/ui/mock/mock_audio_devices.dart` — add the list, the parameter and the method:

```dart
const mockCameraDevices = [
  AudioDevice('facetime', 'FaceTime HD Camera'),
  AudioDevice('continuity', 'Continuity Camera'),
];
```

```dart
class MemoryAudioDevices implements AudioDevices {
  MemoryAudioDevices({
    List<AudioDevice> Function()? microphones,
    List<AudioDevice> Function()? speakers,
    List<AudioDevice> Function()? cameras,
    this.changes = const Stream.empty(),
  }) : _microphones = microphones ?? (() => mockMicrophones),
       _speakers = speakers ?? (() => mockSpeakers),
       _cameras = cameras ?? (() => mockCameraDevices);

  final List<AudioDevice> Function() _microphones;
  final List<AudioDevice> Function() _speakers;
  final List<AudioDevice> Function() _cameras;
```

```dart
  @override
  Future<List<AudioDevice>> cameras() async => _cameras();
```

`lib/platform/system_audio_devices.dart` — add to `SystemAudioDevices`:

```dart
  /// None: the Mac has no video in calls yet.
  @override
  Future<List<AudioDevice>> cameras() async => const [];
```

`lib/platform/livekit_media.dart` — add to `LiveKitAudioDevices`:

```dart
  @override
  Future<List<AudioDevice>> cameras() =>
      _listed(() => Hardware.instance.videoInputs());
```

`test/voice_settings_test.dart` and `test/call_controls_devices_test.dart` — each has a `_Slow implements AudioDevices`; add to both:

```dart
  @override
  Future<List<AudioDevice>> cameras() async => const [];
```

- [ ] **Step 7: The settings section**

In `lib/ui/settings/voice_section.dart`, change the file's doc comment to:

```dart
/// Settings, voice: which microphone, speaker and camera calls use, and
/// what is done to the microphone's sound.
```

and add, directly after the speaker's `const SizedBox(height: LoafSpace.x4),` and still inside `if (picksAudioDevices) ...[`:

```dart
            if (hasCallVideo) ...[
              const SettingsLabel(label: 'camera'),
              ..._choices(
                controller.cameras,
                settings.camera,
                controller.chooseCamera,
              ),
              const SizedBox(height: LoafSpace.x4),
            ],
```

- [ ] **Step 8: Run the tests**

Run: `flutter test test/platform_test.dart test/voice_settings_test.dart test/voice_section_test.dart test/call_controls_devices_test.dart`
Expected: all pass.

- [ ] **Step 9: Check and commit**

Run: `mise run format && mise run check`
Expected: no issues.

```bash
git add -A
git commit -m "feat(voice): a camera among the devices chosen"
```

---

### Task 2: The media interface, its fake, and LiveKit

**Files:**
- Modify: `lib/matrix/call_media.dart`
- Modify: `lib/platform/livekit_media.dart`
- Modify: `test/matrix/in_memory_call_media.dart`
- Modify: `test/matrix/matrix_calls_test.dart` (`_LoggedConnection` only)
- Create: `test/matrix/in_memory_call_media_test.dart`

**Interfaces:**
- Produces, in `lib/matrix/call_media.dart`:
  - `CallPeer({required bool muted, required bool speaking, bool camera = false, bool screen = false})`
  - `class CameraUnavailable implements Exception { const CameraUnavailable(this.detail); final String detail; }`
  - On `CallConnection`:
    - `Future<void> setCamera(bool on)` — throws `CameraUnavailable`
    - `Future<void> setCameraDevice(String? id)` — throws `CameraUnavailable`
    - `String? get camera` — the device the camera is taken from; null is the system's default
    - `Widget? video(String? identity, {bool screen = false})` — null identity is this device
- Produces, in `test/matrix/in_memory_call_media.dart`:
  - `InMemoryCallMedia(server, {bool camera = true, ...})`
  - `void shareScreen(CallConnection connection, {required bool on})`
  - `video()` returns `SizedBox.shrink(key: ValueKey('video-<identity>-<camera|screen>'))`

- [ ] **Step 1: Write the failing test of the fake**

Create `test/matrix/in_memory_call_media_test.dart`:

```dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/matrix/call_media.dart';

import 'in_memory_call_media.dart';

final _url = Uri.parse('wss://sfu.example.com');

String _jwt(String identity) {
  final claims = base64Url.encode(
    utf8.encode(
      jsonEncode({
        'sub': identity,
        'video': {'room': '!oven'},
      }),
    ),
  );
  return 'head.$claims.signature';
}

void main() {
  late InMemoryCallServer server;
  setUp(() => server = InMemoryCallServer(_url));

  Future<CallConnection> join(String identity, {bool camera = true}) =>
      InMemoryCallMedia(server, camera: camera).connect(_url, _jwt(identity));

  test('a camera turned on is seen by everyone else', () async {
    final ada = await join('ada');
    final bea = await join('bea');

    await ada.setCamera(true);

    expect(bea.peers['ada']!.camera, isTrue);
    expect(bea.video('ada'), isNotNull);
    expect(ada.video(null), isNotNull);
  });

  test('a camera turned off is gone', () async {
    final ada = await join('ada');
    final bea = await join('bea');
    await ada.setCamera(true);

    await ada.setCamera(false);

    expect(bea.peers['ada']!.camera, isFalse);
    expect(bea.video('ada'), isNull);
  });

  test('a machine with no camera cannot turn one on', () async {
    final ada = await join('ada', camera: false);

    expect(() => ada.setCamera(true), throwsA(isA<CameraUnavailable>()));
  });

  test('a screen shared is seen, apart from the camera', () async {
    final ada = await join('ada');
    final bea = await join('bea');

    shareScreen(ada, on: true);

    expect(bea.peers['ada']!.screen, isTrue);
    expect(bea.video('ada', screen: true), isNotNull);
    expect(bea.video('ada'), isNull);
  });
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `flutter test test/matrix/in_memory_call_media_test.dart`
Expected: compile errors — `setCamera`, `video`, `shareScreen`, `CameraUnavailable` are not defined.

- [ ] **Step 3: The interface**

In `lib/matrix/call_media.dart`:

Change the file's doc comment and add the import:

```dart
/// A call's media, as [MatrixCalls] needs it: somewhere to connect, a
/// microphone and a camera to send, and who else is there.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Widget;
```

`CallPeer` becomes:

```dart
/// Someone else's device in the call.
@immutable
class CallPeer {
  const CallPeer({
    required this.muted,
    required this.speaking,
    this.camera = false,
    this.screen = false,
  });

  /// Sending no microphone.
  final bool muted;
  final bool speaking;

  /// Sending a camera.
  final bool camera;

  /// Sharing a screen.
  final bool screen;

  @override
  bool operator ==(Object other) =>
      other is CallPeer &&
      other.muted == muted &&
      other.speaking == speaking &&
      other.camera == camera &&
      other.screen == screen;

  @override
  int get hashCode => Object.hash(muted, speaking, camera, screen);
}
```

Add after `MicrophoneUnavailable`:

```dart
/// No camera could be opened.
class CameraUnavailable implements Exception {
  const CameraUnavailable(this.detail);

  final String detail;

  @override
  String toString() => 'CameraUnavailable: $detail';
}
```

Add to `CallConnection`, before `disconnect`:

```dart
  /// Starts or stops sending the camera. Throws [CameraUnavailable] when
  /// none opens.
  Future<void> setCamera(bool on);

  /// The device the camera is taken from, by its id. Null is the system's
  /// default.
  String? get camera;

  /// Takes the camera from the device with [id] from now on, or from the
  /// system's default: for null, and for a device the machine does not
  /// have as of this call. Throws [CameraUnavailable] when one being sent
  /// does not reopen; it is then no longer sent.
  Future<void> setCameraDevice(String? id);

  /// Draws the camera, or with [screen] the screen, that the device with
  /// [identity] sends, filling whatever box it is given; a null [identity]
  /// is this device. Null while that device sends none. While the widget
  /// is on screen the picture is asked of the server at the widget's size;
  /// off screen, not at all.
  Widget? video(String? identity, {bool screen = false});
```

- [ ] **Step 4: The fake**

In `test/matrix/in_memory_call_media.dart`:

Add the import:

```dart
import 'package:flutter/widgets.dart' show SizedBox, ValueKey, Widget;
```

Change `InMemoryCallMedia`'s doc comment, constructor and fields:

```dart
/// One device's way to an [InMemoryCallServer]: its [network], whether it
/// has a [microphone] and a [camera], and which devices it has by id.
class InMemoryCallMedia implements CallMedia {
  InMemoryCallMedia(
    this.server, {
    ValueListenable<CallLink>? network,
    ValueListenable<CallQuality>? quality,
    this.microphone = true,
    this.camera = true,
    this.present,
    this.broken = const {},
  }) : network = network ?? ValueNotifier(CallLink.connected),
       quality = quality ?? ValueNotifier(CallQuality.good);
```

```dart
  final bool microphone;
  final bool camera;
```

Add this top-level function under `InMemoryCallMedia`:

```dart
/// Has the device behind [connection] start or stop sharing its screen.
/// Only for a connection an [InMemoryCallMedia] made.
void shareScreen(CallConnection connection, {required bool on}) {
  final device = connection as _Connection;
  device._screen = on;
  device._media.server._changed(device._room);
}
```

In `_Connection`, add the state under `var _microphone = false;`:

```dart
  var _camera = false;
  var _screen = false;
```

add under the `speaker` field:

```dart
  @override
  String? camera;
```

replace `peers` with:

```dart
  @override
  Map<String, CallPeer> get peers => {
    for (final other in _others)
      other._identity: CallPeer(
        muted: !other._microphone,
        speaking: other._microphone,
        camera: other._camera,
        screen: other._screen,
      ),
  };

  Iterable<_Connection> get _others => [
    for (final other in _media.server._rooms[_room] ?? const <_Connection>[])
      if (!identical(other, this)) other,
  ];
```

and add before `disconnect`:

```dart
  @override
  Future<void> setCamera(bool on) async {
    if (on && (!_media.camera || _media.broken.contains(camera))) {
      throw CameraUnavailable("${camera ?? 'the default'} doesn't open");
    }
    _camera = on;
    _media.server._changed(_room);
  }

  @override
  Future<void> setCameraDevice(String? id) async {
    camera = _present(id);
    if (_camera && _media.broken.contains(camera)) {
      _camera = false;
      _media.server._changed(_room);
      throw CameraUnavailable("$camera doesn't open");
    }
  }

  @override
  Widget? video(String? identity, {bool screen = false}) {
    final device = identity == null
        ? this
        : _others.where((other) => other._identity == identity).firstOrNull;
    if (device == null || !(screen ? device._screen : device._camera)) {
      return null;
    }
    return SizedBox.shrink(
      key: ValueKey(
        'video-${device._identity}-${screen ? 'screen' : 'camera'}',
      ),
    );
  }
```

- [ ] **Step 5: The logging wrapper in the calls test**

In `test/matrix/matrix_calls_test.dart`, add to `_LoggedConnection` (import `package:flutter/widgets.dart` `show Widget` if the file lacks `Widget`):

```dart
  @override
  String? get camera => _inner.camera;
  @override
  Future<void> setCamera(bool on) => _inner.setCamera(on);
  @override
  Future<void> setCameraDevice(String? id) {
    _deviceSets.add('camera');
    return _inner.setCameraDevice(id);
  }

  @override
  Widget? video(String? identity, {bool screen = false}) =>
      _inner.video(identity, screen: screen);
```

- [ ] **Step 6: LiveKit**

In `lib/platform/livekit_media.dart`:

Change the file's doc comment and add imports:

```dart
/// A call's media and the machine's devices over LiveKit: the one file
/// that touches `livekit_client`.
library;

import 'dart:async';
```

```dart
// ConnectionState is LiveKit's here, not the widgets library's.
import 'package:flutter/widgets.dart' show AppLifecycleListener, ObjectKey, Widget;
```

Add under `_capture`:

```dart
/// As Element Call opens it.
const _camera = CameraCaptureOptions(params: VideoParametersPresets.h720_169);
```

In `LiveKitMedia.connect`, the room's options become:

```dart
      roomOptions: const RoomOptions(
        // As Element Call has them, so that either end hears and sees the
        // other the same way. Adaptive stream asks the server only for the
        // pictures on screen, at the size they are drawn; dynacast stops
        // encoding the sizes nobody is being sent.
        adaptiveStream: true,
        dynacast: true,
        defaultAudioPublishOptions: AudioPublishOptions(dtx: true, red: false),
        defaultAudioCaptureOptions: _capture,
        defaultCameraCaptureOptions: _camera,
        defaultVideoPublishOptions: VideoPublishOptions(
          videoCodec: 'vp8',
          videoEncoding: VideoEncoding(
            maxBitrate: 1700000,
            maxFramerate: 30,
          ),
          videoSimulcastLayers: [
            VideoParametersPresets.h180_169,
            VideoParametersPresets.h360_169,
          ],
          backupVideoCodec: BackupVideoCodec(enabled: false),
        ),
      ),
```

`VideoEncoding(maxBitrate: 1700000, maxFramerate: 30)` is what `VideoParametersPresets.h720_169.encoding` holds in 2.13.1; the preset's `encoding` is nullable, which is why it is written out.

In `_LiveKitConnection`:

The constructor becomes:

```dart
  _LiveKitConnection(this._room, this._selectSpeaker) {
    _room.addListener(notifyListeners);
    _lifecycle = AppLifecycleListener(
      onHide: () => unawaited(_watch(false)),
      onShow: () => unawaited(_watch(true)),
    );
    _events = _room.createListener()
      ..on<TrackSubscribedEvent>((event) async {
        final track = event.track;
        if (track is RemoteVideoTrack) {
          if (_hidden) await event.publication.disable();
          return;
        }
        if (track is! RemoteAudioTrack) return;
        final volume = _volumes[event.participant.identity];
        if (volume != null) await _play(track, volume);
        // Someone who starts talking while you are deafened stays unheard.
        if (_deafened) await track.disable();
      });
  }
```

Add fields under `var _deafened = false;`:

```dart
  /// A minimised window draws no frame, so no picture's widget is there to
  /// tell the server it went out of sight. This does.
  late final AppLifecycleListener _lifecycle;
  var _hidden = false;

  /// The camera chosen, and the one the camera is open from. Null: the
  /// system's default, and none open.
  String? _cameraChosen;
  String? _cameraOpened;
```

Replace `peers` with:

```dart
  @override
  Map<String, CallPeer> get peers => {
    for (final participant in _room.remoteParticipants.values)
      participant.identity: CallPeer(
        muted: participant.isMuted,
        speaking: participant.isSpeaking,
        camera: participant.isCameraEnabled(),
        screen: participant.isScreenShareEnabled(),
      ),
  };
```

Add before `setSpeakerDevice`:

```dart
  @override
  String? get camera => _cameraOpened == _cameraChosen ? _cameraChosen : null;

  LocalTrackPublication? get _cameraSent =>
      _room.localParticipant?.getTrackPublicationBySource(TrackSource.camera);

  @override
  Future<void> setCamera(bool on) async {
    final local = _room.localParticipant;
    if (local == null) return;
    final sent = _cameraSent;
    if (!on) {
      // Unpublished, not muted: the camera closes and its light goes out,
      // and the next one opens from whichever device is chosen by then.
      // ponytail: each switching on negotiates anew; mute and unmute if
      // that proves slow.
      if (sent != null) await local.removePublishedTrack(sent.sid);
      _cameraOpened = null;
      return;
    }
    if (sent != null) return;
    try {
      final id = _present(await Hardware.instance.videoInputs(), _cameraChosen);
      await local.setCameraEnabled(
        true,
        cameraCaptureOptions: _camera.copyWith(deviceId: id),
      );
      _cameraOpened = id;
    } on TrackCreateException catch (e) {
      throw CameraUnavailable(e.toString());
    } on PlatformException catch (e) {
      throw CameraUnavailable(e.toString());
    }
  }

  @override
  Future<void> setCameraDevice(String? id) async {
    _cameraChosen = id;
    if (_cameraSent == null) return;
    final String? now;
    try {
      now = _present(await Hardware.instance.videoInputs(), id);
    } on PlatformException catch (e) {
      throw CameraUnavailable(e.toString());
    }
    if (now == _cameraOpened) return;
    await setCamera(false);
    await setCamera(true);
  }

  @override
  Widget? video(String? identity, {bool screen = false}) {
    final Participant? participant = identity == null
        ? _room.localParticipant
        : _room.remoteParticipants.values
              .where((participant) => participant.identity == identity)
              .firstOrNull;
    final publication = participant?.getTrackPublicationBySource(
      screen ? TrackSource.screenShareVideo : TrackSource.camera,
    );
    final track = publication?.track;
    if (publication == null || publication.muted || track is! VideoTrack) {
      return null;
    }
    return VideoTrackRenderer(
      track,
      // A new track is a new picture, not the old one's next frame.
      key: ObjectKey(track),
      // A camera fills its tile, cropped; a screen is shown whole.
      fit: screen ? VideoViewFit.contain : VideoViewFit.cover,
      mirrorMode: identity == null && !screen
          ? VideoViewMirrorMode.mirror
          : VideoViewMirrorMode.off,
    );
  }

  /// Asks the server for everyone's pictures again, or for none of them.
  Future<void> _watch(bool seen) async {
    _hidden = !seen;
    for (final participant in _room.remoteParticipants.values) {
      for (final publication in participant.videoTrackPublications) {
        await (seen ? publication.enable() : publication.disable());
      }
    }
  }
```

In `disconnect`, add as the first line:

```dart
    _lifecycle.dispose();
```

If the analyzer reports a name from `livekit_client` differing from the above (`removePublishedTrack`, `getTrackPublicationBySource`, `isCameraEnabled`, `isScreenShareEnabled`, `VideoTrackRenderer`, `VideoViewFit`, `VideoViewMirrorMode`, `BackupVideoCodec`, `VideoEncoding`), read the package's source under `.dart_tool/package_config.json`'s `livekit_client` path and use the name it has; all of these were read from 2.13.1.

- [ ] **Step 7: Run the tests**

Run: `flutter test test/matrix/in_memory_call_media_test.dart test/matrix/matrix_calls_test.dart`
Expected: all pass (the calls tests unchanged in number).

- [ ] **Step 8: Check and commit**

Run: `mise run format && mise run check`
Expected: no issues.

```bash
git add -A
git commit -m "feat(calls): the media sends a camera and draws pictures"
```

---

### Task 3: The call's interface and the tile

**Files:**
- Modify: `lib/ui/call/calls.dart`
- Modify: `lib/ui/call/call_controller.dart`
- Modify: `lib/matrix/matrix_calls.dart` (stubs only)
- Modify: `lib/ui/call/call_tile.dart`
- Modify: `lib/ui/call/call_view.dart`
- Modify: `lib/ui/call/call_controls.dart`
- Modify: `test/voice_only_calls.dart`
- Test: `test/calls_features_test.dart`, `test/call_controls_devices_test.dart`

**Interfaces:**
- Consumes: `VoiceController.cameras`, `.camera`, `.chooseCamera` (Task 1).
- Produces:
  - `Widget? Calls.video(String memberId, {bool screen = false})`
  - `Calls.cameraDevice` and `Calls.setCameraDevice` no longer exist
  - `CallTile({Widget? video, ...})`
  - `VoiceOnlyCalls({Set<CallFeature> features = const {}, ...})`

- [ ] **Step 1: Write the failing tests**

In `test/voice_only_calls.dart`, so tests can ask for the camera's controls: add the constructor parameter and replace the `features` getter with a field.

```dart
  VoiceOnlyCalls({this.canJoin = true, this.leaving, this.features = const {}});
```

```dart
  @override
  final Set<CallFeature> features;
```

In `test/calls_features_test.dart`, add inside `main()`:

```dart
  group('a tile', () {
    Widget tile({Widget? video}) => SizedBox(
      width: 320,
      height: 200,
      child: CallTile(
        info: const TileInfo(_ada, camera: true),
        video: video,
      ),
    );

    testWidgets('draws the picture it is given', (tester) async {
      await _pump(
        tester,
        tile(video: const SizedBox.expand(key: ValueKey('picture'))),
      );

      expect(find.byKey(const ValueKey('picture')), findsOneWidget);
      expect(find.byIcon(LucideIcons.video), findsNothing);
    });

    testWidgets('with none, draws the camera placeholder', (tester) async {
      await _pump(tester, tile());

      expect(find.byIcon(LucideIcons.video), findsOneWidget);
    });
  });

  testWidgets("the call asks for the picture of whoever's camera is on", (
    tester,
  ) async {
    final calls = _Pictured()
      ..session = const CallSession(
        target: _oven,
        phase: CallPhase.live,
        participants: [CallParticipant(_ada, camera: true)],
      );

    await _pump(tester, CallView(calls: calls));

    expect(
      find.byKey(const ValueKey('picture-@ada:loaf.test-false')),
      findsOneWidget,
    );
    // Your own camera is off: nothing is asked for.
    expect(
      find.byKey(const ValueKey('picture-@you:loaf.test-false')),
      findsNothing,
    );
  });
```

and at the top level of the same file:

```dart
/// Calls that have a picture for anyone asked about.
class _Pictured extends VoiceOnlyCalls {
  @override
  Widget? video(String memberId, {bool screen = false}) =>
      SizedBox.expand(key: ValueKey('picture-$memberId-$screen'));
}
```

In `test/call_controls_devices_test.dart`, add the camera to `_pump`'s machine:

```dart
const _cam = AudioDevice('c920', 'HD Pro Webcam C920');
```

```dart
        MemoryAudioDevices(
          microphones: microphones ?? () => const [_rode, _sony],
          speakers: () => const [_desk],
          cameras: () => const [_cam],
        ),
```

and add inside `main()` (import `package:loaf_native/ui/call/calls.dart` if the file lacks it):

```dart
  group('with a camera to choose', () {
    VoiceOnlyCalls calls() => VoiceOnlyCalls(
      features: const {CallFeature.camera, CallFeature.cameraDevices},
    );

    testWidgets(
      'the camera menu lists the system default and the cameras',
      variant: _desktop,
      (tester) async {
        await _pump(tester, calls: calls());

        await _open(tester, 'Camera settings');

        expect(find.text('system default'), findsOneWidget);
        expect(find.text('HD Pro Webcam C920'), findsOneWidget);
        expect(find.text('RODE NT-USB'), findsNothing);
      },
    );

    testWidgets('picking a camera chooses it', variant: _desktop, (
      tester,
    ) async {
      final voice = await _pump(tester, calls: calls());
      await _open(tester, 'Camera settings');

      await tester.tap(find.text('HD Pro Webcam C920'));
      await tester.pumpAndSettle();

      expect(voice.camera, _cam);
    });
  });
```

- [ ] **Step 2: Run them to see them fail**

Run: `flutter test test/calls_features_test.dart test/call_controls_devices_test.dart`
Expected: compile errors — `CallTile` has no `video`, `Calls` has no `video`.

- [ ] **Step 3: The interface**

In `lib/ui/call/calls.dart` (add `import 'package:flutter/widgets.dart';` if the file does not already have `Widget`):

Remove `String get cameraDevice;` and `void setCameraDevice(String value);` from `Calls`.

Add after `lobbyState`:

```dart
  /// Draws [memberId]'s camera, or with [screen] the screen they share,
  /// filling whatever box it is given. Null where there is no picture to
  /// draw: a tile then draws its placeholder.
  Widget? video(String memberId, {bool screen = false});
```

Change `CallFeature.cameraDevices`' comment to:

```dart
  /// Choosing which camera, among those the voice settings list.
  cameraDevices,
```

- [ ] **Step 4: Everything that implements `Calls`**

`lib/ui/call/call_controller.dart`: delete the `cameraDevice` field and the `setCameraDevice` method, and add:

```dart
  /// None: the mock's tiles draw their placeholders.
  @override
  Widget? video(String memberId, {bool screen = false}) => null;
```

`lib/matrix/matrix_calls.dart`: delete `String get cameraDevice => '';` and `void setCameraDevice(String value) => _lacks('devices');`, and add among the stubs at the bottom (add `import 'package:flutter/widgets.dart' show Widget;`):

```dart
  @override
  Widget? video(String memberId, {bool screen = false}) => null;
```

`test/voice_only_calls.dart`: delete `String get cameraDevice => '';` and `void setCameraDevice(String value) => _lacks();`, and add:

```dart
  @override
  Widget? video(String memberId, {bool screen = false}) => null;
```

- [ ] **Step 5: The tile**

In `lib/ui/call/call_tile.dart`:

Add to `CallTile`'s constructor `this.video,` after `this.small = false,`, and the field:

```dart
  /// Their camera or their screen, live. Null: the placeholder for
  /// whichever [info] says they send.
  final Widget? video;
```

In `_CallTileState.build`, the first children of the `Stack` become:

```dart
          if (widget.video case final video?)
            video
          else if (info.screen)
            _ScreenPlaceholder(member: info.member)
          else if (info.camera)
            _VideoPlaceholder(member: info.member, mirrored: info.you)
          else
```

(the `ColoredBox` with the avatar that follows stays as it is).

- [ ] **Step 6: The call view hands the tile its picture**

In `lib/ui/call/call_view.dart`, in `_tile`, add to the `CallTile(` arguments after `small: small,`:

```dart
      // A screen takes the tile over its person's camera.
      video: info.screen || info.camera
          ? calls.video(info.id, screen: info.screen)
          : null,
```

- [ ] **Step 7: The camera menu**

In `lib/ui/call/call_controls.dart`:

Delete `const mockCameras = [...]`.

Replace the whole `if (_has(CallFeature.camera))` block in `_desktop` with:

```dart
    if (_has(CallFeature.camera))
      if (voice != null && _has(CallFeature.cameraDevices))
        _WithMenu(
          button: _cameraButton(context),
          tooltip: 'Camera',
          onOpen: (context, position) => _chooseDevice(
            context,
            position,
            voice: voice,
            devices: () => voice.cameras,
            chosen: () => voice.camera,
            choose: voice.chooseCamera,
          ),
        )
      else
        _cameraButton(context),
```

In `_cameraButton`, the blocked button says what happened on a computer, as the microphone's does:

```dart
    if (calls.cameraBlocked) {
      return _BlockedButton(
        icon: LucideIcons.videoOff,
        what: 'Camera',
        // On a computer the camera chosen did not open; the ⌄ beside it
        // chooses another.
        message: isDesktop ? "Couldn't open your camera" : null,
        size: _size,
      );
    }
```

- [ ] **Step 8: Run the tests**

Run: `flutter test test/calls_features_test.dart test/call_controls_devices_test.dart test/calls_ui_test.dart test/call_controller_test.dart`
Expected: all pass. If a test in `calls_ui_test.dart` or `call_controller_test.dart` used `cameraDevice`, `setCameraDevice` or `mockCameras`, delete that test: the choice is covered in `call_controls_devices_test.dart` now.

- [ ] **Step 9: Check and commit**

Run: `mise run format && mise run check`
Expected: no issues.

```bash
git add -A
git commit -m "feat(calls): a tile draws the picture the call has for it"
```

---

### Task 4: The camera for real

**Files:**
- Modify: `lib/matrix/matrix_calls.dart`
- Modify: `lib/matrix/matrix_rooms.dart`
- Modify: `lib/main.dart`
- Test: `test/matrix/matrix_calls_test.dart`

**Interfaces:**
- Consumes: `CallConnection.setCamera`, `.setCameraDevice`, `.camera`, `.video`, `CallPeer.camera`, `.screen`, `CameraUnavailable` (Task 2); `InMemoryCallMedia(camera:)`, `shareScreen` (Task 2); `VoiceSettings.camera` (Task 1); `Calls.video` (Task 3); `hasCallVideo` (Task 1).
- Produces:
  - `MatrixCalls(client, media, {bool video = false, ...})`
  - `MatrixRooms(client, {bool callVideo = false, ...})`

- [ ] **Step 1: Let the test world have a camera**

In `test/matrix/matrix_calls_test.dart`:

Add `_bea` beside `_ada`:

```dart
const _bea = '@bea:example.com';
```

`_World.open` gains two parameters and passes them on:

```dart
  Future<void> open({
    bool microphone = true,
    bool camera = true,
    bool video = true,
    bool encrypted = false,
    List<Map<String, Object?>> already = const [],
    ValueListenable<Set<String>>? present,
    Set<String> broken = const {},
  }) async {
```

```dart
      InMemoryCallMedia(
        server,
        network: network,
        quality: quality,
        microphone: microphone,
        camera: camera,
        present: present,
        broken: broken,
      ),
```

```dart
    final rooms = MatrixRooms(
      client,
      callMedia: _media,
      callVideo: video,
      voice: voice,
      voiceApplying: voiceApplying,
      now: () => now,
      callReconnectDelays: const [Duration(milliseconds: 20)],
    );
```

`_open` gains the same two and passes them on:

```dart
Future<_World> _open({
  bool microphone = true,
  bool camera = true,
  bool video = true,
  bool encrypted = false,
  List<Map<String, Object?>> already = const [],
  ValueListenable<Set<String>>? present,
  Set<String> broken = const {},
}) async {
  final world = _World();
  await world.open(
    microphone: microphone,
    camera: camera,
    video: video,
    encrypted: encrypted,
    already: already,
    present: present,
    broken: broken,
  );
  return world;
}
```

- [ ] **Step 2: Write the failing tests**

Add inside `main()` in the same file:

```dart
  group('your camera', () {
    const c920 = AudioDevice('c920', 'HD Pro Webcam C920');
    const brio = AudioDevice('brio', 'Logitech BRIO');

    test('is offered, with a choice of which, where video is on', () async {
      final world = await _open();

      expect(world.calls.features, {
        CallFeature.camera,
        CallFeature.cameraDevices,
      });
    });

    test('is not offered where video is off', () async {
      final world = await _open(video: false);

      expect(world.calls.features, isEmpty);
    });

    test('is off when you join', () async {
      final world = await _open();
      final watcher = await world.watcher();

      await world.join();
      await _settle();

      expect(world.calls.camera, isFalse);
      expect(watcher.peers[_mine]!.camera, isFalse);
    });

    test('is sent when you turn it on', () async {
      final world = await _open();
      final watcher = await world.watcher();
      await world.join();

      world.calls.toggleCamera();
      await _until(() => watcher.peers[_mine]?.camera ?? false);

      expect(world.calls.camera, isTrue);
      expect(watcher.peers[_mine]!.camera, isTrue);
    });

    test('stops being sent when you turn it off', () async {
      final world = await _open();
      final watcher = await world.watcher();
      await world.join();
      world.calls.toggleCamera();
      await _until(() => watcher.peers[_mine]?.camera ?? false);

      world.calls.toggleCamera();
      await _until(() => !(watcher.peers[_mine]?.camera ?? true));

      expect(world.calls.camera, isFalse);
      expect(watcher.peers[_mine]!.camera, isFalse);
    });

    test('switched on before joining is sent once you are in', () async {
      final world = await _open();
      final watcher = await world.watcher();

      world.calls.toggleCamera();
      await world.join();
      await _until(() => watcher.peers[_mine]?.camera ?? false);

      expect(watcher.peers[_mine]!.camera, isTrue);
    });

    test('tells listeners when it is switched', () async {
      final world = await _open();
      var told = 0;
      world.calls.addListener(() => told++);

      world.calls.toggleCamera();

      expect(told, 1);
    });

    test('that cannot open ends off, and says it is blocked', () async {
      final world = await _open(camera: false);
      await world.join();

      world.calls.toggleCamera();
      await _until(() => world.calls.cameraBlocked);

      expect(world.calls.cameraBlocked, isTrue);
      expect(world.calls.camera, isFalse);
    });

    test('that cannot open leaves your microphone sent', () async {
      final world = await _open(camera: false);
      final watcher = await world.watcher();
      await world.join();

      world.calls.toggleCamera();
      await _until(() => world.calls.cameraBlocked);

      expect(watcher.peers[_mine]!.muted, isFalse);
    });

    test('blocked, switching it does nothing', () async {
      final world = await _open(camera: false);
      await world.join();
      world.calls.toggleCamera();
      await _until(() => world.calls.cameraBlocked);

      world.calls.toggleCamera();

      expect(world.calls.camera, isFalse);
      expect(world.calls.cameraBlocked, isTrue);
    });

    test('a change of devices lifts the block, still off', () async {
      final present = ValueNotifier(<String>{});
      final world = await _open(camera: false, present: present);
      await world.join();
      world.calls.toggleCamera();
      await _until(() => world.calls.cameraBlocked);

      present.value = {'c920'};
      await _until(() => !world.calls.cameraBlocked);

      expect(world.calls.cameraBlocked, isFalse);
      expect(world.calls.camera, isFalse);
    });

    test('is off after you leave', () async {
      final world = await _open();
      final watcher = await world.watcher();
      await world.join();
      world.calls.toggleCamera();
      await _until(() => watcher.peers[_mine]?.camera ?? false);

      await world.calls.leave();

      expect(world.calls.camera, isFalse);
    });

    test('is off in the call you go to from another', () async {
      final world = await _open();
      final watcher = await world.watcher();
      await world.join();
      world.calls.toggleCamera();
      await _until(() => watcher.peers[_mine]?.camera ?? false);

      world.calls.joinVoice(_kilnChannel, spaceName: 'Bakery');
      await _until(
        () =>
            world.calls.session?.target.id == _kiln &&
            world.calls.session?.phase == CallPhase.live,
      );
      await _settle();

      expect(world.calls.camera, isFalse);
      expect(world.connection.video(null), isNull);
    });

    test('is off after the call is lost', () async {
      final world = await _open();
      final watcher = await world.watcher();
      await world.join();
      world.calls.toggleCamera();
      await _until(() => watcher.peers[_mine]?.camera ?? false);

      world.network.value = CallLink.ended;
      await _until(() => world.calls.session?.phase == CallPhase.failed);

      expect(world.calls.camera, isFalse);
    });

    test('is taken from the camera chosen', () async {
      final world = await _open();
      world.voice.value = const VoiceSettings(camera: c920);
      await world.join();

      world.calls.toggleCamera();
      await _until(() => world.connection.camera == 'c920');

      expect(world.connection.camera, 'c920');
    });

    test('choosing another during a call switches to it', () async {
      final world = await _open();
      world.voice.value = const VoiceSettings(camera: c920);
      await world.join();
      world.calls.toggleCamera();
      await _until(() => world.connection.camera == 'c920');

      world.voice.value = const VoiceSettings(camera: brio);
      await _until(() => world.connection.camera == 'brio');

      expect(world.connection.camera, 'brio');
      expect(world.calls.camera, isTrue);
    });

    test('a camera that does not open on being chosen ends off and '
        'blocked', () async {
      final world = await _open(broken: {'brio'});
      final watcher = await world.watcher();
      await world.join();
      world.calls.toggleCamera();
      await _until(() => watcher.peers[_mine]?.camera ?? false);

      world.voice.value = const VoiceSettings(camera: brio);
      await _until(() => world.calls.cameraBlocked);

      expect(world.calls.camera, isFalse);
      expect(watcher.peers[_mine]!.camera, isFalse);
    });

    test('deafening leaves it sent', () async {
      final world = await _open();
      final watcher = await world.watcher();
      await world.join();
      world.calls.toggleCamera();
      await _until(() => watcher.peers[_mine]?.camera ?? false);

      world.calls.toggleDeafen();
      await _settle();

      expect(watcher.peers[_mine]!.camera, isTrue);
    });
  });

  group('everyone else', () {
    CallParticipant ada(_World world) => world.calls.session!.participants
        .singleWhere((p) => p.member.id == _ada);

    test('sending a camera shows it', () async {
      final world = await _open();
      final phone = await world.other(_ada, 'PHONE');
      await world.join();

      await phone.setCamera(true);
      await _until(() => ada(world).camera);

      expect(ada(world).camera, isTrue);
      expect(ada(world).screen, isFalse);
    });

    test('sending one on either of two devices shows it', () async {
      final world = await _open();
      await world.other(_ada, 'PHONE');
      final laptop = await world.other(_ada, 'LAPTOP');
      await world.join();

      await laptop.setCamera(true);
      await _until(() => ada(world).camera);

      expect(ada(world).camera, isTrue);
    });

    test('turning it off shows that too', () async {
      final world = await _open();
      final phone = await world.other(_ada, 'PHONE');
      await world.join();
      await phone.setCamera(true);
      await _until(() => ada(world).camera);

      await phone.setCamera(false);
      await _until(() => !ada(world).camera);

      expect(ada(world).camera, isFalse);
    });

    test('sharing a screen shows it and takes the spotlight', () async {
      final world = await _open();
      final phone = await world.other(_ada, 'PHONE');
      await world.join();

      shareScreen(phone, on: true);
      await _until(() => world.calls.spotlight == _ada);

      expect(ada(world).screen, isTrue);
      expect(world.calls.spotlight, _ada);
    });

    test('of two shares, the newest is spotlit', () async {
      final world = await _open();
      final adas = await world.other(_ada, 'PHONE');
      final beas = await world.other(_bea, 'PHONE');
      await world.join();
      shareScreen(adas, on: true);
      await _until(() => world.calls.spotlight == _ada);

      shareScreen(beas, on: true);
      await _until(() => world.calls.spotlight == _bea);

      expect(world.calls.spotlight, _bea);
    });

    test('the newest share ending gives the spotlight back', () async {
      final world = await _open();
      final adas = await world.other(_ada, 'PHONE');
      final beas = await world.other(_bea, 'PHONE');
      await world.join();
      shareScreen(adas, on: true);
      await _until(() => world.calls.spotlight == _ada);
      shareScreen(beas, on: true);
      await _until(() => world.calls.spotlight == _bea);

      shareScreen(beas, on: false);
      await _until(() => world.calls.spotlight == _ada);

      expect(world.calls.spotlight, _ada);
    });

    test('a pin overrides a share', () async {
      final world = await _open();
      final adas = await world.other(_ada, 'PHONE');
      await world.other(_bea, 'PHONE');
      await world.join();
      shareScreen(adas, on: true);
      await _until(() => world.calls.spotlight == _ada);

      world.calls.pin(_bea);

      expect(world.calls.spotlight, _bea);
    });

    test('no share and no pin spotlights no one', () async {
      final world = await _open();
      await world.other(_ada, 'PHONE');
      await world.join();

      expect(world.calls.spotlight, isNull);
    });
  });

  group('a picture', () {
    test('is there for a camera being sent, and not for a screen', () async {
      final world = await _open();
      final phone = await world.other(_ada, 'PHONE');
      await world.join();
      expect(world.calls.video(_ada), isNull);

      await phone.setCamera(true);
      await _until(() => world.calls.video(_ada) != null);

      expect(world.calls.video(_ada), isNotNull);
      expect(world.calls.video(_ada, screen: true), isNull);
    });

    test('is there for a screen being shared', () async {
      final world = await _open();
      final phone = await world.other(_ada, 'PHONE');
      await world.join();

      shareScreen(phone, on: true);
      await _until(() => world.calls.video(_ada, screen: true) != null);

      expect(world.calls.video(_ada, screen: true), isNotNull);
    });

    test('is the first device of theirs that sends one', () async {
      final world = await _open();
      await world.other(_ada, 'PHONE');
      final laptop = await world.other(_ada, 'LAPTOP');
      await world.join();

      await laptop.setCamera(true);
      await _until(() => world.calls.video(_ada) != null);

      expect(
        world.calls.video(_ada)!.key,
        const ValueKey('video-$_ada:LAPTOP-camera'),
      );
    });

    test('of you is there while your camera is on', () async {
      final world = await _open();
      await world.join();
      expect(world.calls.video(_me), isNull);

      world.calls.toggleCamera();
      await _until(() => world.calls.video(_me) != null);

      expect(world.calls.video(_me), isNotNull);
    });

    test('is not there outside a call', () async {
      final world = await _open();

      expect(world.calls.video(_ada), isNull);
      expect(world.calls.video(_me), isNull);
    });
  });
```

- [ ] **Step 3: Run them to see them fail**

Run: `flutter test test/matrix/matrix_calls_test.dart --name "your camera|everyone else|a picture"`
Expected: compile error — `MatrixRooms` has no `callVideo`.

- [ ] **Step 4: `MatrixRooms` passes video on**

In `lib/matrix/matrix_rooms.dart`:

Add the constructor parameter after `this._callMedia,`:

```dart
    this._callVideo = false,
```

the field after `_callMedia`'s:

```dart
  /// Whether calls have cameras and show screen shares.
  final bool _callVideo;
```

and the argument in `calls`, after `media,`:

```dart
      video: _callVideo,
```

- [ ] **Step 5: `MatrixCalls`: the flag, the features, your own camera**

In `lib/matrix/matrix_calls.dart`:

Change the file's doc comment:

```dart
/// Voice channels for real: the call server's access, this device's
/// membership in the room, and the media, sound and pictures, behind the
/// one [Calls] the shell and the call widgets read.
```

Add the constructor parameter after `this._voiceApplying,`:

```dart
    this._video = false,
```

and the field after `_voiceApplying`:

```dart
  /// Whether calls have cameras and show screen shares.
  final bool _video;
```

Add under `var _deafened = false;`:

```dart
  /// Whether you want your camera sent. Chosen before a call, it is how
  /// you join; a call that ends puts it back to off.
  var _camera = false;
```

Replace `features` with:

```dart
  @override
  Set<CallFeature> get features => _video
      ? const {CallFeature.camera, CallFeature.cameraDevices}
      : const {};
```

Replace `spotlight` with:

```dart
  @override
  String? get spotlight => _pinned ?? _live?.sharing.lastOrNull;
```

Add under `micBlocked`:

```dart
  @override
  bool get camera => _camera;

  @override
  bool cameraBlocked = false;
```

and delete, from the stubs at the bottom, `bool get camera => false;`, `bool get cameraBlocked => false;`, `void toggleCamera() => _lacks('camera');` and the `video` stub Task 3 added.

Add under `toggleDeafen`:

```dart
  @override
  void toggleCamera() {
    if (!_video) _lacks('camera');
    if (cameraBlocked) return;
    _camera = !_camera;
    _changedAudio();
  }
```

- [ ] **Step 6: `MatrixCalls`: applying it**

Replace the whole of `_applyAudio` with:

```dart
  /// Brings what [live] sends and plays in line with [muted], [deafened]
  /// and [camera] as they stand when its turn comes; with [voice], first
  /// the microphone, its processing, the speaker and the camera in line
  /// with those chosen.
  void _applyAudio(_Live live, {bool voice = false}) {
    final before = _audioApplied;
    final applied = Completer<void>();
    _audioApplied = applied.future;
    unawaited(() async {
      await before;
      try {
        final connection = live.connection;
        if (!identical(live, _live) || connection == null) return;
        try {
          if (voice) {
            _switching(true);
            try {
              await _applyVoice(connection);
            } finally {
              _switching(false);
            }
          }
          await connection.setDeafened(deafened);
          await connection.setMicrophone(!muted);
        } on MicrophoneUnavailable {
          _muted = true;
          micBlocked = true;
          _notify();
        }
        // After the sound, and whatever became of the microphone.
        await _applyCamera(connection, chosen: voice);
      } finally {
        applied.complete();
      }
    }());
  }

  /// Sends the camera or stops, as [camera] has it; with [chosen], first
  /// takes it from the camera chosen.
  Future<void> _applyCamera(
    CallConnection connection, {
    required bool chosen,
  }) async {
    if (!_video) return;
    try {
      if (chosen) {
        if (cameraBlocked) {
          // Another camera may open where the last did not. Still off:
          // turning it on is yours to do.
          cameraBlocked = false;
          _notify();
        }
        await connection.setCameraDevice(_voice?.value.camera?.id);
      }
      await connection.setCamera(_camera);
    } on CameraUnavailable {
      _camera = false;
      cameraBlocked = true;
      _notify();
    }
  }

  /// A call that has ended leaves the camera off, and free to be tried.
  void _cameraOff() {
    _camera = false;
    cameraBlocked = false;
  }
```

Call `_cameraOff()`:

- in `leave()`, on the line before `_session = null;`
- in `_lost`, on the line before `_phase(CallPhase.failed);`
- in `_hungUp`, on the line before `_phase(CallPhase.hungUp);`
- in `_join`, directly after `final before = _detach();`:

```dart
    // Going from one call to another ends the first; a camera switched on
    // with no call under way is how you asked to join this one.
    if (before != null) _cameraOff();
```

- [ ] **Step 7: `MatrixCalls`: everyone else, the spotlight, the pictures**

In `_participants`, the `CallParticipant(` becomes:

```dart
            return CallParticipant(
              occupant.member,
              muted: theirs.every((peer) => peer.muted),
              silenced: silences[occupant.member.id],
              camera: theirs.any((peer) => peer.camera),
              screen: theirs.any((peer) => peer.screen),
              speaking: theirs.any((peer) => peer.speaking),
            );
```

and its doc comment:

```dart
  /// Everyone else among [occupants]. Someone is speaking if any of their
  /// devices is, muted unless one of them sends a microphone, and seen or
  /// sharing if any of them sends a camera or a screen.
```

Replace `_refresh` with:

```dart
  void _refresh(_Live live) {
    final occupants = _occupants(live.room);
    final participants = _participants(live.room, occupants, live.connection);
    final sharing = {
      for (final participant in participants)
        if (participant.screen) participant.member.id,
    };
    // Kept in the order each began, so the newest is last.
    live.sharing
      ..removeWhere((id) => !sharing.contains(id))
      ..addAll(sharing.difference(live.sharing.toSet()));
    _session = _session?.copyWith(participants: participants);
    _notify();
    _syncVolumes(live, occupants);
  }
```

Add to `_Live`:

```dart
  /// Who is sharing a screen, by user id, in the order they began.
  final sharing = <String>[];
```

Add under `pin`:

```dart
  @override
  Widget? video(String memberId, {bool screen = false}) {
    final live = _live;
    final connection = live?.connection;
    if (live == null || connection == null) return null;
    if (memberId == _client.userID) {
      return connection.video(null, screen: screen);
    }
    for (final occupant in _occupants(live.room)) {
      if (occupant.member.id != memberId) continue;
      // One tile a person: the first of their devices that sends one.
      for (final device in occupant.devices) {
        final video = connection.video('$memberId:$device', screen: screen);
        if (video != null) return video;
      }
    }
    return null;
  }
```

Keep the `import 'package:flutter/widgets.dart' show Widget;` Task 3 added.

- [ ] **Step 8: Run the new tests**

Run: `flutter test test/matrix/matrix_calls_test.dart --name "your camera|everyone else|a picture"`
Expected: all pass.

If `is the first device of theirs that sends one` fails on the order of `occupant.devices` (a `Set`), the picture is still the right one: change the test to send from `PHONE` only if the set's order is not the order of joining, and say so in the commit message.

- [ ] **Step 9: Run every call test**

Run: `flutter test test/matrix/matrix_calls_test.dart test/calls_features_test.dart test/calls_ui_test.dart test/call_controls_devices_test.dart`
Expected: all pass, the existing ones included.

- [ ] **Step 10: Switch it on for Linux**

In `lib/main.dart`, in `newRooms = () => MatrixRooms(`, add after the `callMedia:` argument:

```dart
      callVideo: calls && hasCallVideo,
```

`hasCallVideo` comes from `lib/ui/platform.dart`, which `main.dart` already imports for `hasCalls`.

- [ ] **Step 11: Check, run everything, commit**

Run: `mise run format && mise run check && mise run test`
Expected: no issues; every test passes.

```bash
git add -A
git commit -m "feat(calls): your camera, and everyone's pictures, on Linux"
```

---

### Task 5: By hand on loaf.moe

Nothing in `lib/platform/livekit_media.dart` has an automated test. This task is the check of it, on Linux, against someone on Cinny in the same voice channel. It needs a person at the machine: stop and ask for one if you are an agent without a display.

**Files:** none, unless a step fails.

- [ ] **Step 1: Run the app**

Run: `mise run run:linux`
Expected: the app starts and signs in to loaf.moe.

- [ ] **Step 2: Your camera**

Join a voice channel in a room that is not encrypted. Click the camera button.
Expected: your tile shows your camera, mirrored; the camera's light is on; the Cinny user sees you.

Click it again.
Expected: your tile goes back to your avatar; the light goes out; the Cinny user's tile of you does too.

- [ ] **Step 3: Theirs**

Have the Cinny user turn their camera on.
Expected: their tile shows it, filling the tile, cropped, under their name chip, with the speaking ring still drawn around it.

- [ ] **Step 4: A screen share**

Have the Cinny user share a screen.
Expected: their tile shows the screen whole, with bars, and takes the spotlight; everyone else is in the filmstrip. Pin another tile: the spotlight follows the pin. Unpin: it returns to the share. They stop sharing: the grid returns.

- [ ] **Step 5: Choosing a camera**

With two cameras plugged in, open the ⌄ beside the camera button and pick the other while the camera is on.
Expected: both are listed under "system default"; the picture changes to the other camera. Settings → voice shows the same list with the same one checked.

- [ ] **Step 6: A camera going away**

Unplug the camera in use while it is on.
Expected: no crash. Either the picture moves to the system default, or the camera goes off and the button shows as blocked with "Couldn't open your camera". Write down which.

- [ ] **Step 7: Out of sight**

With their camera on, navigate to a text channel, then back.
Expected: the call goes on; the picture is back when you return.

Minimise the window for ten seconds and restore it.
Expected: the picture is back within a second or two.

- [ ] **Step 8: Leaving**

With your camera on, leave the call and join it again.
Expected: you join with the camera off.

- [ ] **Step 9: What the branch review asked to be looked at**

- Turn the camera on and leave within a second; join with the lobby's toggle on and leave at once. Expected: the light goes out both times.
- Cut the network briefly with the camera on. Expected: after LiveKit reconnects, the Cinny user sees you again and your own tile recovers.
- Open the camera in another program (a browser tab), then turn it on in the call. Write down whether the button ends blocked, or shows on over no picture.
- With the camera blocked, plug a camera in. Expected (a known limitation): the block stays until another camera is picked from the ⌄ menu or the call is left.
- Minimise and restore under X11 and under Wayland, once quickly, and once while someone joins or starts sharing. Expected: every picture returns. Write down whether Wayland stops the pictures at all.
- Watch a picture while people start and stop speaking, and while pinning and unpinning. Write down any flicker or blank moment.
- Change camera mid-call and have the Cinny user say how long your tile dropped to the avatar.
- Try a webcam that cannot do 720p. Expected: it opens at what it can do.

- [ ] **Step 10: Record what was found**

If every step went as expected, there is nothing to commit. If one did not, fix it in `lib/platform/livekit_media.dart`, add what was learned to the spec's "Known limitations" where it is a limit and not a bug, and commit:

```bash
git add -A
git commit -m "fix(calls): <what the hand check found>"
```
