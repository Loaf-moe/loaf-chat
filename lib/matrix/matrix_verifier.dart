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
        // Cross-signing without key backup: the same key adds the backup,
        // keeping every existing key.
        await client.initCryptoIdentity(
          reuseExistingStorageRecoveryKeyOrPassphrase: keyOrPassphrase,
          setupMasterKey: false,
          setupSelfSigningKey: false,
          setupUserSigningKey: false,
        );
      } else {
        // No cross-signing in secret storage: no key can sign this device.
        Logs().w('[loaf] secret storage holds no cross-signing keys');
        return UnlockResult.wrongKey;
      }
      return UnlockResult.unlocked;
    } on InvalidPassphraseException {
      return UnlockResult.wrongKey;
    } on BootstrapBadStateException catch (e, s) {
      Logs().w('[loaf] this account has no usable secret storage', e, s);
      return UnlockResult.wrongKey;
    } on Object catch (e, s) {
      Logs().w('[loaf] unlocking secret storage failed', e, s);
      return UnlockResult.unreachable;
    }
  }

  @override
  Stream<RestoreProgress> restoreHistory() async* {
    final keyManager = client.encryption?.keyManager;
    if (keyManager == null) return;
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

  @override
  Future<String?> createIdentity({
    required void Function(AuthChallenge challenge) onAuth,
  }) async {
    var cancelled = false;
    var asked = 0;
    final asking = client.onUiaRequest.stream.listen((uia) {
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
    try {
      return await client.initCryptoIdentity();
    } on Object {
      if (cancelled) return null;
      rethrow;
    } finally {
      await asking.cancel();
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

  @override
  void password(String password) => unawaited(
    _uia.completeStage(
      AuthenticationPassword(
        session: _uia.session,
        password: password,
        identifier: AuthenticationUserIdentifier(user: _client.userID!),
      ),
    ),
  );

  /// The server's own page for SSO, which signs you in and then tells you to
  /// go back to the app: it hands nothing back.
  @override
  void openBrowser() => unawaited(
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

  @override
  void browserFinished() =>
      unawaited(_uia.completeStage(AuthenticationData(session: _uia.session)));

  @override
  void cancel() {
    onCancel();
    _uia.cancel();
  }
}
