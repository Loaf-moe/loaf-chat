/// One emoji verification with another of your devices, on the SDK's
/// `KeyVerification`: a request this device sent to all your others, or one
/// that arrived from a new sign-in.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';

import '../ui/verify/verifier.dart';
import '../ui/verify/verify_state.dart';

class MatrixDeviceVerification extends ChangeNotifier
    implements DeviceVerification {
  /// Asks every other device of yours; the first to accept answers.
  MatrixDeviceVerification.request(Client client) {
    unawaited(_request(client));
  }

  /// One the SDK already has: a request another of your devices sent.
  MatrixDeviceVerification(KeyVerification verification) {
    _attach(verification);
  }

  KeyVerification? _verification;

  /// Failed before, or outside, the SDK's own states: the request never
  /// went out, or an answer to it did not reach the server.
  var _failed = false;
  var _disposed = false;

  /// The answers already sent: each goes once, so a second tap while the
  /// first is in flight (the phase moves only once it lands) sends nothing.
  final _answered = <_Answer>{};

  Future<void> _request(Client client) async {
    try {
      final keys = client.userDeviceKeys[client.userID];
      if (keys == null) throw StateError('this account has no device keys');
      final verification = await keys.startVerification();
      if (_disposed) {
        // Put away while the request was going out: withdraw it.
        await verification.cancel('m.user');
        return;
      }
      _attach(verification);
    } on Object catch (e, s) {
      Logs().w('[loaf] a verification request did not go out', e, s);
      _fail();
    }
  }

  void _attach(KeyVerification verification) {
    _verification = verification;
    verification.onUpdate = _changed;
    _changed();
  }

  void _changed() {
    if (_disposed) return;
    final v = _verification;
    if (v != null && v.canceled) {
      Logs().i(
        '[loaf] verification ended: ${v.canceledCode} ${v.canceledReason}',
      );
    }
    notifyListeners();
  }

  void _fail() {
    _failed = true;
    _changed();
  }

  @override
  DevicePhase get phase {
    final v = _verification;
    if (_failed || (v != null && v.canceled)) return DevicePhase.cancelled;
    if (v == null) return DevicePhase.waiting;
    return switch (v.state) {
      KeyVerificationState.askAccept ||
      KeyVerificationState.askChoice ||
      KeyVerificationState.waitingAccept => DevicePhase.waiting,
      KeyVerificationState.askSas => DevicePhase.emoji,
      KeyVerificationState.waitingSas => DevicePhase.waitingForOther,
      KeyVerificationState.askSSSS => DevicePhase.needsKey,
      KeyVerificationState.done => DevicePhase.done,
      // QR is never offered, so its states only arrive broken.
      KeyVerificationState.showQRSuccess ||
      KeyVerificationState.confirmQRScan ||
      KeyVerificationState.error => DevicePhase.cancelled,
    };
  }

  @override
  List<SasEmoji> get emoji => phase == DevicePhase.emoji
      ? [for (final e in _verification!.sasEmojis) SasEmoji(e.emoji, e.name)]
      : const [];

  /// Runs one answer; one that fails to reach the server ends the
  /// verification, since the other side is left waiting on it.
  void _answer(
    Future<void> Function(KeyVerification v) answer, {
    _Answer? once,
  }) {
    final v = _verification;
    if (v == null || v.isDone) return;
    if (once != null && !_answered.add(once)) return;
    unawaited(
      answer(v).catchError((Object e, StackTrace s) {
        Logs().w('[loaf] a verification answer did not go out', e, s);
        _fail();
      }),
    );
  }

  @override
  void accept() => _answer((v) => v.acceptVerification(), once: _Answer.accept);

  @override
  void match() => _answer((v) => v.acceptSas(), once: _Answer.match);

  @override
  void mismatch() => _answer((v) => v.rejectSas(), once: _Answer.mismatch);

  @override
  Future<UnlockResult> unlock(String keyOrPassphrase) async {
    final v = _verification;
    if (v == null) return UnlockResult.unreachable;
    try {
      await v.openSSSS(keyOrPassphrase: keyOrPassphrase);
      return UnlockResult.unlocked;
    } on InvalidPassphraseException {
      return UnlockResult.wrongKey;
    } on Object catch (e, s) {
      Logs().w('[loaf] unlocking to vouch failed', e, s);
      return UnlockResult.unreachable;
    }
  }

  @override
  void cancel() => _answer((v) => v.cancel('m.user'));

  @override
  void dispose() {
    _disposed = true;
    _verification?.onUpdate = null;
    super.dispose();
  }
}

enum _Answer { accept, match, mismatch }
