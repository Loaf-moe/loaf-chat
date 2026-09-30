import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:loaf_native/matrix/matrix_profile.dart';
import 'package:loaf_native/matrix/matrix_rooms.dart';
import 'package:loaf_native/ui/members/presence.dart' as loaf;
import 'package:matrix/matrix.dart' hide Presence;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _me = '@test:fakeServer.notExisting';

/// The fake server, recording each presence `PUT`. [gate] holds the next
/// one until completed with true (goes through) or false (refused);
/// [refuseWith] and [socketFailure] apply to all the rest.
class _Api extends FakeMatrixApi {
  final bodies = <Map<String, Object?>>[];
  Completer<bool>? gate;
  ({String errcode, int status})? refuseWith;
  var socketFailure = false;

  @override
  FutureOr<http.Response> mockIntercept(http.Request request) async {
    if (request.method == 'PUT' &&
        request.url.path.contains('/presence/') &&
        request.url.path.endsWith('/status')) {
      bodies.add(jsonDecode(request.body) as Map<String, Object?>);
      final mine = gate;
      gate = null;
      if (mine != null && !await mine.future) return _refused('M_UNKNOWN', 500);
      if (socketFailure) throw const SocketException('no route');
      final refuse = refuseWith;
      if (refuse != null) return _refused(refuse.errcode, refuse.status);
      return http.Response(jsonEncode({}), 200);
    }
    return super.mockIntercept(request);
  }

  http.Response _refused(String errcode, int status) =>
      http.Response(jsonEncode({'errcode': errcode, 'error': 'no'}), status);
}

