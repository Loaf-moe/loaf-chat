/// What a verification panel asks of the account's encryption: another
/// device's emoji, the recovery key, key backup and a new identity.
/// `MockVerifier` plays it on timers; `MatrixVerifier` runs it on the SDK.
/// See "Verifying a session" in the design spec.
library;

import 'package:flutter/foundation.dart';

import 'verify_state.dart';

/// What a recovery key or passphrase did.
enum UnlockResult {
  /// Secret storage opened, and this device signed itself.
  unlocked,

  /// It opens nothing.
  wrongKey,

  /// The server did not answer, so nothing is known about the key.
  unreachable,
}

/// Key backup coming back, counted in room keys.
@immutable
class RestoreProgress {
  const RestoreProgress(this.restored, this.total);

  final int restored;
  final int total;
}

/// Where one emoji verification is, from this end.
enum DevicePhase {
  /// Sent, or received and not yet answered.
  waiting,

  /// Both ends show [DeviceVerification.emoji].
  emoji,

  /// This end said they match; the other has not yet.
  waitingForOther,

  /// Vouching needs this device's own keys, which only the recovery key
  /// opens: [DeviceVerification.unlock] answers it.
  needsKey,

  done,

  /// A mismatch, a refusal, a timeout or a failure. Nothing was trusted.
  cancelled,
}

/// One emoji verification with another of your devices, either way round.
abstract interface class DeviceVerification implements Listenable {
  DevicePhase get phase;

  /// The 7 emoji, once [phase] is [DevicePhase.emoji].
  List<SasEmoji> get emoji;

  /// Incoming only: says yes to the request.
  void accept();

  void match();
  void mismatch();

  /// Answers [DevicePhase.needsKey].
  Future<UnlockResult> unlock(String keyOrPassphrase);

  /// Gives up: a refusal, a "that's not me", or the panel's back.
  void cancel();

  /// Stops listening. The verification itself is left to time out.
  void dispose();
}

enum AuthKind { password, sso }

/// The server asked who you are before new cross-signing keys go up.
abstract interface class AuthChallenge {
  AuthKind get kind;

  /// The last answer was turned away: a wrong password, or a browser visit
  /// that did not finish.
  bool get retry;

  void password(String password);

  /// SSO: opens the server's page in the browser. Again if asked.
  void openBrowser();

  /// SSO: the browser visit is done; asks the server to carry on.
  void browserFinished();

  /// Gives up before anything was changed.
  void cancel();
}

/// Thrown by [Verifier.createIdentity] when `wipe` is false but the account
/// already keeps a recovery key: setting up must never replace one by
/// accident. Only an explicit reset (`wipe: true`) may do that.
class RecoveryExists implements Exception {
  @override
  String toString() =>
      'RecoveryExists: this account already has a recovery '
      'key';
}

/// Thrown by [Verifier.createIdentity] when it failed after the new
/// identity's cross-signing keys were already on the server: the old
/// identity is gone, and the new one's recovery key never reached anyone.
/// Unlike any other failure, something did change; only another reset (which
/// makes a fresh key) is the way forward.
class IdentityIncomplete implements Exception {
  @override
  String toString() =>
      'IdentityIncomplete: the new identity went up without its recovery key';
}

abstract interface class Verifier {
  /// The names of your other devices, which could vouch for this one.
  List<String> get otherSessions;

  /// Asks your other devices to verify this one.
  DeviceVerification verifyWithDevice();

  Future<UnlockResult> unlock(String keyOrPassphrase);

  /// Pulls in key backup. Empty when there is no backup key on this device
  /// to restore with; an error part way leaves what was restored.
  Stream<RestoreProgress> restoreHistory();

  /// Makes a fresh identity and returns its recovery key, or null when
  /// [onAuth]'s challenge was cancelled. The server may ask for
  /// authentication once or more; each ask is handed to [onAuth].
  ///
  /// [wipe] is false for setting up recovery on a fresh account: it refuses,
  /// by throwing [RecoveryExists], an account that already keeps secret
  /// storage, cross-signing (a published master key counts) or a key backup.
  /// [wipe] is true for a reset,
  /// which replaces them.
  Future<String?> createIdentity({
    required bool wipe,
    required void Function(AuthChallenge challenge) onAuth,
  });
}
