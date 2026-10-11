/// A call's media and the machine's audio devices over LiveKit: the one
/// file that touches `livekit_client`.
library;

import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc show Helper;
import 'package:livekit_client/livekit_client.dart';

import '../matrix/call_media.dart';
import '../ui/settings/voice_settings.dart';

/// Muting switches the microphone off and leaves it open.
const _capture = AudioCaptureOptions(stopAudioCaptureOnMute: false);

/// [id] where [devices] has it, else the first: the one WebRTC opens when
/// told none.
String? _present(List<MediaDevice> devices, String? id) =>
    devices.any((device) => device.deviceId == id)
    ? id
    : devices.firstOrNull?.deviceId;

class LiveKitAudioDevices implements AudioDevices {
  const LiveKitAudioDevices();

  @override
  Future<List<AudioDevice>> microphones() =>
      _listed(Hardware.instance.audioInputs);

  @override
  Future<List<AudioDevice>> speakers() =>
      _listed(Hardware.instance.audioOutputs);

  @override
  Stream<void> get changes => Hardware.instance.onDeviceChange.stream;

  static Future<List<AudioDevice>> _listed(
    Future<List<MediaDevice>> Function() list,
  ) async {
    final List<MediaDevice> devices;
    try {
      devices = await list();
    } on PlatformException {
      // The machine would not say: nothing to choose from but the default.
      return const [];
    }
    return [
      for (final device in devices)
        // On Linux the system's default is listed a second time, under this
        // prefix.
        if (!device.label.startsWith('default: '))
          AudioDevice(device.deviceId, device.label),
    ];
  }
}

class LiveKitMedia implements CallMedia {
  const LiveKitMedia();

  @override
  Future<CallConnection> connect(Uri url, String jwt) async {
    if (defaultTargetPlatform == TargetPlatform.linux) {
      ConnectivityPlatform.instance = _AlwaysOnline();
    }
    final room = Room(
      roomOptions: const RoomOptions(
        // As Element Call publishes, so that either end hears the other the
        // same way.
        defaultAudioPublishOptions: AudioPublishOptions(dtx: true, red: false),
        defaultAudioCaptureOptions: _capture,
      ),
    );
    try {
      await room.connect(url.toString(), jwt);
    } on Exception catch (e) {
      // Whatever kind of failure LiveKit reports: the call is not reached.
      await room.dispose();
      // LiveKit's address carries the token.
      throw CallMediaUnreachable(
        e.toString().replaceAll(
          RegExp(r'access_token=[^&\s]+'),
          'access_token=…',
        ),
      );
    }
    return _LiveKitConnection(room);
  }
}

/// LiveKit asks `connectivity_plus` whether there is a network before every
/// connection. On Linux that asks NetworkManager over D-Bus and throws where
/// there is none, so there LiveKit is told yes and finds out by connecting.
class _AlwaysOnline extends ConnectivityPlatform {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => const [
    ConnectivityResult.other,
  ];

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      const Stream.empty();
}

class _LiveKitConnection extends ChangeNotifier implements CallConnection {
  _LiveKitConnection(this._room) {
    _room.addListener(notifyListeners);
    _events = _room.createListener()
      ..on<TrackSubscribedEvent>((event) async {
        final track = event.track;
        if (track is! RemoteAudioTrack) return;
        final volume = _volumes[event.participant.identity];
        if (volume != null) await _play(track, volume);
        // Someone who starts talking while you are deafened stays unheard.
        if (_deafened) await track.disable();
      });
  }

  final Room _room;
  late final EventsListener<RoomEvent> _events;
  var _deafened = false;

  /// How loud each device is played, by identity, where one was set.
  final _volumes = <String, double>{};

  /// The devices chosen, by id. Null: the system's default.
  String? _microphone;
  String? _speaker;

  /// The devices the microphone is open from and the speaker was last set
  /// to, by id. Null when neither has happened.
  String? _opened;
  String? _playing;

  /// The processing chosen, and what the microphone is open with. Linux
  /// takes it only when a microphone is opened.
  var _processing = const MicrophoneProcessing();
  MicrophoneProcessing? _openedWith;

  @override
  MicrophoneProcessing get processing => _openedWith ?? _processing;

  @override
  String? get microphone => _opened == _microphone ? _microphone : null;

  @override
  String? get speaker => _playing == _speaker ? _speaker : null;

  @override
  Stream<void> get deviceChanges => Hardware.instance.onDeviceChange.stream;

  LocalAudioTrack? get _track =>
      _room.localParticipant?.audioTrackPublications.firstOrNull?.track;

  @override
  CallLink get link => switch (_room.connectionState) {
    ConnectionState.connected => CallLink.connected,
    ConnectionState.connecting ||
    ConnectionState.reconnecting => CallLink.reconnecting,
    ConnectionState.disconnected => CallLink.lost,
  };

