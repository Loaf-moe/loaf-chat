import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:loaf_native/matrix/matrix_session.dart';
import 'package:loaf_native/matrix/sso_browser.dart';
import 'package:loaf_native/ui/auth/homeserver.dart';
import 'package:loaf_native/ui/auth/loaf_session.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<MatrixSession> _session({String? mediaPath}) async {
  final client = await openClient(
    httpClient: FakeMatrixApi(),
    databasePath: inMemoryDatabasePath,
    mediaPath: mediaPath,
  );
  FakeMatrixApi.client = client;
  await client.init(waitForFirstSync: false);
  final session = MatrixSession(
    client,
    browser: () => LoopbackSsoBrowser(open: (_) async => false),
    deviceName: 'loaf on test',
    defaultServer: 'fakeServer.notExisting',
  );
  addTearDown(session.dispose);
  return session;
}

/// Lets the SDK's streams deliver.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

/// Waits until [done]: on a loaded CI runner, signing out can take longer
/// than [_settle].
Future<void> _until(bool Function() done) async {
  final give = DateTime.now().add(const Duration(seconds: 10));
  while (!done() && DateTime.now().isBefore(give)) {
    await _settle();
  }
}

Future<void> _signIn(MatrixSession s) async {
  final hs = s.newHomeserver();
  await hs.probe('fakeServer.notExisting');
  expect(
    await hs.password('fakeServer.notExisting', 'test', 'x'),
    isA<SignedIn>(),
  );
}

void main() {
  test('a fresh database is signed out', () async {
    final s = await _session();
    expect(s.account, AccountState.signedOut);
  });

  test('signing in through its homeserver signs the session in', () async {
    final s = await _session();
    var notified = 0;
    s.addListener(() => notified++);
    await _signIn(s);
    await s.client.onSyncStatus.stream.firstWhere(
      (u) => u.status == SyncStatus.finished,
    );
    await _settle();
    expect(s.account, AccountState.signedIn);
    // Read from loaded keys, not the not-yet-known default.
    final keys = s.client.userDeviceKeys[s.client.userID]!;
    expect(keys.outdated, isFalse);
    expect(keys.masterKey, isNotNull);
    // The fake account has an identity this new device is not signed by.
    expect(s.trust, DeviceTrust.unverified);
    expect(notified, greaterThan(0));
  });

  test('keys not yet known never read as no identity', () async {
    final s = await _session();
    await _signIn(s);
    // Straight after sign-in, before any sync has fetched device keys.
    expect(s.trust, isNot(DeviceTrust.noIdentity));
  });

  test('signing out signs the session out', () async {
    final s = await _session();
    await _signIn(s);
    await _settle();
    s.signOut();
    await _until(() => s.account == AccountState.signedOut);
    expect(s.account, AccountState.signedOut);
  });

  test('signing in again after signing out works', () async {
    final s = await _session();
    await _signIn(s);
    await _settle();
    s.signOut();
    await _until(() => s.account == AccountState.signedOut);
    expect(s.account, AccountState.signedOut);
    await _signIn(s);
    await _settle();
    expect(s.account, AccountState.signedIn);
  });

  test('signing out clears downloaded media', () async {
    final dir = Directory.systemTemp.createTempSync('loaf-media');
    addTearDown(() => dir.deleteSync(recursive: true));
    final s = await _session(mediaPath: dir.path);
    await _signIn(s);
    await _settle();
    File('${dir.path}/abc').writeAsStringSync('a picture');
    s.signOut();
    await _until(() => s.account == AccountState.signedOut);
    expect(s.account, AccountState.signedOut);
    expect(dir.existsSync(), isTrue);
    expect(dir.listSync(), isEmpty);
  });

  test('a second sign-out while one is in flight does nothing', () async {
    final s = await _session();
    await _signIn(s);
    await _settle();
    s.signOut();
    s.signOut();
    await _until(() => s.account == AccountState.signedOut);
    expect(s.account, AccountState.signedOut);
    expect(FakeMatrixApi.calledEndpoints['/client/v3/logout'], hasLength(1));
  });

  test('a failed init inside sign-in is not an uncaught error', () async {
    final s = await _session();
    s.client.onLoginStateChanged.addError(Exception('init failed'));
    await _settle();
    expect(s.account, AccountState.signedOut);
  });

  test('a token refresh in flight does not sign out', () async {
    final s = await _session();
    await _signIn(s);
    await _settle();
    s.client.onLoginStateChanged.add(LoginState.softLoggedOut);
    await _settle();
    expect(s.account, AccountState.signedIn);
  });

  test('device names say where they are', () {
    expect(deviceNameFor(desktop: true), startsWith('loaf on '));
  });
}
