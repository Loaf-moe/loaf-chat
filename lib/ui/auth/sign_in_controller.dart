/// The sign-in screen's state machine: discovery, a full id re-pointing the
/// server, SSO and password sign-in, and the rate-limit countdown. What the
/// server says comes from a [Homeserver] — the mock's fixtures or the SDK —
/// so this file never knows which. See "Sign-in and verification" in the
/// design spec.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../mock/accounts.dart';
import '../mock/mock_homeserver.dart';
import '../platform.dart' as platform;
import 'homeserver.dart';
import 'sign_in_state.dart';

class SignInController extends ChangeNotifier {
  /// Starts probing [server] at once, the way the screen opens. Without a
  /// [homeserver], answers come from a [MockHomeserver] over [servers].
  SignInController({
    String server = 'loaf.moe',
    SoftLogout? softLogout,
    required this.onSignedIn,
    Homeserver? homeserver,
    bool Function() consumeFailure = _never,
    Map<String, ServerCheck> servers = mockServers,
    bool? ssoInBrowser,
  }) : homeserver =
           homeserver ??
           MockHomeserver(servers: servers, consumeFailure: consumeFailure),
       ssoInBrowser = ssoInBrowser ?? platform.ssoInBrowser,
       _state = SignInState(
         server: server,
         check: const ServerProbing(),
         softLogout: softLogout,
       ) {
    _probe();
  }

  /// Starts in [state] with nothing in flight, so a test can pin any face.
  @visibleForTesting
  SignInController.at(
    SignInState state, {
    VoidCallback? onSignedIn,
    Homeserver? homeserver,
    bool Function() consumeFailure = _never,
    Map<String, ServerCheck> servers = mockServers,
    bool? ssoInBrowser,
  }) : onSignedIn = onSignedIn ?? _nothing,
       homeserver =
           homeserver ??
           MockHomeserver(servers: servers, consumeFailure: consumeFailure),
       ssoInBrowser = ssoInBrowser ?? platform.ssoInBrowser,
       _state = state;

  static bool _never() => false;
  static void _nothing() {}

  // The mock's timings, kept here because the tests pace themselves by them.
  static const probeDelay = MockHomeserver.probeDelay;
  static const browserDelay = MockHomeserver.browserDelay;
  static const ssoSheetDelay = MockHomeserver.ssoSheetDelay;
  static const passwordDelay = MockHomeserver.passwordDelay;
  static const rateLimit = MockHomeserver.rateLimit;
  static const triesBeforeLimit = MockHomeserver.triesBeforeLimit;

  static const repointDebounce = Duration(milliseconds: 400);

  final VoidCallback onSignedIn;
  final Homeserver homeserver;

  /// Whether SSO goes to the real browser rather than the system sign-in
  /// window: true on Linux and Windows, false everywhere else.
  final bool ssoInBrowser;

  SignInState _state;
  SignInState get state => _state;

  /// Bumped whenever something new starts. An answer to an older question
  /// is dropped, so a stale reply can never sign in or jump a step.
  var _epoch = 0;
  Timer? _repoint;
  Timer? _countdown;

  /// A password submitted while a full id's server is being looked up. It
  /// goes to that server once found: the id says where the account lives.
  (String, String)? _queued;
  String? _repointTarget;

  void _set(SignInState s) {
    _state = s;
    notifyListeners();
  }

  /// Asks, and hands the answer to [then] only if nothing newer has started.
  void _ask<T>(Future<T> question, void Function(T answer) then) =>
      _askFor((_) => question, then);

  /// Like [_ask], but [question] is built from the epoch it will be asked
  /// under, so a callback threaded into it (an `onCommitting`) can tell
  /// later whether it is still the one being waited on.
  void _askFor<T>(
    Future<T> Function(int epoch) question,
    void Function(T answer) then,
  ) {
    final mine = ++_epoch;
    question(mine).then((answer) {
      if (mine == _epoch) then(answer);
    });
  }

  /// The server said yes and the attempt has passed the point where it can
  /// no longer be stopped: [SignInActivity.signedIn], if [epoch] is still
  /// current.
  void Function() _committed(int epoch) => () {
    if (epoch == _epoch) {
      _set(_state.copyWith(activity: SignInActivity.signedIn));
    }
  };

  /// The server picker's connect. Input that names no server is ignored.
  /// Once the point of no return has passed, nothing changes the outcome.
  void connect(String input) {
    if (_state.activity == SignInActivity.signedIn) return;
    final name = serverNameFrom(input);
    if (name == null) return;
    _repoint?.cancel();
    // A rate limit belongs to the server that set it.
    _countdown?.cancel();
    _queued = null;
    homeserver.cancelSso();
    _set(
      SignInState(
        server: name,
        check: const ServerProbing(),
        softLogout: _state.softLogout,
      ),
    );
    _probe();
  }

