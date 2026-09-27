import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:loaf_native/matrix/matrix_verifier.dart';
import 'package:loaf_native/ui/verify/verifier.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';

import 'crypto_harness.dart';

/// The fake server, able to go quiet, and to ask who you are before new
/// cross-signing keys go up: by password (only [password] passes) or by
/// its SSO page (passes once [ssoDone]). It can also hold the upload open
/// once the check has passed, and say there is no key backup at all.
class _Api extends FakeMatrixApi {
  var down = false;
  String? asks;
  var password = 'right';
  var ssoDone = false;

  /// Set to hold `/keys/device_signing/upload` open after the check has
  /// passed, so a test can act while the real upload is still in flight.
  Completer<void>? holdUpload;

  /// True while [holdUpload] is being awaited.
  var holding = false;

  /// 404s `GET .../room_keys/version` as `M_NOT_FOUND`, as an account with
  /// no key backup on the server would answer.
  var noBackupOnServer = false;

  static http.Response _json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status);

  @override
  Future<http.Response> mockIntercept(http.Request request) async {
    if (down) return _json({'errcode': 'M_UNKNOWN', 'error': 'down'}, 502);
    if (noBackupOnServer &&
        request.method == 'GET' &&
        request.url.path.endsWith('/room_keys/version')) {
      return _json({'errcode': 'M_NOT_FOUND', 'error': 'not found'}, 404);
    }
    final stage = asks;
    if (stage != null &&
        request.url.path.endsWith('/keys/device_signing/upload')) {
      final auth = (jsonDecode(request.body) as Map)['auth'] as Map?;
      final passed = switch (stage) {
        AuthenticationTypes.password => auth?['password'] == password,
        AuthenticationTypes.sso => auth?['session'] == 'uia' && ssoDone,
        _ => false,
      };
      if (!passed) {
        return _json({
          'session': 'uia',
          'flows': [
            {
              'stages': [stage],
            },
          ],
          'params': <String, Object?>{},
          if (auth?['password'] != null) 'errcode': 'M_FORBIDDEN',
        }, 401);
      }
      final hold = holdUpload;
      if (hold != null) {
        holding = true;
        await hold.future;
        holding = false;
      }
    }
    return await super.mockIntercept(request);
  }
}

