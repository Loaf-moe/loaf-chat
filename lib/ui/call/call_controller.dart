/// The one call you are in, and the one ringing at you — mockup only.
///
/// Stands in for matrix-dart-sdk's MatrixRTC session plus LiveKit: the phases
/// and flags are the ones the real thing will report, driven here by timers
/// and fixture behaviour instead of the network. See the calls design spec.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../mock/fixtures.dart';

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

/// How a fixture member responds to being rung, so the mock can play out
/// answers, declines and silence.
class RingBehaviour {
  const RingBehaviour.answer(this.after) : answers = true;
  const RingBehaviour.decline(this.after) : answers = false;

  final bool answers;
  final Duration after;
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

class CallController extends ChangeNotifier {
  CallController({
    required this.me,
    this.rings = const {},
    this.flags = const {},
    DateTime Function()? now,
    this.onRecord,
  }) : _now = now ?? DateTime.now;

  final Member me;

  /// How each member answers a ring. Anyone missing never picks up.
  final Map<String, RingBehaviour> rings;

  /// How each member is already set up when you arrive: muted, camera on.
  final Map<String, CallParticipant> flags;

  final DateTime Function() _now;

  /// Called whenever a DM call leaves a line in its timeline.
  final void Function(Channel chat, CallRecord record)? onRecord;

  static const connectDelay = Duration(milliseconds: 700);
  static const ringTimeout = Duration(seconds: 30);
  static const _speakingEvery = Duration(milliseconds: 1800);

  CallSession? _session;
  IncomingRing? _incoming;
  final _timers = <Timer>[];
  Timer? _incomingTimer;
  Timer? _speaking;
  var _speakerTurn = 0;

  CallSession? get session => _session;
  IncomingRing? get incoming => _incoming;

  // Your own state. It outlives any one call, like the account panel's
  // mute and deafen do.
  bool muted = false;
  bool deafened = false;
  bool camera = false;
  bool frontCamera = true;
  AudioRoute route = AudioRoute.speaker;
  String micDevice = 'MacBook Pro Microphone';
  String cameraDevice = 'FaceTime HD Camera';

  /// What you are sharing, if anything. Desktop only.
  String? sharing;

  String? _pinned;
  final _shareOrder = <String>[];
  final _volumes = <String, double>{};

  // Mock-only switches, set from the debug menu.
  bool encrypted = true;
  bool micBlocked = false;
  bool cameraBlocked = false;
  bool _failNext = false;

  /// Whether you are in a call right now: connecting, ringing out or live.
  bool get inCall => _session != null && !_session!.over;

  String? get pinned => _pinned;

  /// Whose tile fills the stage: a pinned tile, else the newest screen share.
  String? get spotlight {
    if (_pinned != null) return _pinned;
    return _shareOrder.isEmpty ? null : _shareOrder.last;
  }

  double volumeOf(String id) => _volumes[id] ?? 1;

  // ── Joining and leaving ──────────────────────────────────────────────

  void joinVoice(Channel channel, {required String spaceName}) {
    _reset();
    _session = CallSession(
      target: channel,
      spaceName: spaceName,
      phase: CallPhase.connecting,
      participants: [for (final m in channel.occupants) _arrive(m)],
    );
    _connect();
    notifyListeners();
  }

  /// Rings everyone in a direct chat. [video] starts with your camera on.
  void startDirect(Channel chat, {bool video = false}) {
    _reset();
    camera = video && !cameraBlocked;
    _session = CallSession(
      target: chat,
      phase: CallPhase.ringing,
      participants: [
        for (final m in chat.members)
          CallParticipant(m, ring: RingState.ringing),
      ],
    );
    _ring();
    notifyListeners();
  }

  void callAgain() {
    final session = _session;
    if (session == null) return;
    startDirect(session.target, video: camera);
  }

  /// Cancels a ring or hangs up. Leaves any record the call is owed.
  void leave() {
    final session = _session;
    if (session == null) return;
    if (session.direct && !session.over) {
      if (session.startedAt != null) {
        _record(EndedCall(_now().difference(session.startedAt!)));
      } else {
        _recordUnanswered(session);
      }
    }
    _reset();
    // Your camera goes off with the call; mic and deafen are yours to keep,
    // like the account panel's.
    camera = false;
    notifyListeners();
  }

