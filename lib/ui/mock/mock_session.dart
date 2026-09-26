/// Who is signed in and how far this device is trusted — mockup only.
/// Stands in for the SDK's login state and cross-signing status. Debug
/// levers move it where the fixtures never go on their own.
library;

import 'package:flutter/foundation.dart';

import '../auth/sign_in_state.dart';
import 'accounts.dart';
import 'fixtures.dart';

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

/// Another of your devices asking this one to vouch for it.
@immutable
class IncomingRequest {
  const IncomingRequest({required this.device, required this.at});

  final String device;
  final DateTime at;
}

class MockSession extends ChangeNotifier {
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

  AccountState get account => _account;
  DeviceTrust get trust => _trust;
  IncomingRequest? get incoming => _incoming;

  Member get me => currentUser;
  String get userId => '${currentUser.id}:$server';

  SoftLogout? get softLogout => _account == AccountState.softLoggedOut
      ? SoftLogout(member: me, userId: userId)
      : null;

  /// The debug "fail the next connection" lever.
  void failNext() => _failNext = true;

  /// Spends the lever, if armed.
  bool consumeFailure() {
    final fail = _failNext;
    _failNext = false;
    return fail;
  }

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

  void markVerified() {
    _trust = DeviceTrust.verified;
    notifyListeners();
  }

  /// Another of your devices asks this one to vouch for it. Only a verified
  /// device is asked, so this one becomes one.
  void receiveRequest() {
    _trust = DeviceTrust.verified;
    _incoming = IncomingRequest(device: mockNewDevice(), at: DateTime.now());
    notifyListeners();
  }

  /// Answered, refused or put away. Put away means ignored: the request
  /// times out on its own, as the protocol specifies.
  void clearIncoming() {
    if (_incoming == null) return;
    _incoming = null;
    notifyListeners();
  }
}
