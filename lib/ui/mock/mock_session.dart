/// Who is signed in and how far this device is trusted — mockup only.
/// Stands in for the SDK's login state and cross-signing status. Debug
/// levers move it where the fixtures never go on their own.
library;

import 'package:flutter/foundation.dart';

import '../auth/homeserver.dart';
import '../auth/loaf_session.dart';
import '../auth/sign_in_state.dart';
import '../verify/verifier.dart';
import 'accounts.dart';
import 'fixtures.dart';
import 'mock_homeserver.dart';
import 'mock_verifier.dart';

// Tests and the shell name these through the mock, as they always have.
export '../auth/loaf_session.dart'
    show AccountState, DeviceTrust, IncomingRequest;

class MockSession extends ChangeNotifier implements LoafSession {
  MockSession({
    this._account = AccountState.signedIn,
    this._trust = DeviceTrust.unverified,
  });

  /// The mock account's homeserver.
  static const server = 'loaf.moe';

  AccountState _account;
  DeviceTrust _trust;
  IncomingRequest? _incoming;
  var _failNext = false;

  @override
  AccountState get account => _account;
  @override
  DeviceTrust get trust => _trust;
  @override
  IncomingRequest? get incoming => _incoming;

  Member get me => currentUser;
  String get userId => '${currentUser.id}:$server';

  @override
  SoftLogout? get softLogout => _account == AccountState.softLoggedOut
      ? SoftLogout(member: me, userId: userId)
      : null;

  @override
  String get homeserverName => server;

  @override
  Homeserver newHomeserver() => MockHomeserver(consumeFailure: consumeFailure);

  /// What the verify panels run on.
  late final Verifier verifier = MockVerifier(
    otherSessions: mockOtherSessions(),
    identityExists: () => _trust != DeviceTrust.noIdentity,
    consumeFailure: consumeFailure,
  );

  /// The debug "fail the next connection" lever.
  void failNext() => _failNext = true;

  /// Spends the lever, if armed.
  @override
  bool consumeFailure() {
    final fail = _failNext;
    _failNext = false;
    return fail;
  }

  @override
  void signOut() {
    _account = AccountState.signedOut;
    // Signing out deletes the device, and its keys with it: the next one
    // starts unverified.
    _trust = DeviceTrust.unverified;
    _incoming = null;
    notifyListeners();
  }

  /// The server rejected the token with `soft_logout: true`.
  void expireSession() {
    if (_account != AccountState.signedIn) return;
    _account = AccountState.softLoggedOut;
    _incoming = null;
    notifyListeners();
  }

  /// Trust stays as it was left: unverified after a sign-out, and kept after
  /// a soft logout, whose keys never left.
  @override
  void signedIn() {
    _account = AccountState.signedIn;
    notifyListeners();
  }

  /// Becomes an account with no cross-signing identity, as a first sign-in
  /// through Kanidm would be.
  void useFreshAccount() {
    _trust = DeviceTrust.noIdentity;
    notifyListeners();
  }

  @override
  void markVerified() {
    _trust = DeviceTrust.verified;
    notifyListeners();
  }

  /// Another of your devices asks this one to vouch for it. Only a verified
  /// device is asked, so this one becomes one. One asked while another is
  /// being answered waits its turn, timing out if it has to.
  void receiveRequest() {
    _trust = DeviceTrust.verified;
    if (_incoming != null) {
      notifyListeners();
      return;
    }
    _incoming = IncomingRequest(
      device: mockNewDevice(),
      at: DateTime.now(),
      verification: MockDeviceVerification(),
    );
    notifyListeners();
  }

  /// Answered, refused or put away. Put away means ignored: the request
  /// times out on its own, as the protocol specifies.
  @override
  void clearIncoming() {
    final incoming = _incoming;
    if (incoming == null) return;
    incoming.verification.dispose();
    _incoming = null;
    notifyListeners();
  }
}