  void retry() => connect(_state.server);

  void _probe() {
    final server = _state.server;
    _ask(
      homeserver.probe(server),
      (ServerCheck check) => _set(
        SignInState(
          server: server,
          check: check,
          softLogout: _state.softLogout,
        ),
      ),
    );
  }

  /// A full user id typed as the username re-points the server once typing
  /// pauses. The form stays up while it looks; anything else leaves the
  /// server alone.
  void usernameChanged(String text) {
    _repoint?.cancel();
    final name = serverFromUserId(text);
    if (name == null || name == _state.server) return;
    _repointTarget = name;
    _repoint = Timer(repointDebounce, () => _lookUpRepoint(name));
  }

  void _lookUpRepoint(String name) {
    // Mid-check the form is spoken for; the next keystroke tries again.
    if (_state.activity != SignInActivity.idle) return;
    _set(_state.copyWith(repointing: name));
    _ask(homeserver.probe(name), (ServerCheck check) {
      _set(
        SignInState(server: name, check: check, softLogout: _state.softLogout),
      );
      final queued = _queued;
      _queued = null;
      if (queued != null && check is ServerFound && check.flows.password) {
        signInWithPassword(queued.$1, queued.$2);
      }
    });
  }

  void continueWithSso(IdentityProvider provider) {
    if (_state.activity != SignInActivity.idle) return;
    _set(
      _state.copyWith(
        activity: ssoInBrowser
            ? SignInActivity.inBrowser
            : SignInActivity.finishingSso,
        provider: provider,
        clearFailure: true,
      ),
    );
    _askFor(
      (epoch) => homeserver.sso(
        _state.server,
        provider,
        inBrowser: ssoInBrowser,
        onCommitting: _committed(epoch),
      ),
      _finish,
    );
  }

  /// Desktop: the browser tab was closed or lost.
  void reopenBrowser() {
    if (_state.activity != SignInActivity.inBrowser) return;
    homeserver.reopenSso();
  }

  void cancelSso() {
    if (_state.activity == SignInActivity.signedIn) return;
    _epoch++;
    homeserver.cancelSso();
    _set(_state.copyWith(activity: SignInActivity.idle));
  }

  void signInWithPassword(String user, String password) {
    if (_state.activity != SignInActivity.idle || _state.retryIn != null) {
      return;
    }
    if (user.trim().isEmpty || password.isEmpty) return;
    // The id names a server not yet looked up: look now, sign in after.
    // Checking against the old one would sign in to the wrong place, and
    // letting the look-up cancel this would lose the attempt.
    final pending = _repoint?.isActive ?? false;
    if (pending || _state.repointing != null) {
      _queued = (user, password);
      if (pending) {
        _repoint?.cancel();
        _lookUpRepoint(_repointTarget!);
      }
      return;
    }
    _set(
      _state.copyWith(
        activity: SignInActivity.checkingPassword,
        wrongPassword: false,
        clearFailure: true,
      ),
    );
    _askFor(
      (epoch) => homeserver.password(
        _state.server,
        user,
        password,
        onCommitting: _committed(epoch),
      ),
      _finish,
    );
  }

  void _finish(SignInOutcome outcome) {
    switch (outcome) {
      case SignedIn():
        _set(_state.copyWith(activity: SignInActivity.signedIn));
        onSignedIn();
      case WrongPassword():
        _set(
          _state.copyWith(activity: SignInActivity.idle, wrongPassword: true),
        );
      case RateLimited(:final retryIn):
        _startLimit(retryIn);
      case SignInCancelled():
        _set(_state.copyWith(activity: SignInActivity.idle));
      case SignInFailed(:final message):
        _set(_state.copyWith(activity: SignInActivity.idle, failure: message));
    }
  }

  void _startLimit(Duration wait) {
    var left = wait;
    _set(
      _state.copyWith(
        activity: SignInActivity.idle,
        wrongPassword: false,
        retryIn: left,
      ),
    );
    _countdown?.cancel();
    _countdown = Timer.periodic(const Duration(seconds: 1), (t) {
      left -= const Duration(seconds: 1);
      if (left <= Duration.zero) {
        t.cancel();
        _set(_state.copyWith(clearRetry: true));
      } else {
        _set(_state.copyWith(retryIn: left));
      }
    });
  }

  @override
  void dispose() {
    _epoch++;
    _repoint?.cancel();
    _countdown?.cancel();
    homeserver.close();
    super.dispose();
  }
}
