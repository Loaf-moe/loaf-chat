/// A call's media, as [MatrixCalls] needs it: somewhere to connect, a
/// microphone to send, and who else is there.
library;

import 'package:flutter/foundation.dart';

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

abstract interface class CallMedia {
  /// Joins the call at [url] with [jwt], sending nothing yet. Throws
  /// [CallMediaUnreachable].
  Future<CallConnection> connect(Uri url, String jwt);
}

/// One device's place in a call. Notifies when anything it reports changes.
abstract interface class CallConnection implements Listenable {
  CallLink get link;

  /// Everyone else's devices, by their identity in the call.
  Map<String, CallPeer> get peers;

  /// Starts or stops sending the microphone. Throws
  /// [MicrophoneUnavailable] when none opens.
  Future<void> setMicrophone(bool on);

  /// Stops or resumes playing everyone else.
  Future<void> setDeafened(bool deafened);

  Future<void> disconnect();
}
