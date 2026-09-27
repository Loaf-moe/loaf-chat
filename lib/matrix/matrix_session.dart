/// The real [LoafSession]: the app's one [Client], its login state and this
/// device's trust, read from the SDK rather than kept alongside it.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';

import '../ui/auth/homeserver.dart';
import '../ui/auth/loaf_session.dart';
import '../ui/auth/sign_in_state.dart';
import '../ui/platform.dart';
import '../ui/verify/verifier.dart';
import 'client_factory.dart';
import 'matrix_device_verification.dart';
import 'matrix_homeserver.dart';
import 'matrix_verifier.dart';
import 'sso_browser.dart';

class MatrixSession extends ChangeNotifier implements LoafSession {
  MatrixSession(
    this.client, {
    required this.browser,
    required this.deviceName,
    this.defaultServer = 'loaf.moe',
  }) {
    _subscriptions = [
      // The SDK reports a failed init as an error on this stream; the state
      // it leaves behind is still worth reading.
      client.onLoginStateChanged.stream.listen(
        (_) => _refresh(),
        onError: (Object _) => _refresh(),
      ),
      // Device keys are updated after a sync is handled, and `finished`
      // comes after that; `onSync` fires too early to see them.
      client.onSyncStatus.stream
          .where((u) => u.status == SyncStatus.finished)
          .listen((_) => _refresh(), onError: (Object _) => _refresh()),
      client.onKeyVerificationRequest.stream.listen(_onRequest),
    ];
    _account = _accountNow();
    _trust = _trustNow();
  }

  /// Opens the stored session, if any. Offline is fine: a stored session
  /// restores from the database and sync retries on its own.
  static Future<MatrixSession> open({required bool desktop}) async {
    // Before the client exists, so this device has encryption keys from its
    // very first sign-in rather than growing them later.
    await vod.init();
    final client = await openClient();
    try {
      await client.init(waitForFirstSync: false);
    } on Exception {
      // A ClientInitException, which package:matrix does not export. The SDK
      // has already cleared the stored session, so the app opens signed out
      // rather than not at all.
    }
    return MatrixSession(
      client,
      browser: ssoInBrowser ? LoopbackSsoBrowser.new : SheetSsoBrowser.new,
      deviceName: deviceNameFor(desktop: desktop),
    );
  }

  final Client client;

  /// Makes each sign-in visit its own browser, so a visit being put away
  /// can never cancel the next one's wait.
  final SsoBrowser Function() browser;

  final String deviceName;

  /// The server a signed-out app offers first.
  final String defaultServer;

  late final List<StreamSubscription<Object?>> _subscriptions;
  late AccountState _account;
  late DeviceTrust _trust;

  @override
  AccountState get account => _account;

  @override
  DeviceTrust get trust => _trust;

  /// The SDK refreshes an expired token itself and clears the session if it
  /// cannot, so there is no locked "welcome back" screen yet.
  @override
  SoftLogout? get softLogout => null;

  IncomingRequest? _incoming;

  @override
  IncomingRequest? get incoming => _incoming;

  @override
  late final Verifier verifier = MatrixVerifier(client);

  @override
  String get homeserverName => defaultServer;

  @override
  Homeserver newHomeserver() =>
      MatrixHomeserver(client, browser: browser(), deviceName: deviceName);

  /// The login state stream says so on its own.
  @override
  void signedIn() {}

  /// Set while a logout is in flight, so a second tap doesn't start another.
  var _signingOut = false;

  @override
  void signOut() {
    if (_signingOut) return;
    _signingOut = true;
    unawaited(_signOut());
  }

  Future<void> _signOut() async {
    try {
      await client.logout();
    } on Exception {
      // The server may be unreachable; logout clears this device either way.
    } finally {
      _signingOut = false;
    }
  }

  /// Trust is read from device keys, so there is nothing to record.
  @override
  void markVerified() {}

  @override
  void clearIncoming() {
    final incoming = _incoming;
    if (incoming == null) return;
    incoming.verification.dispose();
    _incoming = null;
    notifyListeners();
  }

  /// Another of your devices asks this one to verify it. Other people's
  /// requests have no panel yet, so they are left to time out, as is one
  /// that arrives while another is being answered: its panel is open.
  void _onRequest(KeyVerification request) {
    if (request.userId != client.userID || _incoming != null) return;
    final device = request.deviceId == null
        ? null
        : client.userDeviceKeys[client.userID]?.deviceKeys[request.deviceId];
    _incoming = IncomingRequest(
      device: device?.deviceDisplayName ?? request.deviceId ?? 'a new sign-in',
      at: DateTime.now(),
      verification: MatrixDeviceVerification(request),
    );
    notifyListeners();
  }

  @override
  bool consumeFailure() => false;

  AccountState _accountNow() => switch (client.onLoginStateChanged.value) {
    LoginState.loggedIn => AccountState.signedIn,
    // Announced while the SDK refreshes the token, which usually works.
    // Showing sign-in for it would flash the login screen on every refresh.
    LoginState.softLoggedOut => AccountState.signedIn,
    LoginState.loggedOut || null => AccountState.signedOut,
  };

  DeviceTrust _trustNow() {
    final userId = client.userID;
    final keys = userId == null ? null : client.userDeviceKeys[userId];
    // Until this account's keys are known, never claim it has no identity:
    // that notice offers to make one, and would reset a real one.
    if (keys == null || keys.outdated) return DeviceTrust.unverified;
    if (keys.masterKey == null) return DeviceTrust.noIdentity;
    return client.isUnknownSession
        ? DeviceTrust.unverified
        : DeviceTrust.verified;
  }

  void _refresh() {
    final account = _accountNow();
    final trust = _trustNow();
    if (account == _account && trust == _trust) return;
    _account = account;
    _trust = trust;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    unawaited(client.dispose());
    super.dispose();
  }
}

/// What other sessions call this one: "loaf on" this Mac's name, or the
/// kind of phone.
String deviceNameFor({required bool desktop}) {
  if (desktop) return 'loaf on ${Platform.localHostname.split('.').first}';
  return Platform.isIOS ? 'loaf on iPhone' : 'loaf on Android';
}