Future<Client> _client(_Api api) async {
  final client = await openClient(
    httpClient: api,
    databasePath: inMemoryDatabasePath,
  );
  FakeMatrixApi.client = client;
  // No sync loop: the fake's own presence events would answer the questions
  // these tests ask. Each test pushes exactly the sync it means.
  client.backgroundSync = false;
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

/// Lets the SDK's streams deliver.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

var _batches = 0;

Future<void> _presence(
  Client client,
  String sender,
  Map<String, Object?> c,
) async {
  await client.handleSync(
    SyncUpdate.fromJson({
      'next_batch': 'p${_batches++}',
      'presence': {
        'events': [
          {'type': 'm.presence', 'sender': sender, 'content': c},
        ],
      },
    }),
  );
  // The SDK's streams deliver a beat later.
  await _settle();
}

void _finishSync(Client client) =>
    client.onSyncStatus.add(SyncStatusUpdate(SyncStatus.finished));

Future<(_Api, Client, MatrixProfile)> _profile({
  ({String errcode, int status})? refuseWith,
  bool socketFailure = false,
}) async {
  final api = _Api()
    ..refuseWith = refuseWith
    ..socketFailure = socketFailure;
  final client = await _client(api);
  final profile = MatrixProfile(client);
  addTearDown(profile.dispose);
  // The client had synced already, so the first publish is on its way.
  await _settle();
  return (api, client, profile);
}

void main() {
  test('choosing idle sends unavailable', () async {
    final (api, client, profile) = await _profile();
    await profile.choose(loaf.PresenceChoice.idle);
    expect(api.bodies.last['presence'], 'unavailable');
    expect(client.syncPresence, PresenceType.unavailable);
    expect(profile.choice, loaf.PresenceChoice.idle);
  });

  test('invisible sends offline', () async {
    final (api, client, profile) = await _profile();
    await profile.choose(loaf.PresenceChoice.invisible);
    expect(api.bodies.last['presence'], 'offline');
    expect(client.syncPresence, PresenceType.offline);
  });

  test('a status goes out with the presence', () async {
    final (api, _, profile) = await _profile();
    await profile.setStatus('baking');
    expect(api.bodies.last['status_msg'], 'baking');
    expect(profile.status, 'baking');
    await profile.setStatus('');
    expect(api.bodies.last['status_msg'], '');
    expect(profile.status, '');
  });

  test('the first finished sync publishes the choice once', () async {
    final (api, client, _) = await _profile();
    _finishSync(client);
    await _settle();
    _finishSync(client);
    await _settle();
    expect(api.bodies, hasLength(1));
    expect(api.bodies.single['presence'], 'online');
  });

  test('the launch publish keeps the status the server already has', () async {
    final api = _Api();
    final client = await _client(api);
    await client.database.storePresence(
      _me,
      CachedPresence(PresenceType.online, null, 'baking', null, _me),
    );
    final profile = MatrixProfile(client);
    addTearDown(profile.dispose);
    await _settle();
    expect(api.bodies.first['status_msg'], 'baking');
    expect(profile.status, 'baking');
  });

  test('rooms never asked for a profile publish nothing', () async {
    final api = _Api();
    final client = await _client(api);
    final rooms = MatrixRooms(client);
    await _settle();
    rooms.dispose();
    await _settle();
    expect(api.bodies, isEmpty);
  });

  test('a refused publish means the server shares none', () async {
    final (_, client, profile) = await _profile(
      refuseWith: (errcode: 'M_FORBIDDEN', status: 403),
    );
    _finishSync(client);
    await _settle();
    expect(profile.presenceShared, isFalse);
  });

  test('an unrecognised publish means the server shares none', () async {
    final (_, client, profile) = await _profile(
      refuseWith: (errcode: 'M_UNRECOGNIZED', status: 404),
    );
    _finishSync(client);
    await _settle();
    expect(profile.presenceShared, isFalse);
  });

  test('a presence event means the server shares again', () async {
    final (_, client, profile) = await _profile(
      refuseWith: (errcode: 'M_FORBIDDEN', status: 403),
    );
    _finishSync(client);
    await _settle();
    expect(profile.presenceShared, isFalse);
    await _presence(client, '@alice:x', {'presence': 'online'});
    await _settle();
    expect(profile.presenceShared, isTrue);
  });

  test('a network failure decides nothing', () async {
    final (_, client, profile) = await _profile(socketFailure: true);
    _finishSync(client);
    await _settle();
    expect(profile.presenceShared, isTrue);
  });

  test('someone never heard is null, and stays so', () async {
    final (_, _, profile) = await _profile();
    expect(profile.presenceOf('@nobody:x'), isNull);
    await _settle();
    expect(profile.presenceOf('@nobody:x'), isNull);
  });

  test('a stored presence is found after it loads', () async {
    final (_, client, profile) = await _profile();
    await client.database.storePresence(
      '@stored:x',
      CachedPresence(PresenceType.online, null, null, null, '@stored:x'),
    );
    // Your own stored status loads at start; let that land first.
    await _settle();
    var heard = 0;
    profile.addListener(() => heard++);
    expect(profile.presenceOf('@stored:x'), isNull);
    await _settle();
    expect(profile.presenceOf('@stored:x'), (loaf.Presence.online, null));
    expect(heard, 1);
  });

  test('busy reads as do not disturb', () async {
    final (_, client, profile) = await _profile();
    await _presence(client, '@alice:x', {
      'presence': 'busy',
      'status_msg': 'focus',
    });
    expect(profile.presenceOf('@alice:x'), (loaf.Presence.dnd, 'focus'));
  });

  test('unavailable reads as idle, offline as offline', () async {
    final (_, client, profile) = await _profile();
    await _presence(client, '@a:x', {'presence': 'unavailable'});
    await _presence(client, '@b:x', {'presence': 'offline'});
    expect(profile.presenceOf('@a:x'), (loaf.Presence.idle, null));
    expect(profile.presenceOf('@b:x'), (loaf.Presence.offline, null));
  });

  test('a refused choice only rolls back its own wish', () async {
    final (api, _, profile) = await _profile();
    api.gate = Completer<bool>();
    final gate = api.gate!;
    final first = profile.choose(loaf.PresenceChoice.idle);
    final firstFailed = expectLater(first, throwsA(anything));
    await profile.choose(loaf.PresenceChoice.invisible);
    gate.complete(false);
    await firstFailed;
    expect(profile.choice, loaf.PresenceChoice.invisible);
  });

  test('a refused choice with nothing newer goes back', () async {
    final (api, _, profile) = await _profile();
    api.gate = Completer<bool>()..complete(false);
    await expectLater(
      profile.choose(loaf.PresenceChoice.idle),
      throwsA(anything),
    );
    expect(profile.choice, loaf.PresenceChoice.online);
  });

  test('a refused status goes back and throws', () async {
    final (api, _, profile) = await _profile();
    api.gate = Completer<bool>()..complete(false);
    await expectLater(profile.setStatus('baking'), throwsA(anything));
    expect(profile.status, '');
  });

  test('disposing mid-save notifies nothing', () async {
    final (api, _, profile) = await _profile();
    api.gate = Completer<bool>();
    final gate = api.gate!;
    var heard = 0;
    profile.addListener(() => heard++);
    final saving = profile
        .choose(loaf.PresenceChoice.idle)
        .then<void>((_) {}, onError: (Object _) {});
    expect(heard, 1);
    profile.dispose();
    gate.complete(false);
    await saving;
    await _settle();
    expect(heard, 1);
  });
}
