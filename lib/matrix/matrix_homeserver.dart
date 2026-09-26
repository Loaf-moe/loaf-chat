/// The real [Homeserver]: discovery over plain HTTP, then sign-in through
/// the app's one [Client].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

import '../ui/auth/homeserver.dart';
import '../ui/auth/sign_in_state.dart';
import 'sso_browser.dart';

class MatrixHomeserver implements Homeserver {
  MatrixHomeserver(
    this.client, {
    required this.browser,
    required this.deviceName,
    http.Client? httpClient,
  }) : _http = httpClient ?? client.httpClient;

  final Client client;
  final SsoBrowser browser;

  /// What other sessions and "is this you?" call this device.
  final String deviceName;

  final http.Client _http;

  static const timeout = Duration(seconds: 15);

  /// Each probed name's base URL. Sign-in goes to the base its own name
  /// resolved to, whatever was probed since.
  final _bases = <String, String>{};

  // Discovery does not go through the SDK: Client.getVersions caches under
  // one key for every server, so probing a second server would read the
  // first one's answer, and checkHomeserver cannot tell a broken delegation
  // from nothing answering.
  @override
  Future<ServerCheck> probe(String server) async {
    _generation++;
    final named = 'https://$server';
    var base = named;
    String? delegatedTo;
    try {
      final wellKnown = await _json('$named/.well-known/matrix/client');
      final homeserver = wellKnown?['m.homeserver'];
      final url = homeserver is Map ? homeserver['base_url'] : null;
      if (url is String && Uri.tryParse(url)?.hasAuthority == true) {
        base = _trim(url);
        final host = Uri.parse(base).host;
        if (host != Uri.parse(named).host) delegatedTo = host;
      }
    } on _NoAnswer {
      // Nothing answered at the name at all, so asking it again for
      // /versions would only double the wait. A 404 or garbled file is an
      // answer, and falls through to the name itself.
      return const ServerFailed(ServerProblem.unreachable);
    }
    try {
      final versions = await _json('$base/_matrix/client/versions');
      if (versions?['versions'] is! List) {
        return const ServerFailed(ServerProblem.notMatrix);
      }
      final login = await _json('$base/_matrix/client/v3/login');
      _bases[server] = base;
      return ServerFound(flowsFrom(login));
    } on _NoAnswer {
      return delegatedTo == null
          ? const ServerFailed(ServerProblem.unreachable)
          : ServerFailed(
              ServerProblem.delegationBroken,
              delegatedTo: delegatedTo,
            );
    }
  }

  /// Bumped whenever the question changes or the person walks away, so an
  /// attempt can tell it is no longer the one being waited on.
  var _generation = 0;

  @override
  Future<SignInOutcome> password(String server, String user, String password) {
    final attempt = ++_generation;
    return _signIn(
      server,
      attempt,
      (api) => api.login(
        LoginType.mLoginPassword,
        identifier: AuthenticationUserIdentifier(user: user.trim()),
        password: password,
        initialDeviceDisplayName: deviceName,
        refreshToken: client.onSoftLogout != null,
      ),
    );
  }

  @override
  Future<SignInOutcome> sso(
    String server,
    IdentityProvider provider, {
    required bool desktop,
  }) async {
    final attempt = ++_generation;
    final base = _bases[server];
    if (base == null) return SignInFailed("couldn't reach $server");
    final String? token;
    try {
      token = await browser.signIn(
        (redirect) => ssoUrl(base, provider, redirect),
      );
    } on Exception {
      return const SignInFailed("couldn't open the sign-in page");
    }
    if (token == null || attempt != _generation) {
      return const SignInCancelled();
    }
    return _signIn(
      server,
      attempt,
      (api) => api.login(
        LoginType.mLoginToken,
        token: token,
        initialDeviceDisplayName: deviceName,
        refreshToken: client.onSoftLogout != null,
      ),
      // A refused token is not a wrong password.
      refused: "${provider.name} didn't finish signing you in",
    );
  }

  @override
  void reopenSso() => browser.reopen();

  @override
  void cancelSso() {
    _generation++;
    browser.cancel();
  }

  @override
  void close() {
    _generation++;
    browser.cancel();
  }

