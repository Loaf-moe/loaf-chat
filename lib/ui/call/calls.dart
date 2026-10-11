/// What a call is, to the shell and the call widgets: the session, the
/// people in it, your own controls. [Calls] is the one thing they hold.
library;

import 'package:flutter/foundation.dart';

import '../model/models.dart';

enum CallPhase {
  /// An outgoing DM call nobody has answered yet. You are already in the
  /// call; ringing is how the wait is presented.
  ringing,
  connecting,
  live,
  reconnecting,

  /// Couldn't connect. Offers retry and close.
  failed,

  /// Outgoing DM ring ended with nobody answering. Offers call again.
  unanswered,

  /// A 1:1 DM ring the other person declined. Offers call again.
  declined,
}

/// Where one invitee of an outgoing DM call has got to.
enum RingState { ringing, joined, declined, noAnswer }

enum AudioRoute {
  speaker('speaker'),
  phone('iPhone'),
  bluetooth('AirPods');

  const AudioRoute(this.label);
  final String label;
}

/// A system line a call leaves in its DM's timeline.
@immutable
sealed class CallRecord {
  const CallRecord();

  String get label;
}

class EndedCall extends CallRecord {
  const EndedCall(this.duration);

  final Duration duration;

  @override
  String get label {
    final minutes = duration.inMinutes;
    if (minutes >= 60) return 'call · ${minutes ~/ 60}h ${minutes % 60}m';
    return 'call · ${minutes < 1 ? 1 : minutes}m';
  }
}

class MissedCall extends CallRecord {
  const MissedCall();

  @override
  String get label => 'missed call';
}

class NoOneAnswered extends CallRecord {
  const NoOneAnswered();

  @override
  String get label => 'no one answered';
}

/// Someone else in the call, as their tile draws them.
@immutable
class CallParticipant {
  const CallParticipant(
    this.member, {
    this.muted = false,
    this.deafened = false,
    this.camera = false,
    this.screen = false,
    this.speaking = false,
    this.ring,
  });

  final Member member;
  final bool muted;
  final bool deafened;
  final bool camera;
  final bool screen;
  final bool speaking;

  /// Only for invitees of a DM call you started.
  final RingState? ring;

  /// In the call, as opposed to still being rung or having declined.
  bool get present => ring == null || ring == RingState.joined;

  CallParticipant copyWith({
    bool? muted,
    bool? camera,
    bool? screen,
    bool? speaking,
    RingState? ring,
  }) => CallParticipant(
    member,
    muted: muted ?? this.muted,
    deafened: deafened,
    camera: camera ?? this.camera,
    screen: screen ?? this.screen,
    speaking: speaking ?? this.speaking,
    ring: ring ?? this.ring,
  );
}

@immutable
class CallSession {
  const CallSession({
    required this.target,
    required this.phase,
    required this.participants,
    this.spaceName,
    this.startedAt,
  });

  /// A voice channel or a direct chat.
  final Channel target;

  /// The voice channel's space, for the connected-call bar.
  final String? spaceName;

  final CallPhase phase;
  final List<CallParticipant> participants;

  /// When the call went live, for the duration its DM records.
  final DateTime? startedAt;

  bool get direct => target.kind == ChannelKind.direct;

  /// Ended states still show in the panel until closed, but you are no
  /// longer in anything.
  bool get over =>
      phase == CallPhase.failed ||
      phase == CallPhase.unanswered ||
      phase == CallPhase.declined;

  CallParticipant? find(String id) =>
      participants.where((p) => p.member.id == id).firstOrNull;

  CallSession copyWith({
    CallPhase? phase,
    List<CallParticipant>? participants,
    DateTime? startedAt,
  }) => CallSession(
    target: target,
    spaceName: spaceName,
    phase: phase ?? this.phase,
    participants: participants ?? this.participants,
    startedAt: startedAt ?? this.startedAt,
  );
}

/// A DM call ringing at you.
@immutable
class IncomingRing {
  const IncomingRing(this.chat, this.caller);

  final Channel chat;
  final Member caller;
}

/// What a backend's calls can do beyond voice. A control for a feature that
/// is missing is not drawn.
enum CallFeature {
  camera,
  screenShare,

  /// Choosing which camera.
  cameraDevices,

  /// Choosing speaker, earpiece or headset on a phone.
  audioRoute,

  /// Turning one person up or down.
  volume,

  /// Calls in direct chats, and their ringing.
  direct,
}

/// How well your own link to a call is carrying it.
enum CallQuality {
  /// Not rated yet.
  unknown,
  good,
  poor,

  /// Still connected, but barely anything gets through.
  bad,
}

/// The one call you are in, and the one ringing at you, as the shell and the
/// call widgets read and drive it.
abstract interface class Calls implements Listenable {
  Member get me;

  /// How well your link is carrying the call you are in.
  CallQuality get quality;

  Set<CallFeature> get features;

  /// Whether [channel]'s call can be joined at all.
  bool joinable(Channel channel);

  CallSession? get session;
  IncomingRing? get incoming;

  /// Whether you are in a call right now: connecting, ringing out or live.
  bool get inCall;

  String? get pinned;

  /// Whose tile fills the stage: a pinned tile, else the newest screen share.
  String? get spotlight;

  double volumeOf(String id);

  /// Whether the call's media is encrypted end to end.
  bool get encrypted;

  // Your own state. It outlives any one call, like the account panel's
  // mute and deafen do.
  bool get muted;
  bool get deafened;
  bool get camera;
  AudioRoute get route;
  String get cameraDevice;

  /// What you are sharing, if anything. Desktop only.
  String? get sharing;

  /// Whether the system refuses the app the microphone.
  bool get micBlocked;

  /// Whether the system refuses the app the camera.
  bool get cameraBlocked;

  /// How someone in a call you have not joined is set up, when that is
  /// known: muted, camera on.
  CallParticipant? lobbyState(String memberId);

  void joinVoice(Channel channel, {required String spaceName});

  /// Rings everyone in a direct chat. [video] starts with your camera on.
  void startDirect(Channel chat, {bool video = false});

  void callAgain();

  /// Cancels a ring, hangs up, or dismisses a call that has ended. Leaves
  /// any record the call is owed. The call is gone from [session] at once;
  /// the future completes when everyone else has been told too.
  Future<void> leave();

  void retry();
  void accept();
  void decline();

  void toggleMute();
  void toggleDeafen();
  void toggleCamera();
  void flipCamera();
  void setRoute(AudioRoute value);
  void setCameraDevice(String value);
  void startScreenShare(String source);
  void stopScreenShare();
  void pin(String? id);
  void setVolume(String id, double value);
}
