/// The verify panels' work on the SDK: unlocking secret storage with the
/// recovery key, pulling in key backup, and making a new identity behind
/// the server's check of who you are.
library;

import 'dart:async';

import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';
import 'package:url_launcher/url_launcher.dart';

import '../ui/verify/verifier.dart';
import 'matrix_device_verification.dart';
import 'unlock_failure.dart';

class MatrixVerifier implements Verifier {
  MatrixVerifier(
    this.client, {
    Future<bool> Function(Uri url)? openBrowser,
    this.backupKeyWait = const Duration(seconds: 10),
  }) : _openBrowser = openBrowser ?? _launch;

  final Client client;
  final Future<bool> Function(Uri url) _openBrowser;

  /// How long history waits for the key backup key after another device
  /// verified this one: it follows the verification, sent as a secret.
  final Duration backupKeyWait;

  static Future<bool> _launch(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);

  /// Room keys handed to the SDK per step of the count.
  static const _perStep = 50;

  @override
  List<String> get otherSessions => [
    for (final device
        in client.userDeviceKeys[client.userID]?.deviceKeys.values ??
            const <DeviceKeys>[])
      if (device.deviceId != client.deviceID && !device.blocked)
        device.deviceDisplayName ?? device.deviceId ?? 'a device',
  ];

  @override
  DeviceVerification verifyWithDevice() =>
      MatrixDeviceVerification.request(client);

  @override
  Future<UnlockResult> unlock(String keyOrPassphrase) async {
    final encryption = client.encryption;
    if (encryption == null) return UnlockResult.unreachable;
    try {
      final state = await client.getCryptoIdentityState();
      if (state.connected) {
        // The secrets are here already; only this device's signature isn't.
        await encryption.crossSigning.selfSign(
          keyOrPassphrase: keyOrPassphrase,
        );
      } else if (state.initialized) {
        await client.restoreCryptoIdentity(keyOrPassphrase);
      } else if (state.crossSigningEnabled) {
        // Cross-signing without key backup: heal only what's missing.
        GetRoomKeysVersionCurrentResponse? serverBackup;
        try {
          serverBackup = await encryption.keyManager.getRoomKeysBackupInfo(
            false,
          );
        } on MatrixException catch (e) {
          if (e.error != MatrixError.M_NOT_FOUND) rethrow;
        }
        if (serverBackup != null) {
          // The server already keeps a backup whose key isn't in secret
          // storage yet: only sign this device, and never replace it.
          await encryption.crossSigning.selfSign(
            keyOrPassphrase: keyOrPassphrase,
          );
        } else {
          // No backup on the server either: the same key adds one, keeping
          // every existing key.
          await client.initCryptoIdentity(
            reuseExistingStorageRecoveryKeyOrPassphrase: keyOrPassphrase,
            setupMasterKey: false,
            setupSelfSigningKey: false,
            setupUserSigningKey: false,
          );
        }
      } else {
        // No cross-signing in secret storage: no key can sign this device.
        Logs().w('[loaf] secret storage holds no cross-signing keys');
        return UnlockResult.wrongKey;
      }
      return UnlockResult.unlocked;
    } on Object catch (e, s) {
      return unlockFailure(e, s);
    }
  }

