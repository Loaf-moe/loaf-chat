/// The sign-in screen's fake homeserver — mockup only. Plays discovery, SSO
/// and password sign-in out on timers against [mockServers], producing the
/// states a real client would get from `.well-known`, `/versions` and
/// `/login`. See "Sign-in and verification" in the design spec.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../mock/accounts.dart';
import '../platform.dart';
import 'sign_in_state.dart';

class SignInController extends ChangeNotifier {
  /// Starts probing [server] at once, the way the screen opens.
  SignInController({
    String server = 'loaf.moe',
    SoftLogout? softLogout,
    required this.onSignedIn,
    this.consumeFailure = _never,
    this.servers = mockServers,
    bool? desktop,
  }) : desktop = desktop ?? isDesktop,
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
    this.consumeFailure = _never,
    this.servers = mockServers,
    bool? desktop,
  }) : onSignedIn = onSignedIn ?? _nothing,
       desktop = desktop ?? isDesktop,
       _state = state;

  static bool _never() => false;
  static void _nothing() {}

  static const probeDelay = Duration(milliseconds: 700);
  static const repointDebounce = Duration(milliseconds: 400);
  static const browserDelay = Duration(seconds: 3);
  static const ssoSheetDelay = Duration(milliseconds: 900);
  static const passwordDelay = Duration(milliseconds: 700);
  static const rateLimit = Duration(seconds: 30);

  /// Wrong passwords in a row before the server stops checking for a while.
  static const triesBeforeLimit = 3;

  final VoidCallback onSignedIn;

  /// The debug "fail the next connection" lever, spent by the next password.
  final bool Function() consumeFailure;
  final Map<String, ServerCheck> servers;
  final bool desktop;

  SignInState _state;
  SignInState get state => _state;

  /// The one thing in flight. Starting anything new cancels it, so a stale
  /// timer can never sign in or jump a step.
  Timer? _work;
  Timer? _repoint;
  Timer? _countdown;
  var _wrongInARow = 0;

  /// A password submitted while a full id's server is being looked up. It
  /// goes to that server once found: the id says where the account lives.
  (String, String)? _queued;
  String? _repointTarget;

  void _set(SignInState s) {
    _state = s;
    notifyListeners();
  }

  void _after(Duration delay, VoidCallback run) {
    _work?.cancel();
    _work = Timer(delay, run);
  }

  ServerCheck _lookUp(String name) =>
      servers[name] ?? const ServerFailed(ServerProblem.unreachable);

  /// The server picker's connect. Input that names no server is ignored.
  void connect(String input) {
    final name = serverNameFrom(input);
    if (name == null) return;
    _repoint?.cancel();
    // A rate limit and a tally of wrong tries belong to the server that
    // set them.
    _countdown?.cancel();
    _wrongInARow = 0;
    _queued = null;
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
    _after(
      probeDelay,
      () => _set(
        SignInState(
          server: server,
          check: _lookUp(server),
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
    _after(probeDelay, () {
      _set(
        SignInState(
          server: name,
          check: _lookUp(name),
          softLogout: _state.softLogout,
        ),
      );
      final queued = _queued;
      _queued = null;
      final check = _state.check;
      if (queued != null && check is ServerFound && check.flows.password) {
        signInWithPassword(queued.$1, queued.$2);
      }
    });
  }

  void continueWithSso(IdentityProvider provider) {
    if (_state.activity != SignInActivity.idle) return;
    _set(
      _state.copyWith(
        activity: desktop
            ? SignInActivity.inBrowser
            : SignInActivity.finishingSso,
        provider: provider,
      ),
    );
    _after(desktop ? browserDelay : ssoSheetDelay, _succeed);
  }

  /// Desktop: the browser tab was closed or lost. Opening it again restarts
  /// the wait rather than stacking a second one.
  void reopenBrowser() {
    if (_state.activity != SignInActivity.inBrowser) return;
    _after(browserDelay, _succeed);
  }

  void cancelSso() {
    _work?.cancel();
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
      ),
    );
    _after(passwordDelay, () {
      final wrong = password == mockWrongPassword || consumeFailure();
      if (!wrong) {
        _wrongInARow = 0;
        _succeed();
        return;
      }
      _wrongInARow++;
      if (_wrongInARow >= triesBeforeLimit) {
        _wrongInARow = 0;
        _startLimit();
        return;
      }
      _set(_state.copyWith(activity: SignInActivity.idle, wrongPassword: true));
    });
  }

  void _succeed() {
    _set(_state.copyWith(activity: SignInActivity.signedIn));
    onSignedIn();
  }

  void _startLimit() {
    var left = rateLimit;
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
    _work?.cancel();
    _repoint?.cancel();
    _countdown?.cancel();
    super.dispose();
  }
}
