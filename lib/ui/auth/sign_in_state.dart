/// What the sign-in screen can be showing, as plain values. The mock
/// controller produces these on timers; the real one will produce them from
/// `.well-known`, `/versions` and `/login`. See "Sign-in and verification" in
/// the design spec.
library;

import 'package:flutter/widgets.dart';

import '../mock/fixtures.dart';

/// An `m.login.sso` identity provider.
@immutable
class IdentityProvider {
  const IdentityProvider(this.id, this.name);

  final String id;
  final String name;

  /// Stands in for the provider's icon, an mxc URL the mock cannot load.
  String get initial => name.characters.first.toUpperCase();
}

/// What `GET /login` advertised.
@immutable
class ServerFlows {
  const ServerFlows({this.providers = const [], this.password = false});

  final List<IdentityProvider> providers;
  final bool password;

  bool get sso => providers.isNotEmpty;
}

/// The ways discovery fails, told apart because the last is a self-hoster's
/// misconfiguration and names the host to go and fix.
enum ServerProblem { unreachable, notMatrix, delegationBroken }

@immutable
sealed class ServerCheck {
  const ServerCheck();
}

class ServerProbing extends ServerCheck {
  const ServerProbing();
}

class ServerFound extends ServerCheck {
  const ServerFound(this.flows);

  final ServerFlows flows;
}

class ServerFailed extends ServerCheck {
  const ServerFailed(this.problem, {this.delegatedTo});

  final ServerProblem problem;

  /// The base URL `.well-known` named, for [ServerProblem.delegationBroken].
  final String? delegatedTo;

  String messageFor(String server) => switch (problem) {
    ServerProblem.unreachable => 'nothing answered at $server',
    ServerProblem.notMatrix => "$server isn't a matrix server",
    ServerProblem.delegationBroken =>
      "$server points to $delegatedTo, which didn't answer",
  };
}

/// What the screen is in the middle of, beyond showing the ways in.
enum SignInActivity {
  idle,

  /// Desktop: the real browser has the SSO page.
  inBrowser,

  /// Phone: the system sign-in sheet, which the mock cannot draw.
  finishingSso,

  checkingPassword,

  /// The server said yes; the app is about to take over. The button stays
  /// busy rather than flashing back to "sign in" for a frame.
  signedIn,
}

/// An account whose token the server expired (`soft_logout: true`). Its keys
/// are still on this device, so the screen is locked to it.
@immutable
class SoftLogout {
  const SoftLogout({required this.member, required this.userId});

  final Member member;
  final String userId;
}

@immutable
class SignInState {
  const SignInState({
    required this.server,
    required this.check,
    this.activity = SignInActivity.idle,
    this.provider,
    this.wrongPassword = false,
    this.retryIn,
    this.softLogout,
    this.repointing,
    this.failure,
  });

  /// As typed, never the delegated base URL.
  final String server;
  final ServerCheck check;
  final SignInActivity activity;

  /// The provider SSO went to, while [activity] is not idle.
  final IdentityProvider? provider;

  /// `M_FORBIDDEN` from the last attempt.
  final bool wrongPassword;

  /// `M_LIMIT_EXCEEDED`: how long until the server will check again.
  final Duration? retryIn;

  final SoftLogout? softLogout;

  /// A server a full user id in the username field names, being looked for
  /// while the form stays put.
  final String? repointing;

  /// The last attempt went wrong in a way that is neither a wrong password
  /// nor a rate limit — nothing answered, or SSO came back empty — worded
  /// for the screen.
  final String? failure;

  SignInState copyWith({
    SignInActivity? activity,
    IdentityProvider? provider,
    bool? wrongPassword,
    Duration? retryIn,
    bool clearRetry = false,
    String? repointing,
    String? failure,
    bool clearFailure = false,
  }) => SignInState(
    server: server,
    check: check,
    activity: activity ?? this.activity,
    provider: provider ?? this.provider,
    wrongPassword: wrongPassword ?? this.wrongPassword,
    retryIn: clearRetry ? null : (retryIn ?? this.retryIn),
    softLogout: softLogout,
    repointing: repointing ?? this.repointing,
    failure: clearFailure ? null : (failure ?? this.failure),
  );
}

/// The server name in whatever was typed into the homeserver field: a name,
/// a URL or a full user id. Null while there is not yet a name in it, since
/// half-typed input is the normal case, not an error.
String? serverNameFrom(String input) {
  var s = input.trim();
  if (s.isEmpty) return null;
  if (s.startsWith('@')) return serverFromUserId(s);
  s = s.replaceFirst(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://'), '');
  s = s.split('/').first;
  return _plausibleHost(s) ? s.toLowerCase() : null;
}

/// The domain of a full user id (`@chris:loaf.moe`), or null if [input] is
/// not one yet.
String? serverFromUserId(String input) {
  final s = input.trim();
  if (!s.startsWith('@')) return null;
  final colon = s.indexOf(':');
  // A localpart comes before the colon.
  if (colon < 2) return null;
  final host = s.substring(colon + 1);
  return _plausibleHost(host) ? host.toLowerCase() : null;
}

/// A dot with something either side (or localhost), an optional port, and
/// no spaces. Good enough to be worth probing; the probe decides the rest.
bool _plausibleHost(String s) {
  if (s.isEmpty || s.contains(RegExp(r'\s'))) return false;
  final name = s.split(':').first;
  if (name == 'localhost') return true;
  final dot = name.indexOf('.');
  return dot > 0 && dot < name.length - 1 && !name.endsWith('.');
}
