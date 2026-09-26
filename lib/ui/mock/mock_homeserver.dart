/// The sign-in screen's fake homeserver — mockup only. Answers from
/// [mockServers] after short delays, standing in for `.well-known`,
/// `/versions` and `/login`. See "Sign-in and verification" in the design
/// spec.
library;

import 'dart:async';

import '../auth/homeserver.dart';
import '../auth/sign_in_state.dart';
import 'accounts.dart';

class MockHomeserver implements Homeserver {
  MockHomeserver({this.servers = mockServers, this.consumeFailure = _never});

  static bool _never() => false;

  static const probeDelay = Duration(milliseconds: 700);
  static const browserDelay = Duration(seconds: 3);
  static const ssoSheetDelay = Duration(milliseconds: 900);
  static const passwordDelay = Duration(milliseconds: 700);
  static const rateLimit = Duration(seconds: 30);

  /// Wrong passwords in a row before the server stops checking for a while.
  static const triesBeforeLimit = 3;

  final Map<String, ServerCheck> servers;

  /// The debug "fail the next connection" lever, spent by the next password.
  final bool Function() consumeFailure;

  final _timers = <Timer>{};
  var _wrongInARow = 0;

  Completer<SignInOutcome>? _sso;
  Timer? _ssoTimer;
  var _ssoDelay = Duration.zero;
  void Function()? _ssoCommitting;

  Future<T> _later<T>(Duration delay, T Function() answer) {
    final done = Completer<T>();
    late final Timer timer;
    timer = Timer(delay, () {
      _timers.remove(timer);
      done.complete(answer());
    });
    _timers.add(timer);
    return done.future;
  }

  @override
  Future<ServerCheck> probe(String server) {
    // A tally of wrong tries belongs to the server that kept it.
    _wrongInARow = 0;
    return _later(
      probeDelay,
      () => servers[server] ?? const ServerFailed(ServerProblem.unreachable),
    );
  }

  @override
  Future<SignInOutcome> password(
    String server,
    String user,
    String password, {
    void Function()? onCommitting,
  }) => _later(passwordDelay, () {
    final wrong = password == mockWrongPassword || consumeFailure();
    if (!wrong) {
      _wrongInARow = 0;
      onCommitting?.call();
      return const SignedIn();
    }
    if (++_wrongInARow >= triesBeforeLimit) {
      _wrongInARow = 0;
      return const RateLimited(rateLimit);
    }
    return const WrongPassword();
  });

  @override
  Future<SignInOutcome> sso(
    String server,
    IdentityProvider provider, {
    required bool desktop,
    void Function()? onCommitting,
  }) {
    cancelSso();
    final done = _sso = Completer<SignInOutcome>();
    _ssoDelay = desktop ? browserDelay : ssoSheetDelay;
    _ssoCommitting = onCommitting;
    _waitForSso();
    return done.future;
  }

  void _waitForSso() {
    _ssoTimer?.cancel();
    _ssoTimer = Timer(_ssoDelay, () {
      final done = _sso;
      _sso = null;
      _ssoCommitting?.call();
      done?.complete(const SignedIn());
    });
  }

  /// Opening the browser again restarts the wait rather than stacking a
  /// second one.
  @override
  void reopenSso() {
    if (_sso != null) _waitForSso();
  }

  @override
  void cancelSso() {
    _ssoTimer?.cancel();
    final done = _sso;
    _sso = null;
    done?.complete(const SignInCancelled());
  }

  @override
  void close() {
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    cancelSso();
  }
}
