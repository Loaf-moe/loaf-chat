import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:loaf_native/matrix/call_access.dart';
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _me = '@test:fakeServer.notExisting';
const _room = '!oven:example.com';

Map<String, Object?> _livekit(Object? url) => {
  'type': 'livekit',
  'livekit_service_url': url,
};

http.Response _json(Object? body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

/// The fake homeserver with a well-known file, a call server beside it, and
/// OpenID tokens that differ each time one is asked for.
class _Api extends FakeMatrixApi {
  /// What the homeserver's well-known file answers.
  http.Response wellKnown = _json({
    'org.matrix.msc4143.rtc_foci': [_livekit('https://calls.example.com')],
  });

  /// Where the well-known file was asked for.
  final wellKnownAsked = <Uri>[];

  /// What the call server answers.
  http.Response answer = _json({
    'url': 'wss://sfu.example.com',
    'jwt': 'a.b.c',
  });

  /// What the call server was sent.
  final asked = <http.Request>[];

  var _tokens = 0;

  @override
  FutureOr<http.Response> mockIntercept(http.Request request) async {
    if (request.url.path == '/.well-known/matrix/client') {
      wellKnownAsked.add(request.url);
      return wellKnown;
    }
    if (request.url.host == 'calls.example.com') {
      asked.add(request);
      return answer;
    }
    if (request.url.path.endsWith('/openid/request_token')) {
      return _json({
        'access_token': 'token${_tokens++}',
        'token_type': 'Bearer',
        'matrix_server_name': 'fakeServer.notExisting',
        'expires_in': 3600,
      });
    }
    return super.mockIntercept(request);
  }

  Map<String, Object?> body(int index) =>
      jsonDecode(asked[index].body) as Map<String, Object?>;
}

/// A client on the fake homeserver, signed in unless [signedIn] is false.
Future<Client> _client(_Api api, {bool signedIn = true}) async {
  final client = await openClient(
    httpClient: api,
    databasePath: inMemoryDatabasePath,
  );
  addTearDown(client.dispose);
  if (!signedIn) return client;
  FakeMatrixApi.client = client;
  await client.init(
    newToken: 'abcd',
    newHomeserver: Uri.parse('https://fakeServer.notExisting'),
    newUserID: _me,
    newDeviceID: 'GHTYAJCE',
    newDeviceName: 'loaf on test',
  );
  return client;
}

/// The call server the homeserver names when its well-known file is [file].
Future<Uri> _named(http.Response file) async =>
    callServer(await _client(_Api()..wellKnown = file));

final _server = Uri.parse('https://calls.example.com/livekit');

void main() {
  group('the call server a homeserver names', () {
    test('is asked of the well-known file at your own server name', () async {
      final api = _Api();

      await callServer(await _client(api));

      expect(api.wellKnownAsked, [
        Uri.parse('https://fakeserver.notexisting/.well-known/matrix/client'),
      ]);
    });

    test('is its LiveKit focus', () async {
      final server = await _named(
        _json({
          'org.matrix.msc4143.rtc_foci': [
            _livekit('https://calls.example.com'),
          ],
        }),
      );

      expect(server, Uri.parse('https://calls.example.com'));
    });

    test('is the first LiveKit focus, past those of other kinds', () async {
      final server = await _named(
        _json({
          'org.matrix.msc4143.rtc_foci': [
            {'type': 'mesh'},
            _livekit('https://first.example.com'),
            _livekit('https://second.example.com'),
          ],
        }),
      );

      expect(server, Uri.parse('https://first.example.com'));
    });

    group('is not a focus whose address is', () {
      const addresses = <String, Object?>{
        'no text': 42,
        'empty': '',
        'blank': '   ',
        'a bare name': 'calls.example.com',
        'a path alone': '/livekit',
        'not for the web': 'ftp://calls.example.com',
      };
      for (final MapEntry(key: name, value: address) in addresses.entries) {
        test(name, () async {
          final server = await _named(
            _json({
              'org.matrix.msc4143.rtc_foci': [
                _livekit(address),
                _livekit('https://calls.example.com'),
              ],
            }),
          );

          expect(server, Uri.parse('https://calls.example.com'));
        });
      }
    });

    test('is none when it lists no focus', () async {
      expect(
        _named(_json({'m.homeserver': <String, Object?>{}})),
        throwsA(isA<NoCallServer>()),
      );
    });

    test('is none when its well-known file is not JSON', () async {
      expect(
        _named(http.Response('<html></html>', 200)),
        throwsA(isA<NoCallServer>()),
      );
    });

    test('is none when it has no well-known file', () async {
      expect(
        _named(http.Response('not found', 404)),
        throwsA(isA<NoCallServer>()),
      );
    });

    test('is unknown, not none, when the homeserver fails to answer', () async {
      expect(
        _named(http.Response('oops', 500)),
        throwsA(
          isA<WellKnownUnavailable>().having((e) => e.status, 'status', 500),
        ),
      );
    });

    test('cannot be asked for when signed out', () async {
      final client = await _client(_Api(), signedIn: false);

      expect(callServer(client), throwsA(isA<NotSignedIn>()));
    });
  });

  group('access to a room\'s call', () {
    test('is asked for at /sfu/get under the call server', () async {
      final api = _Api();
      final client = await _client(api);

      await sfuAccess(client, _server, _room);

      expect(api.asked.single.method, 'POST');
      expect(
        api.asked.single.url.toString(),
        'https://calls.example.com/livekit/sfu/get',
      );
    });

    group('is asked for at the same place when the server', () {
      const servers = {
        'ends in a slash': 'https://calls.example.com/livekit/',
        'carries a query': 'https://calls.example.com/livekit?region=eu',
        'carries a fragment': 'https://calls.example.com/livekit#top',
      };
      for (final MapEntry(key: name, value: server) in servers.entries) {
        test(name, () async {
          final api = _Api();
          final client = await _client(api);

          await sfuAccess(client, Uri.parse(server), _room);

          expect(
            api.asked.single.url.toString(),
            'https://calls.example.com/livekit/sfu/get',
          );
        });
      }
    });

    test(
      'names the room, this device and the OpenID token as issued',
      () async {
        final api = _Api();
        final client = await _client(api);

        await sfuAccess(client, _server, _room);

        expect(api.body(0), {
          'room': _room,
          'device_id': 'GHTYAJCE',
          'openid_token': {
            'access_token': 'token0',
            'token_type': 'Bearer',
            'matrix_server_name': 'fakeServer.notExisting',
            'expires_in': 3600,
          },
        });
      },
    );

    test('is the address and token the call server answers with', () async {
      final client = await _client(_Api());

      final access = await sfuAccess(client, _server, _room);

      expect(access.url, Uri.parse('wss://sfu.example.com'));
      expect(access.jwt, 'a.b.c');
    });

    test('takes a new OpenID token each time', () async {
      final api = _Api();
      final client = await _client(api);

      await sfuAccess(client, _server, _room);
      await sfuAccess(client, _server, _room);

      final tokens = [
        for (final i in [0, 1])
          (api.body(i)['openid_token'] as Map)['access_token'],
      ];
      expect(tokens, ['token0', 'token1']);
    });

    test('that fails says with what status and error code', () async {
      final api = _Api()
        ..answer = _json({
          'errcode': 'M_FORBIDDEN',
          'error': 'not in the room',
        }, 403);
      final client = await _client(api);

      expect(
        sfuAccess(client, _server, _room),
        throwsA(
          isA<CallServerError>()
              .having((e) => e.status, 'status', 403)
              .having((e) => e.errcode, 'errcode', 'M_FORBIDDEN'),
        ),
      );
    });

    test('that fails with no JSON says the status alone', () async {
      final api = _Api()..answer = http.Response('bad gateway', 502);
      final client = await _client(api);

      expect(
        sfuAccess(client, _server, _room),
        throwsA(
          isA<CallServerError>()
              .having((e) => e.status, 'status', 502)
              .having((e) => e.errcode, 'errcode', isNull),
        ),
      );
    });

    group('answered without', () {
      const answers = <String, Object?>{
        'an address': {'jwt': 'a.b.c'},
        'a token': {'url': 'wss://sfu.example.com'},
        'an address that is text': {'url': 7, 'jwt': 'a.b.c'},
        'a token that is text': {'url': 'wss://sfu.example.com', 'jwt': 7},
        'a token of any length': {'url': 'wss://sfu.example.com', 'jwt': ''},
        'an address a call can reach': {
          'url': 'sfu.example.com',
          'jwt': 'a.b.c',
        },
        'an address for calls': {
          'url': 'ftp://sfu.example.com',
          'jwt': 'a.b.c',
        },
        'an object at all': ['wss://sfu.example.com', 'a.b.c'],
      };
      for (final MapEntry(key: name, value: answer) in answers.entries) {
        test('$name is malformed', () async {
          final api = _Api()..answer = _json(answer);
          final client = await _client(api);

          expect(
            sfuAccess(client, _server, _room),
            throwsA(isA<CallServerMalformed>()),
          );
        });
      }
    });

    test('cannot be asked for when signed out', () async {
      final api = _Api();
      final client = await _client(api, signedIn: false);

      await expectLater(
        sfuAccess(client, _server, _room),
        throwsA(isA<NotSignedIn>()),
      );
      expect(api.asked, isEmpty);
    });
  });
}
