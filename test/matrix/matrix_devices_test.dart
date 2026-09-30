import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:loaf_native/matrix/matrix_devices.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _me = '@test:fakeServer.notExisting';

/// The fake server, plus the device endpoints: a list, renaming, and a
/// delete that asks for the password first.
class _Api extends FakeMatrixApi {
  final requests = <String>[];
  var deletes = 0;

  /// The device list can't be fetched: the reload after a write fails.
  var listFails = false;

  /// Keeps the next DELETE back until completed.
  Completer<void>? hold;

  var devices = <Map<String, Object?>>[
    {
      'device_id': 'GHTYAJCE',
      'display_name': 'loaf on test',
      'last_seen_ts': 1700000000000,
      'last_seen_ip': '1.2.3.4',
    },
    {'device_id': 'OTHER', 'display_name': 'element on phone'},
    {'device_id': 'NAMELESS'},
  ];

  Map<String, Object?> _ask({bool wrong = false}) => {
    if (wrong) 'errcode': 'M_FORBIDDEN',
    if (wrong) 'error': 'Invalid password',
    'flows': [
      {
        'stages': ['m.login.password'],
      },
    ],
    'params': <String, Object?>{},
    'session': 'sess',
  };

  @override
  Future<http.Response> mockIntercept(http.Request request) async {
    final path = request.url.path;
    if (path == '/_matrix/client/v3/devices' && request.method == 'GET') {
      requests.add('GET devices');
      if (listFails) return http.Response('{}', 500);
      return http.Response(jsonEncode({'devices': devices}), 200);
    }
    final id = path.startsWith('/_matrix/client/v3/devices/')
        ? Uri.decodeComponent(path.split('/').last)
        : null;
    if (id != null && request.method == 'PUT') {
      final name = (jsonDecode(request.body) as Map)['display_name'];
      requests.add('PUT $id $name');
      for (final d in devices) {
        if (d['device_id'] == id) d['display_name'] = name;
      }
      return http.Response('{}', 200);
    }
    if (id != null && request.method == 'DELETE') {
      deletes++;
      requests.add('DELETE $id');
      final held = hold;
      if (held != null) {
        hold = null;
        await held.future;
      }
      final auth = (jsonDecode(request.body) as Map)['auth'] as Map?;
      final password = auth?['password'];
      if (auth == null) return http.Response(jsonEncode(_ask()), 401);
      if (password != 'right') {
        return http.Response(jsonEncode(_ask(wrong: true)), 401);
      }
      devices.removeWhere((d) => d['device_id'] == id);
      return http.Response('{}', 200);
    }
    return super.mockIntercept(request);
  }
}

