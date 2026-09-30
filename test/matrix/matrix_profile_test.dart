import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:loaf_native/matrix/matrix_profile.dart';
import 'package:loaf_native/matrix/matrix_rooms.dart';
import 'package:loaf_native/ui/members/presence.dart' as loaf;
import 'package:loaf_native/ui/shell/profile.dart'
    show AccountSaveFailed, HalfApplied;
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

  /// Everything that changes do not disturb, in the order it arrived:
  /// `mute:true`, `presence:busy`, `account:{...}`.
  final log = <String>[];
  Client? client;
  var refuseBusy = false;
  var refuseMute = false;

  /// Profile writes and uploads, in order: `PUT displayname {…}`,
  /// `POST upload`, `PUT avatar_url {…}`.
  final wire = <String>[];
  var refuseName = false;

  /// Holds the next display name write until completed.
  Completer<void>? nameGate;

  @override
  FutureOr<http.Response> mockIntercept(http.Request request) async {
    final path = request.url.path;
    if (request.method == 'PUT' &&
        path.endsWith('/pushrules/global/override/.m.rule.master/enabled')) {
      final enabled =
          (jsonDecode(request.body) as Map<String, Object?>)['enabled'];
      log.add('mute:$enabled');
      if (refuseMute) return _refused('M_UNKNOWN', 500);
      // A real server echoes the rule on the next sync.
      await client!.handleSync(
        SyncUpdate.fromJson({
          'next_batch': 'r${_batches++}',
          'account_data': {
            'events': [
              {
                'type': 'm.push_rules',
                'content': {
                  'global': {
                    'override': [
                      {
                        'rule_id': '.m.rule.master',
                        'default': true,
                        'enabled': enabled,
                        'conditions': <Object?>[],
                        'actions': ['dont_notify'],
                      },
                    ],
                  },
                },
              },
            ],
          },
        }),
      );
      return http.Response(jsonEncode({}), 200);
    }
    if (request.method == 'PUT' && path.endsWith('/displayname')) {
      wire.add('PUT displayname ${request.body}');
      final hold = nameGate;
      nameGate = null;
      if (hold != null) await hold.future;
      if (refuseName) return _refused('M_UNKNOWN', 500);
      return http.Response(jsonEncode({}), 200);
    }
    if (request.method == 'POST' && path.contains('/media/v3/upload')) {
      wire.add('POST upload');
      return http.Response(
        jsonEncode({'content_uri': 'mxc://fakeServer.notExisting/new'}),
        200,
      );
    }
    if (request.method == 'PUT' && path.endsWith('/avatar_url')) {
      wire.add('PUT avatar_url ${request.body}');
      return http.Response(jsonEncode({}), 200);
    }
    if (request.method == 'PUT' &&
        path.endsWith('/account_data/moe.loaf.presence')) {
      log.add('account:${request.body}');
    }
    if (request.method == 'PUT' &&
        request.url.path.contains('/presence/') &&
        request.url.path.endsWith('/status')) {
      final body = jsonDecode(request.body) as Map<String, Object?>;
      bodies.add(body);
      log.add('presence:${body['presence']}');
      if (refuseBusy && body['presence'] == 'busy') {
        return _refused('M_INVALID_PARAM', 400);
      }
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
  api.client = client;
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

/// Account data as a sync brings it, master rule included.
Future<void> _remote(
  Client client, {
  String? choice,
  required bool muted,
}) async {
  await client.handleSync(
    SyncUpdate.fromJson({
      'next_batch': 'a${_batches++}',
      'account_data': {
        'events': [
          if (choice != null)
            {
              'type': 'moe.loaf.presence',
              'content': {'choice': choice},
            },
          {
            'type': 'm.push_rules',
            'content': {
              'global': {
                'override': [
                  {
                    'rule_id': '.m.rule.master',
                    'default': true,
                    'enabled': muted,
                    'conditions': <Object?>[],
                    'actions': ['dont_notify'],
                  },
                ],
              },
            },
          },
        ],
      },
    }),
  );
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

  test('a status set on another device is followed and kept', () async {
    final (api, client, profile) = await _profile();
    await _presence(client, _me, {
      'presence': 'online',
      'status_msg': 'from desktop',
    });
    expect(profile.status, 'from desktop');
    expect(profile.me.statusMessage, 'from desktop');
    // The next automatic idle carries it rather than this device's old text.
    profile.away(true);
    await _settle();
    expect(api.bodies.last['status_msg'], 'from desktop');
  });

  test('your own older presence never undoes a status in flight', () async {
    final (api, client, profile) = await _profile();
    api.gate = Completer<bool>();
    final gate = api.gate!;
    final setting = profile.setStatus('baking');
    await _presence(client, _me, {
      'presence': 'online',
      'status_msg': 'old text',
    });
    expect(profile.status, 'baking');
    gate.complete(true);
    await setting;
    expect(profile.status, 'baking');
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

  group('do not disturb', () {
    test('dnd sends busy and mutes every device', () async {
      final (api, client, profile) = await _profile();
      api.log.clear();
      await profile.choose(loaf.PresenceChoice.dnd);
      await _settle();
      expect(api.bodies.last['presence'], 'busy');
      expect(api.log, contains('mute:true'));
      expect(api.log, contains('account:{"choice":"dnd"}'));
      expect(client.syncPresence, PresenceType.unavailable);
      expect(profile.choice, loaf.PresenceChoice.dnd);
    });

    test('a server that refuses busy gets unavailable', () async {
      final (api, _, profile) = await _profile();
      api.refuseBusy = true;
      api.log.clear();
      await profile.choose(loaf.PresenceChoice.dnd);
      await _settle();
      expect(api.log.where((e) => e.startsWith('presence:')), [
        'presence:busy',
        'presence:unavailable',
      ]);
      expect(api.log, contains('mute:true'));
      expect(profile.choice, loaf.PresenceChoice.dnd);
    });

    test('leaving dnd unmutes first', () async {
      final (api, _, profile) = await _profile();
      await profile.choose(loaf.PresenceChoice.dnd);
      await _settle();
      api.log.clear();
      await profile.choose(loaf.PresenceChoice.online);
      await _settle();
      expect(api.log.take(2), ['mute:false', 'presence:online']);
      expect(api.log, contains('account:{"choice":"online"}'));
      expect(profile.choice, loaf.PresenceChoice.online);
    });

    test('a refused mute is half-applied', () async {
      final (api, _, profile) = await _profile();
      api.refuseMute = true;
      await expectLater(
        profile.choose(loaf.PresenceChoice.dnd),
        throwsA(isA<HalfApplied>()),
      );
      expect(profile.choice, loaf.PresenceChoice.online);
    });

    test(
      'a refused busy with a landed mute is half-applied, and muted',
      () async {
        final (api, _, profile) = await _profile();
        api.refuseWith = (errcode: 'M_UNKNOWN', status: 500);
        await expectLater(
          profile.choose(loaf.PresenceChoice.dnd),
          throwsA(isA<HalfApplied>()),
        );
        // The devices are silenced, so that is what the choice says.
        expect(profile.choice, loaf.PresenceChoice.dnd);
      },
    );

    test('every other choice is remembered too', () async {
      final (api, _, profile) = await _profile();
      api.log.clear();
      await profile.choose(loaf.PresenceChoice.idle);
      expect(api.log, contains('account:{"choice":"idle"}'));
    });

    test('dnd survives a restart', () async {
      final api = _Api();
      final client = await _client(api);
      await _remote(client, choice: 'dnd', muted: true);
      api.log.clear();
      final profile = MatrixProfile(client);
      addTearDown(profile.dispose);
      await _settle();
      expect(profile.choice, loaf.PresenceChoice.dnd);
      expect(api.log.where((e) => e.startsWith('mute:')), isEmpty);
      expect(api.log.where((e) => e.startsWith('account:')), isEmpty);
    });

    test('the push rule wins over account data', () async {
      final api = _Api();
      final client = await _client(api);
      await _remote(client, choice: 'dnd', muted: false);
      api.log.clear();
      final profile = MatrixProfile(client);
      addTearDown(profile.dispose);
      await _settle();
      expect(profile.choice, loaf.PresenceChoice.online);
      expect(api.log.where((e) => !e.startsWith('presence:')), isEmpty);

      await _remote(client, choice: 'idle', muted: true);
      expect(profile.choice, loaf.PresenceChoice.dnd);
      expect(api.log.where((e) => !e.startsWith('presence:')), isEmpty);
    });
  });

  group('away', () {
    test('away sends unavailable only while online', () async {
      final (api, client, profile) = await _profile();
      profile.away(true);
      await _settle();
      expect(api.bodies.last['presence'], 'unavailable');
      expect(client.syncPresence, PresenceType.unavailable);
      expect(profile.choice, loaf.PresenceChoice.online);

      await profile.choose(loaf.PresenceChoice.invisible);
      final sent = api.bodies.length;
      profile.away(false);
      await _settle();
      expect(api.bodies.length, sent + 1);
      expect(api.bodies.last['presence'], 'offline');

      profile.away(true);
      await _settle();
      expect(api.bodies, hasLength(sent + 1));
    });

    test('back restores the choice', () async {
      final (api, client, profile) = await _profile();
      profile.away(true);
      await _settle();
      profile.away(false);
      await _settle();
      expect(api.bodies.last['presence'], 'online');
      expect(client.syncPresence, PresenceType.online);
    });

    test('a refused away says nothing and changes nothing', () async {
      final (api, _, profile) = await _profile();
      api.refuseWith = (errcode: 'M_UNKNOWN', status: 500);
      var heard = 0;
      profile.addListener(() => heard++);
      profile.away(true);
      await _settle();
      expect(profile.choice, loaf.PresenceChoice.online);
      expect(heard, 0);
    });

    test('away after dispose does nothing', () async {
      final (api, _, profile) = await _profile();
      profile.dispose();
      final sent = api.bodies.length;
      profile.away(true);
      await _settle();
      expect(api.bodies, hasLength(sent));
    });
  });

  group('name and picture', () {
    final png = Uint8List.fromList([1, 2, 3]);

    test('the server has your name at start', () async {
      final (_, _, profile) = await _profile();
      expect(profile.displayName, 'Some First Name Some Last Name');
    });

    test('the rooms know you by the profile once it has loaded', () async {
      final api = _Api();
      final client = await _client(api);
      final rooms = MatrixRooms(client);
      addTearDown(rooms.dispose);
      rooms.profile;
      await _settle();
      await rooms.profile.saveAccount(displayName: 'Mochi', status: '');
      expect(rooms.me.name, 'Mochi');
    });

    test('saving sends only what changed', () async {
      final (api, _, profile) = await _profile();
      final sent = api.bodies.length;
      await profile.saveAccount(displayName: 'Mochi', status: profile.status);
      expect(api.wire, ['PUT displayname {"displayname":"Mochi"}']);
      expect(api.bodies, hasLength(sent));
      expect(profile.displayName, 'Mochi');
      expect(profile.savingAccount, isFalse);
    });

    test('a changed status alone sends no name', () async {
      final (api, _, profile) = await _profile();
      await profile.saveAccount(
        displayName: profile.displayName,
        status: 'baking',
      );
      expect(api.wire, isEmpty);
      expect(api.bodies.last['status_msg'], 'baking');
    });

    test('a refused name is named', () async {
      final (api, _, profile) = await _profile();
      api.refuseName = true;
      await expectLater(
        profile.saveAccount(displayName: 'Mochi', status: profile.status),
        throwsA(
          isA<AccountSaveFailed>()
              .having((e) => e.name, 'name', isTrue)
              .having((e) => e.status, 'status', isFalse),
        ),
      );
      expect(profile.displayName, 'Some First Name Some Last Name');
      expect(profile.savingAccount, isFalse);
    });

    test('both refused names both', () async {
      final (api, _, profile) = await _profile();
      api.refuseName = true;
      api.refuseWith = (errcode: 'M_UNKNOWN', status: 500);
      await expectLater(
        profile.saveAccount(displayName: 'Mochi', status: 'baking'),
        throwsA(
          isA<AccountSaveFailed>()
              .having((e) => e.name, 'name', isTrue)
              .having((e) => e.status, 'status', isTrue),
        ),
      );
    });

    test('an avatar goes up and is set', () async {
      final (api, _, profile) = await _profile();
      await profile.setAvatar(png);
      expect(api.wire, [
        'POST upload',
        'PUT avatar_url {"avatar_url":"mxc://fakeserver.notexisting/new"}',
      ]);
      expect(profile.uploadingAvatar, isFalse);
    });

    test('removing sends an empty avatar_url', () async {
      final (api, _, profile) = await _profile();
      await profile.setAvatar(null);
      expect(api.wire, ['PUT avatar_url {"avatar_url":""}']);
    });

    test('uploading is on while it is in flight', () async {
      final (_, _, profile) = await _profile();
      final done = profile.setAvatar(png);
      expect(profile.uploadingAvatar, isTrue);
      await done;
      expect(profile.uploadingAvatar, isFalse);
    });

    test(
      'a second avatar while one uploads is refused, not swallowed',
      () async {
        final (_, _, profile) = await _profile();
        final first = profile.setAvatar(png);
        await expectLater(profile.setAvatar(png), throwsStateError);
        await first;
        expect(profile.uploadingAvatar, isFalse);
      },
    );

    test('disposing mid-save notifies nothing', () async {
      final (api, _, profile) = await _profile();
      final gate = api.nameGate = Completer<void>();
      final saving = profile.saveAccount(
        displayName: 'Mochi',
        status: profile.status,
      );
      await _settle();
      var heard = 0;
      profile.addListener(() => heard++);
      profile.dispose();
      // The write was already in flight; releasing it must not touch us.
      gate.complete();
      await saving;
      await _settle();
      expect(heard, 0);
    });
  });
}
