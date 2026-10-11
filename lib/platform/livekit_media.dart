/// A call's media over LiveKit: the one file that touches `livekit_client`.
library;

import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';

import '../matrix/call_media.dart';

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
        defaultAudioCaptureOptions: AudioCaptureOptions(
          stopAudioCaptureOnMute: false,
        ),
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
        // Someone who starts talking while you are deafened stays unheard.
        if (_deafened && event.track is RemoteAudioTrack) {
          await event.track.disable();
        }
      });
  }

  final Room _room;
  late final EventsListener<RoomEvent> _events;
  var _deafened = false;

  @override
  CallLink get link => switch (_room.connectionState) {
    ConnectionState.connected => CallLink.connected,
    ConnectionState.connecting ||
    ConnectionState.reconnecting => CallLink.reconnecting,
    ConnectionState.disconnected => CallLink.lost,
  };

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
    try {
      await _room.localParticipant?.setMicrophoneEnabled(on);
    } on TrackCreateException catch (e) {
      throw MicrophoneUnavailable(e.toString());
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
