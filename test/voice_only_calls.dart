import 'package:flutter/material.dart';
import 'package:loaf_native/ui/call/calls.dart';
import 'package:loaf_native/ui/model/models.dart';

/// Calls with voice and nothing else, as a backend with no camera, screen
/// sharing, device choice, volume or DM calls has them. Joining goes live at
/// once.
class VoiceOnlyCalls extends ChangeNotifier implements Calls {
  VoiceOnlyCalls({this.canJoin = true, this.leaving});

  /// What [joinable] answers for every channel.
  final bool canJoin;

  /// When leaving finishes telling everyone else. Null: at once.
  final Future<void>? leaving;

  @override
  final Member me = const Member('@you:loaf.test', 'you', Color(0xFF888888));

  @override
  Set<CallFeature> get features => const {};

  @override
  CallSession? session;

  @override
  bool muted = false;
  @override
  bool deafened = false;
  @override
  String? pinned;

  /// Puts the call as [session] has it, as a backend's own events would.
  void show(CallSession? session) {
    this.session = session;
    notifyListeners();
  }

  @override
  bool joinable(Channel channel) => canJoin;

  @override
  bool get inCall => session != null && !session!.over;

  @override
  void joinVoice(Channel channel, {required String spaceName}) {
    session = CallSession(
      target: channel,
      spaceName: spaceName,
      phase: CallPhase.live,
      participants: const [],
    );
    notifyListeners();
  }

  @override
  Future<void> leave() {
    session = null;
    notifyListeners();
    return leaving ?? Future.value();
  }

  @override
  void toggleMute() {
    muted = !muted;
    notifyListeners();
  }

  @override
  void toggleDeafen() {
    deafened = !deafened;
    muted = deafened;
    notifyListeners();
  }

  @override
  void pin(String? id) {
    pinned = id;
    notifyListeners();
  }

  @override
  void retry() {}

  @override
  String? get spotlight => pinned;
  @override
  IncomingRing? get incoming => null;
  @override
  bool get encrypted => false;
  @override
  bool get camera => false;
  @override
  bool get micBlocked => false;
  @override
  bool get cameraBlocked => false;
  @override
  String? get sharing => null;
  @override
  AudioRoute get route => AudioRoute.speaker;
  @override
  String get micDevice => '';
  @override
  String get cameraDevice => '';
  @override
  double volumeOf(String id) => 1;
  @override
  CallParticipant? lobbyState(String memberId) => null;

  @override
  void startDirect(Channel chat, {bool video = false}) => _lacks();
  @override
  void callAgain() => _lacks();
  @override
  void accept() => _lacks();
  @override
  void decline() => _lacks();
  @override
  void toggleCamera() => _lacks();
  @override
  void flipCamera() => _lacks();
  @override
  void startScreenShare(String source) => _lacks();
  @override
  void stopScreenShare() => _lacks();
  @override
  void setRoute(AudioRoute value) => _lacks();
  @override
  void setMicDevice(String value) => _lacks();
  @override
  void setCameraDevice(String value) => _lacks();
  @override
  void setVolume(String id, double value) => _lacks();

  Never _lacks() => throw UnsupportedError('voice only');
}