Future<Client> _client(_Api api) async {
  final client = await openClient(
    httpClient: api,
    databasePath: inMemoryDatabasePath,
  );
  FakeMatrixApi.client = client;
  await client.init(
    newToken: 'abcd',
    newHomeserver: Uri.parse('https://fakeServer.notExisting'),
    newUserID: _me,
    newDeviceID: 'GHTYAJCE',
    newDeviceName: 'loaf on test',
    waitForFirstSync: true,
  );
  addTearDown(client.dispose);
  return client;
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

Future<(_Api, MatrixDevices)> _open() async {
  final api = _Api();
  final devices = MatrixDevices(await _client(api));
  addTearDown(devices.dispose);
  await devices.load();
  return (api, devices);
}

void main() {
  test('devices map with this one marked current', () async {
    final (_, devices) = await _open();
    final list = devices.list!;
    final mine = list.firstWhere((d) => d.id == 'GHTYAJCE');
    expect(mine.current, isTrue);
    expect(mine.name, 'loaf on test');
    expect(mine.lastIp, '1.2.3.4');
    expect(mine.lastSeen, DateTime.fromMillisecondsSinceEpoch(1700000000000));
    final other = list.firstWhere((d) => d.id == 'OTHER');
    expect(other.current, isFalse);
    expect(other.verified, isFalse);
    expect(other.lastSeen, isNull);
    // No display name: the id stands in.
    expect(list.firstWhere((d) => d.id == 'NAMELESS').name, 'NAMELESS');
  });

  test('rename sends the name and reloads', () async {
    final (api, devices) = await _open();
    await devices.rename('OTHER', 'kitchen tablet');
    expect(api.requests, containsAllInOrder(['PUT OTHER kitchen tablet']));
    expect(api.requests.last, 'GET devices');
    expect(
      devices.list!.firstWhere((d) => d.id == 'OTHER').name,
      'kitchen tablet',
    );
  });

  test('a rename that landed is not a failure when the reload fails', () async {
    final (api, devices) = await _open();
    api.listFails = true;
    await devices.rename('OTHER', 'kitchen tablet');
    expect(api.requests, contains('PUT OTHER kitchen tablet'));
  });

  test('a device-list change in sync reloads', () async {
    final api = _Api();
    final client = await _client(api);
    final devices = MatrixDevices(client);
    addTearDown(devices.dispose);
    await devices.load();
    api.devices.add({'device_id': 'NEW', 'display_name': 'new one'});
    client.onSync.add(
      SyncUpdate(
        nextBatch: 'x',
        deviceLists: DeviceListsUpdate(changed: [_me]),
      ),
    );
    await _settle();
    expect(devices.list!.any((d) => d.id == 'NEW'), isTrue);
  });

  test("a change to someone else's devices reloads nothing", () async {
    final api = _Api();
    final client = await _client(api);
    final devices = MatrixDevices(client);
    addTearDown(devices.dispose);
    await devices.load();
    final before = api.requests.length;
    client.onSync.add(
      SyncUpdate(
        nextBatch: 'x',
        deviceLists: DeviceListsUpdate(changed: ['@other:example.org']),
      ),
    );
    await _settle();
    expect(api.requests.length, before);
  });

  group('signing out', () {
    test('asks who you are, then deletes', () async {
      final (_, devices) = await _open();
      final ok = await devices.signOut(
        'OTHER',
        onAuth: (c) => c.password('right'),
      );
      expect(ok, isTrue);
      expect(devices.list!.any((d) => d.id == 'OTHER'), isFalse);
    });

    test('signed out is signed out when the reload fails', () async {
      final (api, devices) = await _open();
      api.listFails = true;
      var heard = 0;
      devices.addListener(() => heard++);
      final ok = await devices.signOut(
        'OTHER',
        onAuth: (c) => c.password('right'),
      );
      expect(ok, isTrue);
      expect(devices.list!.any((d) => d.id == 'OTHER'), isFalse);
      expect(devices.list!.any((d) => d.id == 'NAMELESS'), isTrue);
      expect(heard, greaterThan(0));
    });

    test('a wrong password asks again with retry', () async {
      final (_, devices) = await _open();
      final retries = <bool>[];
      final ok = await devices.signOut(
        'OTHER',
        onAuth: (c) {
          retries.add(c.retry);
          c.password(retries.length == 1 ? 'wrong' : 'right');
        },
      );
      expect(ok, isTrue);
      expect(retries, [false, true]);
    });

    test('cancelling signs nothing out', () async {
      final (api, devices) = await _open();
      final ok = await devices.signOut('OTHER', onAuth: (c) => c.cancel());
      expect(ok, isFalse);
      expect(api.deletes, 1);
      expect(devices.list!.any((d) => d.id == 'OTHER'), isTrue);
    });

    test('never appears on onUiaRequest', () async {
      final api = _Api();
      final client = await _client(api);
      final devices = MatrixDevices(client);
      addTearDown(devices.dispose);
      await devices.load();
      final seen = <UiaRequest<Object?>>[];
      final sub = client.onUiaRequest.stream.listen(seen.add);
      addTearDown(sub.cancel);
      await devices.signOut('OTHER', onAuth: (c) => c.password('right'));
      await _settle();
      expect(seen, isEmpty);
    });

    test('disposing mid-save notifies nothing', () async {
      final api = _Api();
      final client = await _client(api);
      final devices = MatrixDevices(client);
      await devices.load();
      var notified = 0;
      var asked = 0;
      devices.addListener(() => notified++);
      final release = api.hold = Completer<void>();
      final signOut = devices.signOut('OTHER', onAuth: (_) => asked++);
      await _settle();
      devices.dispose();
      release.complete();
      expect(await signOut, isFalse);
      await _settle();
      expect(notified, 0);
      expect(asked, 0);
    });
  });
}
