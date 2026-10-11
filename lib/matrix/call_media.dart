/// A call's media, as [MatrixCalls] needs it: somewhere to connect, a
/// microphone to send, and who else is there.
library;

import 'package:flutter/foundation.dart';

import '../ui/call/calls.dart' show CallQuality;

export '../ui/call/calls.dart' show CallQuality;

/// Whether a connection is carrying the call.
enum CallLink {
  connected,

  /// Dropped, and trying to come back by itself.
  reconnecting,

  /// Gone for good. Only a new connection brings the call back.
  lost,
}

/// Someone else's device in the call.
@immutable
class CallPeer {
  const CallPeer({required this.muted, required this.speaking});

  /// Sending no microphone.
  final bool muted;
  final bool speaking;

  @override
  bool operator ==(Object other) =>
      other is CallPeer && other.muted == muted && other.speaking == speaking;

  @override
  int get hashCode => Object.hash(muted, speaking);
}

/// The media server could not be reached, or would not let this device in.
class CallMediaUnreachable implements Exception {
  const CallMediaUnreachable(this.detail);

  final String detail;

  @override
  String toString() => 'CallMediaUnreachable: $detail';
}

/// No microphone could be opened.
class MicrophoneUnavailable implements Exception {
  const MicrophoneUnavailable(this.detail);

  final String detail;

  @override
  String toString() => 'MicrophoneUnavailable: $detail';
}

/// The speaker chosen could not be played on.
class SpeakerUnavailable implements Exception {
  const SpeakerUnavailable(this.detail);

  final String detail;

  @override
  String toString() => 'SpeakerUnavailable: $detail';
}

abstract interface class CallMedia {
  /// Joins the call at [url] with [jwt], sending nothing yet. Throws
  /// [CallMediaUnreachable].
  Future<CallConnection> connect(Uri url, String jwt);
}

/// One device's place in a call. Notifies when anything it reports changes.
abstract interface class CallConnection implements Listenable {
  CallLink get link;

  /// How well this device's own link is doing, as the media server rates it.
  CallQuality get quality;

  /// Everyone else's devices, by their identity in the call.
  Map<String, CallPeer> get peers;

  /// Starts or stops sending the microphone. Throws
  /// [MicrophoneUnavailable] when none opens.
  Future<void> setMicrophone(bool on);

  /// Stops or resumes playing everyone else.
  Future<void> setDeafened(bool deafened);

  /// The device the microphone is taken from, by its id. Null is the
  /// system's default.
  String? get microphone;

  /// The device everyone else is played on, by its id. Null is the system's
  /// default.
  String? get speaker;

  /// An event whenever a microphone or a speaker may have come or gone.
  Stream<void> get deviceChanges;

  /// Takes the microphone from the device with [id] from now on, or from
  /// the system's default: for null, and for a device the machine does not
  /// have as of this call. Throws [MicrophoneUnavailable] when one being
  /// sent does not reopen; it is then no longer sent.
  Future<void> setMicrophoneDevice(String? id);

  /// Plays everyone else on the device with [id] from now on, or on the
  /// system's default: for null, and for a device the machine does not
  /// have as of this call. Throws [SpeakerUnavailable], playing on as
  /// before.
  Future<void> setSpeakerDevice(String? id);

  Future<void> disconnect();
}
