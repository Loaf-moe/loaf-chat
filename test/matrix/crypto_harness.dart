/// What an encryption test needs: vodozemac, and fake-server clients whose
/// keys match the fake server's fixtures.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The native library under the name vodozemac loads on this platform.
final _file = Platform.isWindows
    ? 'vodozemac_bindings_dart.dll'
    : Platform.isMacOS
    ? 'libflutter_vodozemac.dylib'
    : 'libvodozemac_bindings_dart.so';

/// What `tool/build-vodozemac` builds, which CI uses; on a Mac, a debug app
/// build has one too.
final _dirs = [
  'build/vodozemac/',
  if (Platform.isMacOS) 'build/macos/Build/Products/Debug/',
];

Future<void>? _loading;

/// Loads vodozemac from its build, once per test file.
Future<void> loadVodozemac() => _loading ??= () async {
  final dir = _dirs.where((d) => File('$d$_file').existsSync()).firstOrNull;
  if (dir == null) {
    fail(
      'encryption tests need vodozemac built: run `sh tool/build-vodozemac` '
      'once, then test again',
    );
  }
  await vod.init(libraryPath: dir);
}();

const me = '@test:fakeServer.notExisting';
const other = '@othertest:fakeServer.notExisting';

/// The fixture account's secret storage key: it opens the fake server's
/// cross-signing and key backup secrets.
const fixtureRecoveryKey =
    'EsT9 RzbW VhPW yqNp cC7j ViiW 5TZB LuY4 ryyv 9guN Ysmr WDPH';
const fixturePassphrase = 'nae7ahDiequ7ohniufah3ieS2je1thohX4xeeka7aixohsho9O';

// The olm accounts behind the fixtures' device keys: @test's GHTYAJCE and
// @othertest's FOXDEVICE. From matrix-dart-sdk's own tests.
const _myAccount =
    'huxcPifHlyiQsX7cZeMMITbka3hLeUT3ss6DLL6dV7knaD4wgAYK6gcWknkixnX8C5KMIyxzytxiNqAOhDFRE5NsET8hr2dQ8OvXX7M95eQ7/3dPi7FkPUIbvneTSGgJYNDxJdHsDJ8OBHZ3BoqUJFDbTzFfVJjEzN4G9XQwPDafZ2p5WyerOK8Twj/rvk5N+ERmkt1XgVLQl66we/BO1ugTeM3YpDHm5lTzFUitJGTIuuONsKG9mmzdAmVUJ9YIrSxwmOBdegbGA+LAl5acg5VOol3KxRgZUMJQRQ58zpBAs72oauHizv1QVoQ7uIUiCUeb9lym+TEjmApvhru/1CPHU90K5jHNZ57wb/4V9VsqBWuoNibzDWG35YTFLcx0o+1lrCIjm1QjuC0777G+L1HNw5wnppV3z/k0YujjuPS3wvOA30TjHg';
const _otherAccount =
    '0aFMkSgJhj0kVLxVnactRpl3L2kgIR8bAqICFtDkvp/mkinITZjr1Vh6Jy9FmJzvhLfFUtjU2j/2bqrFn61CSrvRbRaLP6rCFegGJHNGpVfw+c24NthCwGF/SN10aPjPo6yQ3er9bc42I6AmJz5HgyfU6C4bE+LdWrML93C0iEnmQN/SYHnS1KHPXNl6NpFGITggbZQ9jwHOFILWo8wzJ4iqlJtMrNaOOLAAB7By7Fbxl4xoNz2K+w';

/// A signed-in client with encryption on, over [api] (a fresh fake server
/// when null). [asOther] signs in as @othertest instead of @test. Sync stops
/// after the first, so tests hand it what they want it to see. [path] keeps
/// its store in a file, for [relaunch].
Future<Client> cryptoClient({
  FakeMatrixApi? api,
  bool asOther = false,
  String path = inMemoryDatabasePath,
}) async {
  await loadVodozemac();
  final client = await openClient(
    httpClient: api ?? FakeMatrixApi(),
    databasePath: path,
  );
  FakeMatrixApi.client = client;
  await client.checkHomeserver(
    Uri.parse('https://fakeServer.notExisting'),
    checkWellKnown: false,
  );
  await client.init(
    newToken: asOther ? 'abc' : 'abcd',
    newUserID: asOther ? other : me,
    newHomeserver: client.homeserver,
    newDeviceName: 'loaf on test',
    newDeviceID: asOther ? 'FOXDEVICE' : 'GHTYAJCE',
    newOlmAccount: asOther ? _otherAccount : _myAccount,
  );
  await client.abortSync();
  addTearDown(() => client.dispose(closeDatabase: true));
  return client;
}

/// The app quitting and opening again on the store at [path]: the session
/// and its keys come back from it alone.
Future<Client> relaunch(Client quitting, String path) async {
  await quitting.dispose(closeDatabase: true);
  final client = await openClient(
    httpClient: FakeMatrixApi(),
    databasePath: path,
  );
  FakeMatrixApi.client = client;
  await client.init(waitForFirstSync: false);
  addTearDown(() => client.dispose(closeDatabase: true));
  return client;
}

/// The first in-room verification event [client] sent since the fake
/// server's record was last cleared, as the other side would receive it.
/// Nothing delivers it; tests relay it by hand.
Event sentVerification(Client client, String transactionId, Room room) {
  final entry = FakeMatrixApi.calledEndpoints.entries.firstWhere(
    (e) => e.key.contains('/send/'),
  );
  return Event.fromJson({
    'event_id': transactionId,
    'type': entry.key.split('/')[6],
    'content': jsonDecode(entry.value.first as String),
    'origin_server_ts': DateTime.now().millisecondsSinceEpoch,
    'sender': client.userID,
  }, room);
}

/// Waits for the fake server to have been asked for [path]. Polls, since
/// `FakeMatrixApi.firstWhere` only sees calls already made.
Future<void> sentTo(String path) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!FakeMatrixApi.calledEndpoints.keys.any((e) => e.startsWith(path))) {
    if (DateTime.now().isAfter(deadline)) fail('nothing was sent to $path');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
