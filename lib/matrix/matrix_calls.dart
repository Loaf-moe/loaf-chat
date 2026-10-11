/// Voice channels for real: the call server's access, this device's
/// membership in the room, and the media, behind the one [Calls] the shell
/// and the call widgets read.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
// The SDK's own call module has classes of the same names.
import 'package:matrix/matrix.dart' hide CallParticipant, CallSession;

import '../ui/call/calls.dart';
import '../ui/model/models.dart';
import 'call_access.dart';
import 'call_media.dart';
import 'call_members.dart';
import 'call_membership.dart';

/// Someone in a room's call, and the devices they are in it on.
typedef CallOccupant = ({Member member, Set<String> devices});

class MatrixCalls extends ChangeNotifier implements Calls {
  MatrixCalls(
    this._client,
    this._media, {
    required this._occupants,
    required this._me,
    DateTime Function()? now,
    this._timings = const CallMembershipTimings(),
  }) : _now = now ?? DateTime.now {
    _sync = _client.onSync.stream.listen((_) => _onSync());
  }

  final Client _client;
  final CallMedia _media;
  final List<CallOccupant> Function(Room room) _occupants;
  final Member Function() _me;
  final DateTime Function() _now;
  final CallMembershipTimings _timings;
  late final StreamSubscription<SyncUpdate> _sync;

  CallSession? _session;
  _Live? _live;

  /// Counts joins and leaves, so a step that finishes after you have moved
  /// on can tell.
  var _attempt = 0;

  /// Done when the last change to what is sent and heard has been applied,
  /// so changes apply in order. Never fails: a change that throws is the
  /// zone's to report, and the next one still runs.
  Future<void> _audioApplied = Future.value();
  String? _pinned;
  var _disposed = false;

  @override
  bool muted = false;
  @override
  bool deafened = false;
  @override
  bool micBlocked = false;

  @override
  Member get me => _me();

  @override
  Set<CallFeature> get features => const {};

  @override
  CallSession? get session => _session;

  @override
  bool get inCall => _session != null && !_session!.over;

  @override
  String? get pinned => _pinned;

  @override
  String? get spotlight => _pinned;

  @override
  bool joinable(Channel channel) =>
      // Element Call encrypts a call's media in an encrypted room.
      !(_client.getRoomById(channel.id)?.encrypted ?? false);

  // ── Joining and leaving ──────────────────────────────────────────────

  @override
  void joinVoice(Channel channel, {required String spaceName}) =>
      unawaited(_join(channel, spaceName));

  @override
  void retry() {
    final session = _session;
    if (session?.phase != CallPhase.failed) return;
    unawaited(_join(session!.target, session.spaceName ?? ''));
  }

  @override
  void leave() {
    _attempt++;
    final live = _detach();
    _session = null;
    _pinned = null;
    _notify();
    unawaited(_end(live));
  }

  Future<void> _join(Channel channel, String spaceName) async {
    final attempt = ++_attempt;
    final before = _detach();
    final room = _client.getRoomById(channel.id);
    micBlocked = false;
    _pinned = null;
    _session = CallSession(
      target: channel,
      spaceName: spaceName,
      phase: CallPhase.connecting,
      participants: room == null ? const [] : _participants(room, null),
    );
    _notify();
    await _end(before);
    if (attempt != _attempt) return;
    if (room == null || room.membership != Membership.join || room.encrypted) {
      return _phase(CallPhase.failed);
    }

    CallConnection? connection;
    OwnCallMembership? membership;
    var joined = false;
    try {
      final server = await callServer(_client);
      final access = await sfuAccess(_client, server, room.id);
      if (attempt != _attempt) return;
      connection = await _media.connect(access.url, access.jwt);
      if (attempt != _attempt) return;
      membership = OwnCallMembership(
        _client,
        room,
        server,
        now: _now,
        timings: _timings,
        onLost: () => unawaited(_lost(attempt)),
      );
      // Last: until this is written nobody else sees you in the call.
      await membership.join();
      joined = true;
    } on Exception {
      // The call server, the media server or the homeserver said no, or
      // could not be reached: the session ends as failed, below.
    } finally {
      if (!joined || attempt != _attempt) {
        await membership?.leave();
        membership?.dispose();
        await connection?.disconnect();
        if (attempt == _attempt) _phase(CallPhase.failed);
      }
    }
    if (!joined || attempt != _attempt) return;

    final live = _live = _Live(room, connection!, membership!);
    connection.addListener(_onMedia);
    _session = _session!.copyWith(
      phase: CallPhase.live,
      startedAt: _now(),
      participants: _participants(room, connection),
    );
    _notify();
    _applyAudio(live);
  }

  /// Takes the live call out of this object's hands, for [_end] to finish.
  _Live? _detach() {
    final live = _live;
    _live = null;
    live?.connection.removeListener(_onMedia);
    return live;
  }

  /// Empties the membership first, so nobody is shown someone they cannot
  /// hear, then drops the media.
  Future<void> _end(_Live? live) async {
    if (live == null) return;
    await live.membership.leave();
    live.membership.dispose();
    await live.connection.disconnect();
  }

