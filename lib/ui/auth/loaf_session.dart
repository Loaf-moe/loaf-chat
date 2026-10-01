/// Who is signed in and how far this device is trusted: what the app shows
/// sign-in or the shell from, and which encryption notice the rail carries.
/// [MockSession] plays it on fixtures; `MatrixSession` reads it from the SDK.
library;

import 'package:flutter/foundation.dart';

import '../verify/verifier.dart';
import 'homeserver.dart';
import 'sign_in_state.dart';

enum AccountState { signedOut, softLoggedOut, signedIn }

/// How far this device is trusted, which decides the rail's encryption
/// notice.
enum DeviceTrust {
  /// The account has no cross-signing identity yet: set up recovery.
  noIdentity,

  /// There is an identity and this device is not signed by it: verify.
  unverified,

  verified,
}

/// Another of your devices asking this one to vouch for it, or someone
/// else asking to verify you.
@immutable
class IncomingRequest {
  const IncomingRequest({
    required this.device,
    required this.at,
    required this.verification,
    this.person,
  });

  /// Your own device's name. For someone else's request, theirs is not
  /// shown: it is them you verify, not one of their devices.
  final String device;
  final DateTime at;

  /// Someone else's request: their name. Null for one of your own devices.
  final String? person;

  /// The request itself, which the panel answers.
  final DeviceVerification verification;
}

abstract interface class LoafSession implements Listenable {
  AccountState get account;
  DeviceTrust get trust;
  SoftLogout? get softLogout;
  IncomingRequest? get incoming;

  /// What the verify panels run on.
  Verifier get verifier;

  /// The server the sign-in screen opens on.
  String get homeserverName;

  /// Answers for one visit to the sign-in screen, which closes it on leaving.
  Homeserver newHomeserver();

  /// The sign-in screen got a yes.
  void signedIn();

  void signOut();

  /// This device was just verified.
  void markVerified();

  /// The incoming verification request was answered or put away.
  void clearIncoming();

  /// The debug "fail the next connection" lever, for flows still mocked.
  bool consumeFailure();

  void dispose();
}
