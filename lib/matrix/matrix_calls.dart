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
import '../ui/settings/voice_settings.dart';
import 'call_access.dart';
import 'call_media.dart';
import 'call_members.dart';
import 'call_membership.dart';
import 'call_silence.dart';

/// Someone in a room's call, and the devices they are in it on.
typedef CallOccupant = ({Member member, Set<String> devices});

class MatrixCalls extends ChangeNotifier implements Calls {
  MatrixCalls(
    this._client,
    this._media, {
    required this._occupants,
    required this._me,
    this._voice,
    this._voiceApplying,
    DateTime Function()? now,
    this._timings = const CallMembershipTimings(),
    this._reconnectDelays = defaultReconnectDelays,
  }) : _now = now ?? DateTime.now {
    _sync = _client.onSync.stream.listen((_) => _onSync());
    _voice?.addListener(_changedVoice);
    _clearLeftBehind();
  }

  final Client _client;
  final CallMedia _media;
  final List<CallOccupant> Function(Room room) _occupants;
  final Member Function() _me;

  /// The microphone, its processing and the speaker chosen. Null: the
  /// system's default devices, and every kind of processing.
  final ValueListenable<VoiceSettings>? _voice;

  /// Told true while a call takes those up, which can take seconds.
  final ValueNotifier<bool>? _voiceApplying;
  final DateTime Function() _now;
  final CallMembershipTimings _timings;

  /// How long a call waits before each of its own tries at media it has
  /// lost; the last one repeats.
  final List<Duration> _reconnectDelays;
  late final StreamSubscription<SyncUpdate> _sync;