  @override
  bool get speaking => _room.localParticipant?.isSpeaking ?? false;

  @override
  CallQuality get quality =>
      switch (_room.localParticipant?.connectionQuality) {
        ConnectionQuality.excellent ||
        ConnectionQuality.good => CallQuality.good,
        ConnectionQuality.poor => CallQuality.poor,
        ConnectionQuality.lost => CallQuality.bad,
        ConnectionQuality.unknown || null => CallQuality.unknown,
      };

  @override
  Map<String, CallPeer> get peers => {
    for (final participant in _room.remoteParticipants.values)
      participant.identity: CallPeer(
        muted: participant.isMuted,
        speaking: participant.isSpeaking,
      ),
  };

  @override
  Future<void> setMicrophone(bool on) async {
    final local = _room.localParticipant;
    if (local == null) return;
    try {
      final track = _track;
      if (!on || track != null) {
        // A muted microphone stays open on the device it had, so one chosen
        // meanwhile is opened now.
        if (on) await _reopen(track!);
        await local.setMicrophoneEnabled(on);
        return;
      }
      final id = _present(await Hardware.instance.audioInputs(), _microphone);
      final processing = _processing;
      await local.setMicrophoneEnabled(
        true,
        audioCaptureOptions: _options(id, processing),
      );
      _opened = id;
      _openedWith = processing;
    } on TrackCreateException catch (e) {
      throw MicrophoneUnavailable(e.toString());
    } on PlatformException catch (e) {
      throw MicrophoneUnavailable(e.toString());
    }
  }

  @override
  Future<void> setMicrophoneDevice(String? id) {
    _microphone = id;
    return _reopenIfSent();
  }

  @override
  Future<void> setMicrophoneProcessing(MicrophoneProcessing processing) {
    _processing = processing;
    return _reopenIfSent();
  }

  Future<void> _reopenIfSent() async {
    final track = _track;
    // Reopening a muted microphone would send it until it is switched off
    // again; [setMicrophone] reopens it on the way to unmuting.
    if (track == null || track.muted) return;
    try {
      await _reopen(track);
    } on TrackCreateException catch (e) {
      throw MicrophoneUnavailable(e.toString());
    } on PlatformException catch (e) {
      throw MicrophoneUnavailable(e.toString());
    }
  }

  /// Opens the microphone again from the device and with the processing
  /// chosen, when either is not what it is open with.
  Future<void> _reopen(LocalAudioTrack track) async {
    final id = _present(await Hardware.instance.audioInputs(), _microphone);
    final processing = _processing;
    if (id == null || (id == _opened && processing == _openedWith)) return;
    // Closed before the next is opened, so a failure leaves none open.
    _opened = null;
    _openedWith = null;
    await track.restartTrack(_options(id, processing));
    _opened = id;
    _openedWith = processing;
  }

  static AudioCaptureOptions _options(
    String? id,
    MicrophoneProcessing processing,
  ) => _capture.copyWith(
    deviceId: id,
    echoCancellation: processing.echoCancellation,
    noiseSuppression: processing.noiseSuppression,
    autoGainControl: processing.automaticGain,
    highPassFilter: processing.highPassFilter,
  );

  @override
  Future<void> setSpeakerDevice(String? id) async {
    _speaker = id;
    try {
      final devices = await Hardware.instance.audioOutputs();
      final device =
          devices.where((device) => device.deviceId == id).firstOrNull ??
          devices.firstOrNull;
      if (device == null || device.deviceId == _playing) return;
      await Hardware.instance.selectAudioOutput(device);
      _playing = device.deviceId;
    } on PlatformException catch (e) {
      throw SpeakerUnavailable(e.toString());
    }
  }

  @override
  Future<void> setVolume(String identity, double volume) async {
    _volumes[identity] = volume;
    for (final participant in _room.remoteParticipants.values) {
      if (participant.identity != identity) continue;
      for (final publication in participant.audioTrackPublications) {
        final track = publication.track;
        if (track != null) await _play(track, volume);
      }
    }
  }

  Future<void> _play(RemoteAudioTrack track, double volume) async {
    try {
      await rtc.Helper.setVolume(volume, track.mediaStreamTrack);
    } on PlatformException catch (e) {
      // The plugin's code for a track it no longer has: it ended
      // meanwhile, and nothing is left to set.
      if (e.code != 'setVolume') rethrow;
    }
  }

  @override
  Future<void> setDeafened(bool deafened) async {
    _deafened = deafened;
    for (final participant in _room.remoteParticipants.values) {
      for (final publication in participant.audioTrackPublications) {
        final track = publication.track;
        if (track == null) continue;
        await (deafened ? track.disable() : track.enable());
      }
    }
  }

  @override
  Future<void> disconnect() async {
    _room.removeListener(notifyListeners);
    await _events.dispose();
    await _room.disconnect();
    await _room.dispose();
  }
}