  /// Dismisses an ended call's panel.
  void close() => leave();

  void retry() {
    final session = _session;
    if (session == null || session.phase != CallPhase.failed) return;
    _session = session.copyWith(phase: CallPhase.connecting);
    _connect();
    notifyListeners();
  }

  // ── Incoming ─────────────────────────────────────────────────────────

  void receive(Channel chat, {required Member from}) {
    _incomingTimer?.cancel();
    _incoming = IncomingRing(chat, from);
    _incomingTimer = Timer(ringTimeout, () {
      _incoming = null;
      onRecord?.call(chat, const MissedCall());
      notifyListeners();
    });
    notifyListeners();
  }

  void accept() {
    final ring = _incoming;
    if (ring == null) return;
    _stopIncoming();
    _reset();
    _session = CallSession(
      target: ring.chat,
      phase: CallPhase.connecting,
      participants: [
        for (final m in ring.chat.members)
          m.id == ring.caller.id
              ? _arrive(m, ring: RingState.joined)
              : CallParticipant(m, ring: RingState.ringing),
      ],
    );
    _connect();
    notifyListeners();
  }

  void decline() {
    _stopIncoming();
    notifyListeners();
  }

  void _stopIncoming() {
    _incomingTimer?.cancel();
    _incomingTimer = null;
    _incoming = null;
  }

  // ── Your controls ────────────────────────────────────────────────────

  /// Unmuting while deafened undeafens too: you cannot talk to people you
  /// cannot hear.
  void toggleMute() {
    if (micBlocked) return;
    muted = !muted;
    if (!muted) deafened = false;
    notifyListeners();
  }

  /// Deafening implies muting; coming back restores you to unmuted rather
  /// than leaving you silently muted for a reason you never chose.
  void toggleDeafen() {
    deafened = !deafened;
    muted = deafened;
    notifyListeners();
  }

  void toggleCamera() {
    if (cameraBlocked) return;
    camera = !camera;
    notifyListeners();
  }

  void flipCamera() {
    frontCamera = !frontCamera;
    notifyListeners();
  }

  void setRoute(AudioRoute value) {
    route = value;
    notifyListeners();
  }

  void setMicDevice(String value) {
    micDevice = value;
    notifyListeners();
  }

  void setCameraDevice(String value) {
    cameraDevice = value;
    notifyListeners();
  }

  void startScreenShare(String source) {
    sharing = source;
    _shareOrder
      ..remove(me.id)
      ..add(me.id);
    notifyListeners();
  }

  void stopScreenShare() {
    sharing = null;
    _shareOrder.remove(me.id);
    notifyListeners();
  }

  /// Pins [id] to the spotlight, or with null goes back to the automatic
  /// choice.
  void pin(String? id) {
    _pinned = id;
    notifyListeners();
  }

  void setVolume(String id, double value) {
    _volumes[id] = value;
    notifyListeners();
  }

  // ── Debug switches ───────────────────────────────────────────────────

  void failNextConnection() => _failNext = true;

  void toggleReconnecting() {
    final session = _session;
    if (session == null) return;
    final phase = switch (session.phase) {
      CallPhase.live => CallPhase.reconnecting,
      CallPhase.reconnecting => CallPhase.live,
      _ => null,
    };
    if (phase == null) return;
    _session = session.copyWith(phase: phase);
    notifyListeners();
  }

  void toggleEncryption() {
    encrypted = !encrypted;
    notifyListeners();
  }

  void toggleMicBlocked() {
    micBlocked = !micBlocked;
    if (micBlocked) muted = true;
    notifyListeners();
  }

  void toggleCameraBlocked() {
    cameraBlocked = !cameraBlocked;
    if (cameraBlocked) camera = false;
    notifyListeners();
  }

  /// Someone else starts or stops sharing their screen.
  void toggleRemoteShare(String id) {
    final session = _session;
    final participant = session?.find(id);
    if (session == null || participant == null) return;
    final on = !participant.screen;
    _replace(id, participant.copyWith(screen: on));
    _shareOrder.remove(id);
    if (on) _shareOrder.add(id);
    notifyListeners();
  }