  /// The call cannot go on: the server stopped keeping the membership, or
  /// the media is gone for good.
  Future<void> _lost(int attempt) async {
    if (attempt != _attempt) return;
    _attempt++;
    final live = _detach();
    _phase(CallPhase.failed);
    await _end(live);
  }

  void _phase(CallPhase phase) {
    final session = _session;
    if (session == null) return;
    _session = session.copyWith(phase: phase);
    _notify();
  }

  // ── What the room and the media say ──────────────────────────────────

  void _onSync() {
    final live = _live;
    if (live == null) return;
    // A room you have left is dropped from the client, not updated.
    if (_client.getRoomById(live.room.id)?.membership != Membership.join) {
      return leave();
    }
    final own = live.room.getState(callMemberType, live.membership.stateKey);
    final present = own != null && own.content['application'] == 'm.call';
    if (present) {
      live.echoed = true;
    } else if (live.echoed) {
      // Emptied from elsewhere: say again that this device is here.
      live.echoed = false;
      final attempt = _attempt;
      unawaited(
        live.membership.join().onError<Exception>((_, _) => _lost(attempt)),
      );
    }
    _refresh(live);
  }

  void _onMedia() {
    final live = _live;
    if (live == null) return;
    switch (live.connection.link) {
      case CallLink.lost:
        unawaited(_lost(_attempt));
        return;
      case CallLink.reconnecting:
        _session = _session?.copyWith(phase: CallPhase.reconnecting);
      case CallLink.connected:
        _session = _session?.copyWith(phase: CallPhase.live);
    }
    _refresh(live);
  }

  void _refresh(_Live live) {
    _session = _session?.copyWith(
      participants: _participants(live.room, live.connection),
    );
    _notify();
  }

  /// Everyone else in [room]'s call. Someone is speaking if any of their
  /// devices is, and muted unless one of them sends a microphone.
  List<CallParticipant> _participants(Room room, CallConnection? connection) {
    final peers = connection?.peers ?? const <String, CallPeer>{};
    return [
      for (final occupant in _occupants(room))
        if (occupant.member.id != _client.userID)
          () {
            final theirs = [
              for (final device in occupant.devices)
                ?peers['${occupant.member.id}:$device'],
            ];
            return CallParticipant(
              occupant.member,
              muted: theirs.every((peer) => peer.muted),
              speaking: theirs.any((peer) => peer.speaking),
            );
          }(),
    ];
  }

  // ── Your own controls ────────────────────────────────────────────────

  @override
  void toggleMute() {
    if (micBlocked) return;
    muted = !muted;
    if (!muted) deafened = false;
    _changedAudio();
  }

  @override
  void toggleDeafen() {
    deafened = !deafened;
    muted = deafened;
    _changedAudio();
  }

  void _changedAudio() {
    _notify();
    final live = _live;
    if (live != null) _applyAudio(live);
  }

  /// Brings what [live] sends and plays in line with [muted] and
  /// [deafened] as they stand when its turn comes.
  void _applyAudio(_Live live) {
    final before = _audioApplied;
    final applied = Completer<void>();
    _audioApplied = applied.future;
    unawaited(() async {
      await before;
      try {
        if (!identical(live, _live)) return;
        await live.connection.setDeafened(deafened);
        await live.connection.setMicrophone(!muted);
      } on MicrophoneUnavailable {
        muted = true;
        micBlocked = true;
        _notify();
      } finally {
        applied.complete();
      }
    }());
  }

  @override
  void pin(String? id) {
    _pinned = id;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _attempt++;
    unawaited(_sync.cancel());
    unawaited(_end(_detach()));
    super.dispose();
  }

  // ── What voice alone does not have ───────────────────────────────────

  @override
  IncomingRing? get incoming => null;
  @override
  bool get encrypted => false;
  @override
  bool get camera => false;
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
  void startDirect(Channel chat, {bool video = false}) => _lacks('direct');
  @override
  void callAgain() => _lacks('direct');
  @override
  void accept() => _lacks('direct');
  @override
  void decline() => _lacks('direct');
  @override
  void toggleCamera() => _lacks('camera');
  @override
  void flipCamera() => _lacks('camera');
  @override
  void startScreenShare(String source) => _lacks('screenShare');
  @override
  void stopScreenShare() => _lacks('screenShare');
  @override
  void setRoute(AudioRoute value) => _lacks('audioRoute');
  @override
  void setMicDevice(String value) => _lacks('devices');
  @override
  void setCameraDevice(String value) => _lacks('devices');
  @override
  void setVolume(String id, double value) => _lacks('volume');

  Never _lacks(String feature) =>
      throw UnsupportedError('MatrixCalls has no $feature');
}

/// The call this device is in.
class _Live {
  _Live(this.room, this.connection, this.membership);

  final Room room;
  final CallConnection connection;
  final OwnCallMembership membership;

  /// Whether a sync has shown this device's membership since it was
  /// written. Until then its absence means nothing.
  var echoed = false;
}