void main() {
  late _Api api;
  late Client client;
  late MatrixVerifier verifier;
  final opened = <Uri>[];

  setUp(() async {
    opened.clear();
    api = _Api();
    client = await cryptoClient(api: api);
    verifier = MatrixVerifier(
      client,
      openBrowser: (url) async {
        opened.add(url);
        return true;
      },
      backupKeyWait: const Duration(milliseconds: 100),
    );
  });

  test('other sessions are your other devices, by name', () {
    final names = verifier.otherSessions;
    expect(names, isNotEmpty);
    final mine = client.userDeviceKeys[me]!.deviceKeys[client.deviceID]!;
    expect(names, isNot(contains(mine.deviceDisplayName ?? client.deviceID)));
  });

  group('unlocking', () {
    test('a wrong key or passphrase unlocks nothing', () async {
      expect(await verifier.unlock('EsT9 not the key'), UnlockResult.wrongKey);
      expect(
        await verifier.unlock('not the passphrase'),
        UnlockResult.wrongKey,
      );
      expect(client.isUnknownSession, isTrue);
    });

    test('the recovery key signs this device', () async {
      expect(client.isUnknownSession, isTrue);
      expect(await verifier.unlock(fixtureRecoveryKey), UnlockResult.unlocked);
      expect(client.isUnknownSession, isFalse);
    });

    test('so does the passphrase', () async {
      expect(await verifier.unlock(fixturePassphrase), UnlockResult.unlocked);
      expect(client.isUnknownSession, isFalse);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a server that does not answer is not a wrong key', () async {
      api.down = true;
      expect(
        await verifier.unlock(fixtureRecoveryKey),
        UnlockResult.unreachable,
      );
    });

    test('a mistyped key is a wrong key, not an unreachable server', () async {
      final key = await client.initCryptoIdentity();
      await client.encryption!.ssss.clearCache();
      final chars = key.split('');
      // Keeps the length and the `Es` start; one base58 character (never
      // `0`) becomes `0`.
      final i = chars.indexWhere((c) => c != ' ', 2);
      chars[i] = '0';
      expect(await verifier.unlock(chars.join()), UnlockResult.wrongKey);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('cross-signing without key backup is signed, and a backup the server '
        'has is left alone', () async {
      await client.setAccountData(me, EventTypes.MegolmBackup, {});
      var state = await client.getCryptoIdentityState();
      expect(state.crossSigningEnabled, isTrue);
      expect(state.keyBackupEnabled, isFalse);
      final master = client.userDeviceKeys[me]!.masterKey!.ed25519Key;
      FakeMatrixApi.calledEndpoints.clear();

      expect(await verifier.unlock(fixtureRecoveryKey), UnlockResult.unlocked);
      expect(client.isUnknownSession, isFalse);
      state = await client.getCryptoIdentityState();
      expect(state.keyBackupEnabled, isFalse);
      expect(client.userDeviceKeys[me]!.masterKey!.ed25519Key, master);
      // Only a GET checked the server's backup; nothing POSTed a new one.
      expect(
        FakeMatrixApi.calledEndpoints['/client/v3/room_keys/version']
                ?.whereType<String>() ??
            const [],
        isEmpty,
      );
    });

    test(
      'cross-signing with no backup on the server, the key adds one',
      () async {
        await client.setAccountData(me, EventTypes.MegolmBackup, {});
        api.noBackupOnServer = true;
        final master = client.userDeviceKeys[me]!.masterKey!.ed25519Key;

        expect(
          await verifier.unlock(fixtureRecoveryKey),
          UnlockResult.unlocked,
        );
        final state = await client.getCryptoIdentityState();
        expect(state.keyBackupEnabled, isTrue);
        expect(client.userDeviceKeys[me]!.masterKey!.ed25519Key, master);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('restoring history', () {
    test('counts every room key in the backup, and keeps them', () async {
      await verifier.unlock(fixtureRecoveryKey);
      final steps = await verifier.restoreHistory().toList();
      expect(steps.first.restored, 0);
      expect(steps.last.restored, steps.last.total);
      expect(steps.last.total, greaterThan(0));
      final backup = await client.getRoomKeys(
        (await client.encryption!.keyManager.getRoomKeysBackupInfo()).version,
      );
      final room = backup.rooms.entries.first;
      final session = room.value.sessions.keys.first;
      expect(
        client.encryption!.keyManager.getInboundGroupSession(room.key, session),
        isNotNull,
      );
    });

    test('nothing to restore without the backup key', () async {
      expect(await verifier.restoreHistory().toList(), isEmpty);
    });

    test('waits for the backup key to arrive', () async {
      final slow = MatrixVerifier(
        client,
        backupKeyWait: const Duration(seconds: 5),
      );
      final steps = slow.restoreHistory().toList();
      // As it would arrive after an emoji verification, as a secret.
      await client.restoreCryptoIdentity(fixtureRecoveryKey);
      expect(await steps, isNotEmpty);
    });
  });

  group('a new identity', () {
    test('comes with a recovery key, and signs this device', () async {
      final asked = <AuthChallenge>[];
      FakeMatrixApi.calledEndpoints.clear();
      final key = await verifier.createIdentity(wipe: true, onAuth: asked.add);
      expect(key, startsWith('Es'));
      expect(asked, isEmpty);
      expect((await client.getCryptoIdentityState()).connected, isTrue);
      // The fake server keeps serving the old signatures, so this device's
      // new one shows only as sent.
      expect(
        FakeMatrixApi.calledEndpoints.keys,
        contains('/client/v3/keys/signatures/upload'),
      );
    }, timeout: const Timeout(Duration(minutes: 2)));

    test(
      'setting up refuses an account that already keeps a recovery key',
      () async {
        final master = client.userDeviceKeys[me]!.masterKey!.ed25519Key;
        final asked = <AuthChallenge>[];
        await expectLater(
          verifier.createIdentity(wipe: false, onAuth: asked.add),
          throwsA(isA<RecoveryExists>()),
        );
        expect(asked, isEmpty);
        expect(client.userDeviceKeys[me]!.masterKey!.ed25519Key, master);
      },
    );

    test('setting up also refuses a key backup the server holds, even with '
        'no secret storage or cross-signing locally', () async {
      // Blanks every secret this device would otherwise see, the same
      // way the "cross-signing without key backup" tests do — but the
      // fake server still answers the backup version it was given at
      // setup, as a real server would keep serving one Chris made
      // elsewhere.
      for (final type in [
        EventTypes.MegolmBackup,
        EventTypes.CrossSigningSelfSigning,
        EventTypes.CrossSigningUserSigning,
        EventTypes.CrossSigningMasterKey,
        EventTypes.SecretStorageDefaultKey,
      ]) {
        await client.setAccountData(me, type, {});
      }
      final state = await client.getCryptoIdentityState();
      expect(state.keyBackupEnabled, isFalse);
      expect(state.crossSigningEnabled, isFalse);
      expect(client.encryption!.ssss.defaultKeyId, isNull);

      FakeMatrixApi.calledEndpoints.clear();
      final asked = <AuthChallenge>[];
      await expectLater(
        verifier.createIdentity(wipe: false, onAuth: asked.add),
        throwsA(isA<RecoveryExists>()),
      );
      expect(asked, isEmpty);
      expect(
        FakeMatrixApi.calledEndpoints['/client/v3/room_keys/version']
                ?.whereType<String>() ??
            const [],
        isEmpty,
        reason: 'nothing POSTed a new backup',
      );
    });

    test('asks for the password, again when it is wrong', () async {
      api.asks = AuthenticationTypes.password;
      final asked = <AuthChallenge>[];
      final made = verifier.createIdentity(wipe: true, onAuth: asked.add);
      await _until(() => asked.length == 1);
      expect(asked.single.kind, AuthKind.password);
      expect(asked.single.retry, isFalse);

      asked.single.password('wrong');
      await _until(() => asked.length == 2);
      expect(asked.last.retry, isTrue);

      asked.last.password('right');
      expect(await made, startsWith('Es'));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('sends you to the server\'s page for SSO, and asks again if it '
        'did not finish', () async {
      api.asks = AuthenticationTypes.sso;
      final asked = <AuthChallenge>[];
      final made = verifier.createIdentity(wipe: true, onAuth: asked.add);
      await _until(() => asked.length == 1);
      expect(asked.single.kind, AuthKind.sso);

      asked.single.openBrowser();
      await _until(() => opened.isNotEmpty);
      expect(
        opened.single.toString(),
        endsWith(
          '/_matrix/client/v3/auth/m.login.sso/fallback/web?session=uia',
        ),
      );

      asked.single.browserFinished();
      await _until(() => asked.length == 2);
      expect(asked.last.retry, isTrue);

      api.ssoDone = true;
      asked.last.browserFinished();
      expect(await made, startsWith('Es'));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('cancelled at the check, nothing is made', () async {
      api.asks = AuthenticationTypes.password;
      final master = client.userDeviceKeys[me]!.masterKey!.ed25519Key;
      final asked = <AuthChallenge>[];
      final made = verifier.createIdentity(wipe: true, onAuth: asked.add);
      await _until(() => asked.isNotEmpty);
      asked.single.cancel();
      expect(await made, isNull);
      expect(client.userDeviceKeys[me]!.masterKey!.ed25519Key, master);
      // The old recovery key still opens everything it did.
      expect(await verifier.unlock(fixtureRecoveryKey), UnlockResult.unlocked);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('cancelling once the answer went up is too late, and the key still '
        'comes back', () async {
      api.asks = AuthenticationTypes.password;
      final hold = Completer<void>();
      api.holdUpload = hold;
      final asked = <AuthChallenge>[];
      final made = verifier.createIdentity(wipe: true, onAuth: asked.add);
      await _until(() => asked.isNotEmpty);
      asked.single.password('right');
      await _until(() => api.holding);
      asked.single.cancel();
      hold.complete();
      expect(await made, startsWith('Es'));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a check this app cannot answer fails, and says so', () async {
      api.asks = 'm.login.recaptcha';
      final asked = <AuthChallenge>[];
      await expectLater(
        verifier.createIdentity(wipe: true, onAuth: asked.add),
        throwsA(anything),
      );
      expect(asked, isEmpty);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}

Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('it never happened');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
