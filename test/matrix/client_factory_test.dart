import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('a new database opens signed out', () async {
    final client = await openClient(
      httpClient: FakeMatrixApi(),
      databasePath: inMemoryDatabasePath,
    );
    addTearDown(client.dispose);
    await client.init(waitForFirstSync: false);
    expect(client.onLoginStateChanged.value, LoginState.loggedOut);
  });

  test('two in-memory clients do not share a database', () async {
    Future<Client> fresh() async {
      final c = await openClient(
        httpClient: FakeMatrixApi(),
        databasePath: inMemoryDatabasePath,
      );
      FakeMatrixApi.client = c;
      addTearDown(c.dispose);
      await c.init(waitForFirstSync: false);
      return c;
    }

    final a = await fresh();
    await a.checkHomeserver(
      Uri.https('fakeServer.notExisting'),
      checkWellKnown: false,
    );
    await a.login(
      LoginType.mLoginPassword,
      identifier: AuthenticationUserIdentifier(user: 'test'),
      password: 'x',
    );
    final b = await fresh();
    expect(a.isLogged(), isTrue);
    expect(b.isLogged(), isFalse);
  });
}
