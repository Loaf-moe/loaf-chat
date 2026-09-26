import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:loaf_native/matrix/matrix_homeserver.dart';
import 'package:loaf_native/matrix/sso_browser.dart';
import 'package:loaf_native/ui/auth/homeserver.dart';
import 'package:loaf_native/ui/auth/sign_in_state.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A browser that is never opened: SSO has its own tests.
class _NoBrowser implements SsoBrowser {
  String? token;
  Exception? failure;

  @override
  Future<String?> signIn(Uri Function(Uri redirect) urlFor) async {
    if (failure case final failure?) throw failure;
    return token;
  }

  @override
  void reopen() {}
  @override
  void cancel() {}
}

http.Response _ok(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

const _loginFlows = {
  'flows': [
    {'type': 'm.login.password'},
    {
      'type': 'm.login.sso',
      'identity_providers': [
        {'id': 'tuwunel', 'name': 'loaf.moe', 'brand': 'kanidm'},
      ],
    },
  ],
};

/// A server answering at `matrix.<name>` behind a well-known file, the way
/// loaf.moe does. [loginError] answers every POST /login.
MockClient _server({
  bool baseAnswers = true,
  Map<String, Object?>? loginError,
  int loginStatus = 403,
}) => MockClient((request) async {
  final path = request.url.path;
  if (path == '/.well-known/matrix/client') {
    return _ok({
      'm.homeserver': {'base_url': 'https://matrix.${request.url.host}/'},
    });
  }
  if (!request.url.host.startsWith('matrix.')) {
    return http.Response('<html>', 200);
  }
  if (!baseAnswers) throw const SocketException('connection refused');
  if (path == '/_matrix/client/versions') {
    return _ok({
      'versions': ['v1.19'],
    });
  }
  if (path == '/_matrix/client/v3/login' && request.method == 'GET') {
    return _ok(_loginFlows);
  }
  if (path == '/_matrix/client/v3/login' && loginError != null) {
    return http.Response(jsonEncode(loginError), loginStatus);
  }
  return http.Response('{}', 404);
});

/// [FakeMatrixApi] answering at `a.test` and `b.test` too, with no
/// well-known file so each name is its own base. `POST /login` on A waits
/// for [holdA] and answers with A's own token; everything else, B's login
/// included, is the fake's. [seen] records each request and its bearer.
class _TwoServers extends http.BaseClient {
  _TwoServers() {
    fake.servers.addAll({'https://a.test', 'https://b.test'});
  }

  final fake = FakeMatrixApi();
  final holdA = Completer<void>();
  final seen = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final url = request.url;
    seen.add(
      '${request.method} ${url.origin}${url.path} '
      '${request.headers['authorization'] ?? '-'}',
    );
    if (url.path == '/.well-known/matrix/client') {
      return http.StreamedResponse(const Stream.empty(), 404);
    }
    if (url.host == 'a.test' &&
        url.path == '/_matrix/client/v3/login' &&
        request.method == 'POST') {
      await holdA.future;
      return http.StreamedResponse(
        Stream.value(
          utf8.encode(
            jsonEncode({
              'user_id': '@test:a.test',
              'access_token': 'token-a',
              'device_id': 'DEVICEA',
            }),
          ),
        ),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return fake.send(request);
  }
}

Future<(MatrixHomeserver, _NoBrowser)> _make(http.Client http) async {
  final client = await openClient(
    httpClient: http,
    databasePath: inMemoryDatabasePath,
  );
  if (http is FakeMatrixApi || http is _TwoServers) {
    FakeMatrixApi.client = client;
  }
  await client.init(waitForFirstSync: false);
  addTearDown(client.dispose);
  final browser = _NoBrowser();
  return (
    MatrixHomeserver(client, browser: browser, deviceName: 'loaf on test'),
    browser,
  );
}

void main() {
  group('probe', () {
    test('follows .well-known and keeps the name typed', () async {
      final (hs, _) = await _make(_server());
      final check = await hs.probe('loaf.test');
      final flows = (check as ServerFound).flows;
      expect(flows.password, isTrue);
      expect(flows.providers.single.id, 'tuwunel');
      expect(flows.providers.single.name, 'loaf.moe');
    });

    test('nothing answering is unreachable', () async {
      final (hs, _) = await _make(
        MockClient((_) async => throw const SocketException('no route')),
      );
      final check = await hs.probe('nowhere.test') as ServerFailed;
      expect(check.problem, ServerProblem.unreachable);
    });

    test('nothing answering at the name is asked only once', () async {
      var requests = 0;
      final (hs, _) = await _make(
        MockClient((_) async {
          requests++;
          throw const SocketException('no route');
        }),
      );
      final check = await hs.probe('nowhere.test') as ServerFailed;
      expect(check.problem, ServerProblem.unreachable);
      expect(requests, 1);
    });

    test('a website with no matrix behind it is not matrix', () async {
      final (hs, _) = await _make(
        MockClient((_) async => http.Response('<html>', 404)),
      );
      final check = await hs.probe('example.com') as ServerFailed;
      expect(check.problem, ServerProblem.notMatrix);
    });

    test('a delegation to nothing names the host to fix', () async {
      final (hs, _) = await _make(_server(baseAnswers: false));
      final check = await hs.probe('broken.test') as ServerFailed;
      expect(check.problem, ServerProblem.delegationBroken);
      expect(check.delegatedTo, 'matrix.broken.test');
    });

    test('flowsFrom reads providers, names and bare sso', () {
      expect(flowsFrom(null).sso, isFalse);
      final bare = flowsFrom({
        'flows': [
          {'type': 'm.login.sso'},
        ],
      });
      expect(bare.providers.single.id, '');
      final unnamed = flowsFrom({
        'flows': [
          {
            'type': 'm.login.sso',
            'identity_providers': [
              {'id': 'oidc'},
              {'name': 'no id'},
            ],
          },
        ],
      });
      expect(unnamed.providers.single.name, 'oidc');
    });

    test('a malformed .well-known falls back to the name itself', () async {
      final (hs, _) = await _make(
        MockClient((request) async {
          if (request.url.path == '/.well-known/matrix/client') {
            return _ok({'m.homeserver': 'oops'});
          }
          if (request.url.path == '/_matrix/client/versions') {
            return _ok({
              'versions': ['v1.19'],
            });
          }
          return _ok({'flows': 'oops'});
        }),
      );
      final check = await hs.probe('odd.test');
      expect(check, isA<ServerFound>());
      expect((check as ServerFound).flows.sso, isFalse);
    });

    test('flowsFrom shrugs off wrong types', () {
      expect(flowsFrom({'flows': 'oops'}).password, isFalse);
      final odd = flowsFrom({
        'flows': [
          'oops',
          {'type': 'm.login.sso', 'identity_providers': 'oops'},
          {'type': 'm.login.password'},
        ],
      });
      expect(odd.password, isTrue);
      expect(odd.providers.single.id, '');
    });
  });

  group('password', () {
    test('signs the client in', () async {
      final (hs, _) = await _make(FakeMatrixApi());
      await hs.probe('fakeServer.notExisting');
      final outcome = await hs.password('fakeServer.notExisting', 'test', 'x');
      expect(outcome, isA<SignedIn>());
      expect(hs.client.isLogged(), isTrue);
    });

    test('M_FORBIDDEN is a wrong password', () async {
      final (hs, _) = await _make(
        _server(loginError: {'errcode': 'M_FORBIDDEN', 'error': 'nope'}),
      );
      await hs.probe('loaf.test');
      expect(
        await hs.password('loaf.test', 'chris', 'x'),
        isA<WrongPassword>(),
      );
    });

    test('M_LIMIT_EXCEEDED counts down whole seconds', () async {
      final (hs, _) = await _make(
        _server(
          loginStatus: 429,
          loginError: {'errcode': 'M_LIMIT_EXCEEDED', 'retry_after_ms': 2500},
        ),
      );
      await hs.probe('loaf.test');
      final outcome = await hs.password('loaf.test', 'chris', 'x');
      expect((outcome as RateLimited).retryIn, const Duration(seconds: 3));
    });

    test('a server never probed is not signed in to', () async {
      final (hs, _) = await _make(_server());
      expect(await hs.password('loaf.test', 'chris', 'x'), isA<SignInFailed>());
    });

    test('a login answered after close signs nothing in', () async {
      final servers = _TwoServers();
      final (hs, _) = await _make(servers);
      await hs.probe('a.test');
      final pending = hs.password('a.test', 'test', 'x');
      hs.close();
      servers.holdA.complete();
      expect(await pending, isNot(isA<SignedIn>()));
      expect(hs.client.isLogged(), isFalse);
    });

    test('a login to one server never lands on another', () async {
      final servers = _TwoServers();
      final (a, _) = await _make(servers);
      final b = MatrixHomeserver(
        a.client,
        browser: _NoBrowser(),
        deviceName: 'loaf on test',
      );
      await a.probe('a.test');
      final pendingA = a.password('a.test', 'test', 'x');
      a.close();
      await b.probe('b.test');
      expect(await b.password('b.test', 'test', 'x'), isA<SignedIn>());
      servers.holdA.complete();
      expect(await pendingA, isNot(isA<SignedIn>()));
      final client = a.client;
      expect(client.homeserver, Uri.parse('https://b.test'));
      expect(client.isLogged(), isTrue);
      expect(client.accessToken, isNot('token-a'));
      // A's stale token was spent on A, and never carried to B.
      expect(
        servers.seen,
        contains('POST https://a.test/_matrix/client/v3/logout Bearer token-a'),
      );
      expect(
        servers.seen.where(
          (s) => s.contains('token-a') && !s.startsWith('POST https://a.test'),
        ),
        isEmpty,
      );
    });

    test('a changed question makes a pending login stale', () async {
      final servers = _TwoServers();
      final (hs, _) = await _make(servers);
      await hs.probe('a.test');
      final pending = hs.password('a.test', 'test', 'x');
      await hs.probe('b.test');
      servers.holdA.complete();
      expect(await pending, isA<SignInCancelled>());
      expect(hs.client.isLogged(), isFalse);
    });

    test('retryIn rounds up and defaults', () {
      expect(retryIn(1), const Duration(seconds: 1));
      expect(retryIn(null), const Duration(seconds: 30));
    });
  });

  group('sso', () {
    test('the redirect names the provider and comes back here', () {
      final url = ssoUrl(
        'https://matrix.loaf.moe',
        const IdentityProvider('tuwunel', 'loaf.moe'),
        Uri.parse('http://127.0.0.1:5000/sso'),
      );
      expect(
        url.toString(),
        'https://matrix.loaf.moe/_matrix/client/v3/login/sso/redirect/tuwunel'
        '?redirectUrl=http%3A%2F%2F127.0.0.1%3A5000%2Fsso',
      );
      expect(
        ssoUrl(
          'https://x.test',
          const IdentityProvider('', 'single sign-on'),
          Uri.parse('moe.loaf.native://sso'),
        ).path,
        '/_matrix/client/v3/login/sso/redirect',
      );
    });

    test('a token from the browser signs in', () async {
      final (hs, browser) = await _make(FakeMatrixApi());
      await hs.probe('fakeServer.notExisting');
      browser.token = 'abc';
      final outcome = await hs.sso(
        'fakeServer.notExisting',
        const IdentityProvider('tuwunel', 'loaf.moe'),
        desktop: true,
      );
      expect(outcome, isA<SignedIn>());
    });

    test('giving up is a cancel, not an error', () async {
      final (hs, _) = await _make(FakeMatrixApi());
      await hs.probe('fakeServer.notExisting');
      final outcome = await hs.sso(
        'fakeServer.notExisting',
        const IdentityProvider('tuwunel', 'loaf.moe'),
        desktop: false,
      );
      expect(outcome, isA<SignInCancelled>());
    });
    test('a browser that fails is a failure, not a throw', () async {
      final (hs, browser) = await _make(FakeMatrixApi());
      await hs.probe('fakeServer.notExisting');
      browser.failure = const SocketException('bind failed');
      final outcome = await hs.sso(
        'fakeServer.notExisting',
        const IdentityProvider('tuwunel', 'loaf.moe'),
        desktop: true,
      );
      expect(
        (outcome as SignInFailed).message,
        "couldn't open the sign-in page",
      );
    });
  });

  group('onCommitting', () {
    test(
      'is called exactly once on a successful sign-in, before isLogged is true',
      () async {
        final (hs, _) = await _make(FakeMatrixApi());
        await hs.probe('fakeServer.notExisting');
        var calls = 0;
        bool? loggedDuringCommit;
        final outcome = await hs.password(
          'fakeServer.notExisting',
          'test',
          'x',
          onCommitting: () {
            calls++;
            loggedDuringCommit = hs.client.isLogged();
          },
        );
        expect(outcome, isA<SignedIn>());
        expect(calls, 1);
        expect(loggedDuringCommit, isFalse);
      },
    );

    test('is not called for M_FORBIDDEN', () async {
      final (hs, _) = await _make(
        _server(loginError: {'errcode': 'M_FORBIDDEN', 'error': 'nope'}),
      );
      await hs.probe('loaf.test');
      var called = false;
      final outcome = await hs.password(
        'loaf.test',
        'chris',
        'x',
        onCommitting: () => called = true,
      );
      expect(outcome, isA<WrongPassword>());
      expect(called, isFalse);
    });

    test(
      'is not called when the attempt is abandoned before /login answers',
      (() async {
        final servers = _TwoServers();
        final (hs, _) = await _make(servers);
        await hs.probe('a.test');
        var called = false;
        final pending = hs.password(
          'a.test',
          'test',
          'x',
          onCommitting: () => called = true,
        );
        hs.close();
        servers.holdA.complete();
        expect(await pending, isNot(isA<SignedIn>()));
        expect(called, isFalse);
      }),
    );
  });
}