  @override
  Stream<RestoreProgress> restoreHistory() async* {
    final keyManager = client.encryption?.keyManager;
    // An account that keeps no key backup has no key on its way to wait for.
    if (keyManager == null || !keyManager.enabled) return;
    final deadline = DateTime.now().add(backupKeyWait);
    while (!await keyManager.isCached()) {
      if (DateTime.now().isAfter(deadline)) return;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    final info = await keyManager.getRoomKeysBackupInfo(false);
    final backup = await client.getRoomKeys(info.version);
    final total = backup.rooms.values.fold(
      0,
      (n, room) => n + room.sessions.length,
    );
    var restored = 0;
    yield RestoreProgress(0, total);
    for (final MapEntry(key: roomId, value: room) in backup.rooms.entries) {
      final sessions = room.sessions.entries.toList();
      for (var i = 0; i < sessions.length; i += _perStep) {
        final step = sessions.skip(i).take(_perStep);
        await keyManager.loadFromResponse(
          RoomKeys(
            rooms: {roomId: RoomKeyBackup(sessions: Map.fromEntries(step))},
          ),
        );
        restored += step.length;
        yield RestoreProgress(restored, total);
      }
    }
  }

  /// This account's master key as the server publishes it, if any.
  String? get _publishedMasterKey =>
      client.userDeviceKeys[client.userID]?.masterKey?.ed25519Key;

  @override
  Future<String?> createIdentity({
    required bool wipe,
    required void Function(AuthChallenge challenge) onAuth,
  }) async {
    if (!wipe) {
      final state = await client.getCryptoIdentityState();
      // A published master key is an identity too, even with its secrets
      // gone from secret storage: setting up must never replace it.
      if (state.keyBackupEnabled ||
          state.crossSigningEnabled ||
          client.encryption!.ssss.defaultKeyId != null ||
          _publishedMasterKey != null) {
        throw RecoveryExists();
      }
      // Secret storage and cross-signing may be untouched, but the server
      // can still hold a key backup from before: setting up must not
      // orphan it either.
      try {
        await client.encryption!.keyManager.getRoomKeysBackupInfo(false);
        throw RecoveryExists();
      } on MatrixException catch (e) {
        if (e.error != MatrixError.M_NOT_FOUND) rethrow;
      }
    }
    var cancelled = false;
    var asked = 0;
    UiaRequest<Object?>? upload;
    final asking = client.onUiaRequest.stream.listen((uia) {
      upload = uia;
      if (uia.state != UiaRequestState.waitForUser) return;
      final kind = uia.nextStages.contains(AuthenticationTypes.password)
          ? AuthKind.password
          : uia.nextStages.contains(AuthenticationTypes.sso)
          ? AuthKind.sso
          : null;
      if (kind == null) {
        // A check this app can't answer: the upload fails, and says so.
        Logs().w('[loaf] the server asked for ${uia.nextStages}');
        uia.cancel();
        return;
      }
      onAuth(
        _Challenge(
          this,
          uia,
          kind,
          retry: asked++ > 0,
          onCancel: () => cancelled = true,
        ),
      );
    });
    // Read before anything goes up, to tell afterwards whether a failure
    // came before or after the old identity was replaced.
    final masterBefore = _publishedMasterKey;
    try {
      return await client.initCryptoIdentity();
    } on Object catch (e, s) {
      if (cancelled) return null;
      if (await _wentUp(upload, masterBefore)) {
        Logs().e('[loaf] the new identity went up but did not finish', e, s);
        throw IdentityIncomplete();
      }
      rethrow;
    } finally {
      await asking.cancel();
    }
  }

  /// Whether new cross-signing keys reached the server before a failure.
  /// This device's own copy of its keys only catches up on a later sync, so
  /// a failure between the upload and that sync can't be read from it.
  Future<bool> _wentUp(UiaRequest<Object?>? asked, String? masterBefore) async {
    // An upload that asked who you are says itself whether it landed.
    if (asked?.state == UiaRequestState.done) return true;
    if (_publishedMasterKey != masterBefore) return true;
    // One that never asked never showed itself: ask the server what it
    // publishes now.
    try {
      final keys = await client.queryKeys({client.userID!: []});
      final now = keys.masterKeys?[client.userID]?.publicKey;
      return now != null && now != masterBefore;
    } on Object catch (e, s) {
      Logs().w("[loaf] couldn't re-read this account's keys", e, s);
      return false;
    }
  }
}

class _Challenge implements AuthChallenge {
  _Challenge(
    this._verifier,
    this._uia,
    this.kind, {
    required this.retry,
    required this.onCancel,
  });

  final MatrixVerifier _verifier;
  final UiaRequest<Object?> _uia;
  final void Function() onCancel;

  @override
  final AuthKind kind;

  @override
  final bool retry;

  Client get _client => _verifier.client;

  /// Once an answer is on its way to the server, nothing here can take it
  /// back: a stale tap (or a cancel that arrives after the right password
  /// already went up) must do nothing rather than fail an upload that may
  /// yet land — that would report "nothing was made" while the server
  /// replaced the identity anyway.
  bool get _live => _uia.state == UiaRequestState.waitForUser;

  @override
  void password(String password) {
    if (!_live) return;
    unawaited(
      _uia.completeStage(
        AuthenticationPassword(
          session: _uia.session,
          password: password,
          identifier: AuthenticationUserIdentifier(user: _client.userID!),
        ),
      ),
    );
  }

  /// The server's own page for SSO, which signs you in and then tells you to
  /// go back to the app: it hands nothing back.
  @override
  void openBrowser() {
    if (!_live) return;
    unawaited(
      _verifier._openBrowser(
        _client.homeserver!.resolveUri(
          Uri(
            path:
                '/_matrix/client/v3/auth/${AuthenticationTypes.sso}/fallback/web',
            queryParameters: {'session': _uia.session},
          ),
        ),
      ),
    );
  }

  @override
  void browserFinished() {
    if (!_live) return;
    unawaited(_uia.completeStage(AuthenticationData(session: _uia.session)));
  }

  @override
  void cancel() {
    if (!_live) return;
    onCancel();
    _uia.cancel();
  }
}