  static const defaultReconnectDelays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 15),
  ];

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

  /// The joins that have not finished, or finished undoing themselves.
  final _joins = <Future<void>>{};

  /// The memberships [_clearLeftBehind] has dealt with, by event id.
  final _cleared = <String>{};

  /// The rooms whose call is being left, until the server has been told.
  final _leaving = <String>{};

  /// What you chose yourself. A moderator may have chosen more: see
  /// [silenced].
  var _muted = false;
  var _deafened = false;

  @override
  bool get muted => _muted || silenced != null;

  @override
  bool get deafened => _deafened || silenced == CallSilence.deafened;

  @override
  CallSilence? get silenced => _live?.silenced;
  @override
  bool micBlocked = false;

  @override
  bool switchingAudio = false;

  @override
  Member get me => _me();

  @override
  Set<CallFeature> get features => const {};

  @override
  CallQuality get quality => _live?.connection?.quality ?? CallQuality.unknown;

  @override
  bool get speaking =>
      // Muted is not heard, whatever the media has yet to notice.
      !muted && (_live?.connection?.speaking ?? false);

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
      _start(channel, spaceName);

  @override
  void retry() {
    final session = _session;
    if (session == null ||
        (session.phase != CallPhase.failed &&
            session.phase != CallPhase.hungUp)) {
      return;
    }
    _start(session.target, session.spaceName ?? '');
  }

  void _start(Channel channel, String spaceName) {
    final join = _join(channel, spaceName);
    _joins.add(join);
    unawaited(join.whenComplete(() => _joins.remove(join)));
  }

  @override
  Future<void> leave() async {
    _attempt++;
    final live = _detach();
    final joins = _joins.toList();
    _session = null;
    _pinned = null;
    _notify();
    await _end(live);
    // A join that was under way has now been overtaken, and undoes itself.
    await Future.wait(joins);
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
      participants: room == null
          ? const []
          : _participants(room, _occupants(room), null),
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
    } on Exception catch (e, s) {
      // The call server, the media server or the homeserver said no, or
      // could not be reached: the session ends as failed, below.
      Logs().w("[loaf] couldn't join the call in ${room.id}", e, s);
    } finally {
      if (!joined || attempt != _attempt) {
        await membership?.leave();
        membership?.dispose();
        await connection?.disconnect();
        if (attempt == _attempt) _phase(CallPhase.failed);
      }
    }
    if (!joined || attempt != _attempt) return;

    final live = _live = _Live(room, membership!)
      ..voice = _voice?.value
      ..silenced = _silences(room)[_client.userID];
    _session = _session!.copyWith(startedAt: _now());
    _carry(live, connection!);
  }

  /// Puts [connection] in [live]'s hands: the call is live on it from now.
  void _carry(_Live live, CallConnection connection) {
    live.connection = connection;
    live.volumes.clear();
    connection.addListener(_onMedia);
    live.deviceChanges = connection.deviceChanges.listen((_) {
      if (identical(live, _live)) _applyAudio(live, voice: true);
    });
    _session = _session?.copyWith(phase: CallPhase.live);
    _applyAudio(live, voice: true);
    _refresh(live);
  }

  /// Takes the live call out of this object's hands, for [_end] to finish.
  _Live? _detach() {
    final live = _live;
    _live = null;
    live?.connection?.removeListener(_onMedia);
    unawaited(live?.deviceChanges?.cancel());
    return live;
  }

  /// Empties the membership first, so nobody is shown someone they cannot
  /// hear, then drops the media.
  Future<void> _end(_Live? live) async {
    if (live == null) return;
    // The leave empties this one itself; memory shows it until the echo.
    final own = live.room.getState(callMemberType, live.membership.stateKey);
    if (own is Event) _cleared.add(own.eventId);
    _leaving.add(live.room.id);
    await live.membership.leave();
    _leaving.remove(live.room.id);
    live.membership.dispose();
    await live.connection?.disconnect();
  }

  /// Empties any membership of this device's in a call it is not in: what a
  /// run that died without leaving left behind. Nothing else would until
  /// the membership ran out.
  void _clearLeftBehind() {
    final current = inCall ? _session!.target.id : null;
    for (final room in _client.rooms) {
      if (room.membership != Membership.join ||
          room.id == current ||
          _leaving.contains(room.id)) {
        continue;
      }
      final key = callMemberStateKey(_client, room);
      final own = room.getState(callMemberType, key);
      if (own is! Event || !own.content.containsKey('application')) continue;
      if (_cleared.add(own.eventId)) unawaited(_empty(room, key, own.eventId));
    }
  }

  Future<void> _empty(Room room, String key, String eventId) async {
    try {
      await _client.setRoomStateWithKey(room.id, callMemberType, key, const {});
    } on MatrixException catch (e, s) {
      if (e.error == MatrixError.M_LIMIT_EXCEEDED) {
        _cleared.remove(eventId);
        return;
      }
      // Refused: asking again would be refused again.
      Logs().w("[loaf] couldn't empty a call membership left behind", e, s);
    } on Exception {
      // A dropped connection, or a 5xx, which the SDK throws bare. As with
      // being told to slow down, the next sync tries again.
      _cleared.remove(eventId);
    }
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
    _clearLeftBehind();
    final live = _live;
    if (live == null) return;
    // A room you have left is dropped from the client, not updated.
    if (_client.getRoomById(live.room.id)?.membership != Membership.join) {
      unawaited(leave());
      return;
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
        live.membership.join().onError<Exception>((e, s) {
          Logs().w("[loaf] couldn't say again that this device is here", e, s);
          return _lost(attempt);
        }),
      );
    }
    final silenced = _silences(live.room)[_client.userID];
    if (silenced != live.silenced) {
      live.silenced = silenced;
      _applyAudio(live);
    }
    final hungUp = _hangUps(live.room)[_client.userID];
    final created = live.membership.created;
    if (hungUp != null &&
        created != null &&
        hungUp.millisecondsSinceEpoch > created) {
      unawaited(_hungUp(_attempt));
      return;
    }
    _refresh(live);
  }

  /// Someone hung up for you: out of the call, with the end shown.
  Future<void> _hungUp(int attempt) async {
    if (attempt != _attempt) return;
    _attempt++;
    final live = _detach();
    _phase(CallPhase.hungUp);
    await _end(live);
  }

  /// Whom someone has muted or deafened for everyone in [room], by user id.
  Map<String, CallSilence> _silences(Room room) =>
      callSilences(callModeration(room));

  /// Whom someone has hung up for in [room], and when.
  Map<String, DateTime> _hangUps(Room room) =>
      callHangUps(callModeration(room));

  void _onMedia() {
    final live = _live;
    final connection = live?.connection;
    if (live == null || connection == null) return;
    switch (connection.link) {
      case CallLink.ended:
        unawaited(_lost(_attempt));
        return;
      case CallLink.lost:
        unawaited(_reconnect(live, connection, _attempt));
        return;
      case CallLink.reconnecting:
        _session = _session?.copyWith(phase: CallPhase.reconnecting);
      case CallLink.connected:
        _session = _session?.copyWith(phase: CallPhase.live);
    }
    _refresh(live);
  }

  /// The media gave up on [dead]: drops it and connects anew, over and
  /// over, until the call is live again or you have moved on. The
  /// membership stays, so everyone else still sees you in the call.
  Future<void> _reconnect(_Live live, CallConnection dead, int attempt) async {
    dead.removeListener(_onMedia);
    unawaited(live.deviceChanges?.cancel());
    live.connection = null;
    live.deviceChanges = null;
    _phase(CallPhase.reconnecting);
    await dead.disconnect();
    for (var tries = 0; ; tries++) {
      final delay = tries < _reconnectDelays.length
          ? _reconnectDelays[tries]
          : _reconnectDelays.last;
      await Future<void>.delayed(delay);
      if (attempt != _attempt) return;
      try {
        final server = await callServer(_client);
        final access = await sfuAccess(_client, server, live.room.id);
        if (attempt != _attempt) return;
        final connection = await _media.connect(access.url, access.jwt);
        if (attempt != _attempt) {
          await connection.disconnect();
          return;
        }
        _carry(live, connection);
        Logs().w("[loaf] the call's media is back");
        return;
      } on Exception catch (e, s) {
        Logs().w("[loaf] couldn't connect the call's media again", e, s);
      }
    }
  }

  void _refresh(_Live live) {
    final occupants = _occupants(live.room);
    _session = _session?.copyWith(
      participants: _participants(live.room, occupants, live.connection),
    );
    _notify();
    _syncVolumes(live, occupants);
  }

  /// Tells [live]'s media how loud to play each device of everyone else
  /// among [occupants], where that is not what it was last told.
  void _syncVolumes(_Live live, List<CallOccupant> occupants) {
    final connection = live.connection;
    if (connection == null) return;
    final volumes = _voice?.value.volumes ?? const <String, double>{};
    for (final occupant in occupants) {
      if (occupant.member.id == _client.userID) continue;
      final volume = volumes[occupant.member.id] ?? 1;
      for (final device in occupant.devices) {
        final identity = '${occupant.member.id}:$device';
        if ((live.volumes[identity] ?? 1) == volume) continue;
        live.volumes[identity] = volume;
        unawaited(connection.setVolume(identity, volume));
      }
    }
  }

  /// Everyone else among [occupants]. Someone is speaking if any of their
  /// devices is, and muted unless one of them sends a microphone.
  List<CallParticipant> _participants(
    Room room,
    List<CallOccupant> occupants,
    CallConnection? connection,
  ) {
    final peers = connection?.peers ?? const <String, CallPeer>{};
    final silences = _silences(room);
    return [
      for (final occupant in occupants)
        if (occupant.member.id != _client.userID)
          () {
            final theirs = [
              for (final device in occupant.devices)
                ?peers['${occupant.member.id}:$device'],
            ];
            return CallParticipant(
              occupant.member,
              muted: theirs.every((peer) => peer.muted),
              silenced: silences[occupant.member.id],
              speaking: theirs.any((peer) => peer.speaking),
            );
          }(),
    ];
  }

  // ── Your own controls ────────────────────────────────────────────────

  @override
  void toggleMute() {
    if (micBlocked) return;
    // A moderator's mute is not yours to undo.
    if (silenced != null) return;
    _muted = !_muted;
    if (!_muted) _deafened = false;
    _changedAudio();
  }

  @override
  void toggleDeafen() {
    if (silenced == CallSilence.deafened) return;
    _deafened = !_deafened;
    _muted = _deafened;
    _changedAudio();
  }

  void _changedAudio() {
    _notify();
    final live = _live;
    if (live != null) _applyAudio(live);
  }

  /// Another device, other processing or someone's volume was chosen.
  void _changedVoice() {
    final live = _live;
    if (live == null) return;
    final before = live.voice;
    final now = live.voice = _voice?.value;
    // Someone's volume alone leaves the microphone and the speaker be.
    if (before?.copyWith(volumes: const {}) !=
        now?.copyWith(volumes: const {})) {
      _applyAudio(live, voice: true);
    }
    _syncVolumes(live, _occupants(live.room));
  }

  /// Brings what [live] sends and plays in line with [muted] and
  /// [deafened] as they stand when its turn comes; with [voice], first
  /// the microphone, its processing and the speaker in line with those
  /// chosen.
  void _applyAudio(_Live live, {bool voice = false}) {
    final before = _audioApplied;
    final applied = Completer<void>();
    _audioApplied = applied.future;
    unawaited(() async {
      await before;
      try {
        final connection = live.connection;
        if (!identical(live, _live) || connection == null) return;
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
      } finally {
        applied.complete();
      }
    }());
  }

  void _switching(bool on) {
    switchingAudio = on;
    _voiceApplying?.value = on;
    _notify();
  }

  Future<void> _applyVoice(CallConnection connection) async {
    final voice = _voice?.value;
    try {
      await connection.setSpeakerDevice(voice?.speaker?.id);
    } on SpeakerUnavailable catch (e, s) {
      // The call plays on where it did.
      Logs().w("[loaf] couldn't play the call on the speaker chosen", e, s);
    }
    if (micBlocked) {
      // Another microphone may open where the last did not. Still muted:
      // unmuting is yours to do.
      micBlocked = false;
      _notify();
    }
    await connection.setMicrophoneDevice(voice?.microphone?.id);
    await connection.setMicrophoneProcessing(
      voice == null
          ? const MicrophoneProcessing()
          : MicrophoneProcessing(
              echoCancellation: voice.echoCancellation,
              noiseSuppression: voice.noiseSuppression,
              automaticGain: voice.automaticGain,
              highPassFilter: voice.highPassFilter,
            ),
    );
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
    _voice?.removeListener(_changedVoice);
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
  String get cameraDevice => '';
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
  void setCameraDevice(String value) => _lacks('devices');

  Never _lacks(String feature) =>
      throw UnsupportedError('MatrixCalls has no $feature');
}

/// The call this device is in.
class _Live {
  _Live(this.room, this.membership);

  final Room room;
  final OwnCallMembership membership;

  /// The media carrying the call; null while a new connection is sought.
  CallConnection? connection;
  StreamSubscription<void>? deviceChanges;

  /// The settings as of the last change this call looked at.
  VoiceSettings? voice;

  /// What a moderator has put on you here, as of the last sync.
  CallSilence? silenced;

  /// How loud the media was last told to play each device, by identity.
  /// Absent: never told, so as loud as sent.
  final volumes = <String, double>{};

  /// Whether a sync has shown this device's membership since it was
  /// written. Until then its absence means nothing.
  var echoed = false;
}