  // The request goes through a throwaway [MatrixApi], not the shared
  // [Client]: Client.login reads its homeserver only after /login answers,
  // so an attempt abandoned mid-flight could store its token against
  // whatever server a later attempt pointed the client at. The client is
  // only touched once this attempt is known to still be the current one.
  Future<SignInOutcome> _signIn(
    String server,
    int attempt,
    Future<LoginResponse> Function(MatrixApi api) login, {
    String? refused,
  }) async {
    final base = _bases[server];
    if (base == null) return SignInFailed("couldn't reach $server");
    final homeserver = Uri.parse(base);
    try {
      final response = await login(
        MatrixApi(homeserver: homeserver, httpClient: _http),
      );
      if (attempt != _generation) {
        await _spend(homeserver, response.accessToken);
        return const SignInCancelled();
      }
      final expiresInMs = response.expiresInMs;
      try {
        await client.init(
          newToken: response.accessToken,
          newTokenExpiresAt: expiresInMs == null
              ? null
              : DateTime.now().add(Duration(milliseconds: expiresInMs)),
          newRefreshToken: response.refreshToken,
          newUserID: response.userId,
          newHomeserver: homeserver,
          newDeviceName: deviceName,
          newDeviceID: response.deviceId,
          waitForFirstSync: false,
        );
      } on Exception {
        // Nothing kept the token, so nothing should be left signed in with it.
        await _spend(homeserver, response.accessToken);
        return SignInFailed("couldn't finish signing in to $server");
      }
      return const SignedIn();
    } on MatrixException catch (e) {
      return switch (e.error) {
        MatrixError.M_FORBIDDEN when refused == null => const WrongPassword(),
        MatrixError.M_LIMIT_EXCEEDED => RateLimited(retryIn(e.retryAfterMs)),
        _ => SignInFailed(refused ?? "$server said no: ${e.errorMessage}"),
      };
    } on Exception {
      return SignInFailed("couldn't reach $server");
    } on TypeError {
      // A 200 that is not a login answer.
      return SignInFailed("couldn't reach $server");
    }
  }

  /// Logs out a token nobody will use, so it leaves no orphan device behind.
  /// Best effort: a server that doesn't answer keeps it.
  Future<void> _spend(Uri homeserver, String token) async {
    try {
      await MatrixApi(
        homeserver: homeserver,
        accessToken: token,
        httpClient: _http,
      ).logout().timeout(timeout);
    } on Exception {
      // Nothing more to do.
    }
  }

  /// A 200 with a JSON object, or null for any other answer. Throws
  /// [_NoAnswer] when nothing answered at all.
  Future<Map<String, Object?>?> _json(String url) async {
    final http.Response response;
    try {
      response = await _http.get(Uri.parse(url)).timeout(timeout);
    } on Exception {
      throw const _NoAnswer();
    }
    if (response.statusCode != 200) return null;
    try {
      final body = jsonDecode(response.body);
      return body is Map<String, Object?> ? body : null;
    } on FormatException {
      return null;
    }
  }
}

class _NoAnswer implements Exception {
  const _NoAnswer();
}

/// A base URL with no trailing slash, so paths append cleanly even under a
/// path prefix.
String _trim(String url) => url.replaceFirst(RegExp(r'/+$'), '');

/// What `GET /login` offers that loaf can use.
@visibleForTesting
ServerFlows flowsFrom(Map<String, Object?>? login) {
  var password = false;
  final providers = <IdentityProvider>[];
  final flows = login?['flows'];
  for (final flow in (flows is List ? flows : const []).whereType<Map>()) {
    switch (flow['type']) {
      case 'm.login.password':
        password = true;
      case 'm.login.sso':
        final idps = flow['identity_providers'];
        final listed = (idps is List ? idps : const [])
            .whereType<Map>()
            .where((p) => p['id'] is String)
            .toList();
        // SSO with no providers listed redirects without choosing one.
        if (listed.isEmpty) {
          providers.add(const IdentityProvider('', 'single sign-on'));
        }
        for (final p in listed) {
          final name = p['name'];
          providers.add(
            IdentityProvider(
              p['id'] as String,
              name is String && name.isNotEmpty ? name : p['id'] as String,
            ),
          );
        }
    }
  }
  return ServerFlows(providers: providers, password: password);
}

@visibleForTesting
Uri ssoUrl(String base, IdentityProvider provider, Uri redirect) {
  final id = provider.id.isEmpty ? '' : '/${Uri.encodeComponent(provider.id)}';
  return Uri.parse('$base/_matrix/client/v3/login/sso/redirect$id')
      .replace(queryParameters: {'redirectUrl': redirect.toString()});
}

/// `retry_after_ms`, rounded up to the whole seconds the button counts in.
/// A server that names no wait gets thirty seconds.
@visibleForTesting
Duration retryIn(int? ms) =>
    Duration(seconds: max(1, ((ms ?? 30000) / 1000).ceil()));