  // ── Internals ────────────────────────────────────────────────────────

  CallParticipant _arrive(Member m, {RingState? ring}) {
    final f = flags[m.id];
    return CallParticipant(
      m,
      muted: f?.muted ?? false,
      deafened: f?.deafened ?? false,
      camera: f?.camera ?? false,
      ring: ring,
    );
  }

  void _connect() {
    _after(connectDelay, () {
      final session = _session;
      if (session == null) return;
      if (_failNext) {
        _failNext = false;
        _session = session.copyWith(phase: CallPhase.failed);
      } else {
        _goLive();
      }
      notifyListeners();
    });
  }

  void _goLive() {
    _session = _session!.copyWith(
      phase: CallPhase.live,
      startedAt: _session!.startedAt ?? _now(),
    );
    _speaking?.cancel();
    _speaking = Timer.periodic(_speakingEvery, (_) => _passTheMic());
  }

  /// Moves the speaking ring around the unmuted people in the call, so the
  /// mock looks like a conversation.
  void _passTheMic() {
    final session = _session;
    if (session == null) return;
    final talkers = session.participants
        .where((p) => p.present && !p.muted)
        .toList();
    if (talkers.isEmpty) return;
    final speaker = talkers[_speakerTurn++ % talkers.length].member.id;
    _session = session.copyWith(
      participants: [
        for (final p in session.participants)
          p.copyWith(speaking: p.member.id == speaker),
      ],
    );
    notifyListeners();
  }

  void _ring() {
    final session = _session!;
    for (final p in session.participants) {
      final behaviour = rings[p.member.id];
      if (behaviour == null) continue;
      _after(behaviour.after, () => _respond(p.member, behaviour.answers));
    }
    _after(ringTimeout, _timeOut);
  }

  void _respond(Member member, bool answers) {
    final session = _session;
    if (session == null || session.over) return;
    if (session.find(member.id)?.ring != RingState.ringing) return;
    _replace(
      member.id,
      answers
          ? _arrive(member, ring: RingState.joined)
          : CallParticipant(member, ring: RingState.declined),
    );
    if (answers && session.phase == CallPhase.ringing) {
      _goLive();
    } else if (!answers && session.target.members.length == 1) {
      // A 1:1 decline ends the call; in a group it is one tile of many.
      _session = _session!.copyWith(phase: CallPhase.declined);
      _cancelTimers();
      _recordUnanswered(session);
    }
    _checkEveryoneOut();
    notifyListeners();
  }

  void _timeOut() {
    final session = _session;
    if (session == null) return;
    _session = session.copyWith(
      participants: [
        for (final p in session.participants)
          p.ring == RingState.ringing
              ? p.copyWith(ring: RingState.noAnswer)
              : p,
      ],
    );
    if (session.phase == CallPhase.ringing) {
      _session = _session!.copyWith(phase: CallPhase.unanswered);
      _recordUnanswered(session);
    }
    notifyListeners();
  }

  /// A group where everyone has declined ends early, without waiting out
  /// the ring.
  void _checkEveryoneOut() {
    final session = _session!;
    if (session.phase != CallPhase.ringing) return;
    if (session.participants.every((p) => p.ring == RingState.declined)) {
      _session = session.copyWith(phase: CallPhase.unanswered);
      _cancelTimers();
      _recordUnanswered(session);
    }
  }

  void _recordUnanswered(CallSession session) => _record(
    session.target.members.length > 1
        ? const NoOneAnswered()
        : const MissedCall(),
  );

  void _record(CallRecord record) => onRecord?.call(_session!.target, record);

  void _replace(String id, CallParticipant with_) {
    final session = _session!;
    _session = session.copyWith(
      participants: [
        for (final p in session.participants) p.member.id == id ? with_ : p,
      ],
    );
  }

  void _after(Duration delay, VoidCallback run) {
    _timers.add(Timer(delay, run));
  }

  void _cancelTimers() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    _speaking?.cancel();
    _speaking = null;
  }

  void _reset() {
    _cancelTimers();
    _session = null;
    _pinned = null;
    _shareOrder.clear();
    sharing = null;
  }

  @override
  void dispose() {
    _cancelTimers();
    _incomingTimer?.cancel();
    super.dispose();
  }
}
