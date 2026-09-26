/// Sign-in or the app, whichever [MockSession] says. Owns the sign-in
/// controller while sign-in is showing, so every visit starts fresh.
library;

import 'package:flutter/material.dart';

import '../mock/mock_session.dart';
import '../shell/app_shell.dart';
import 'login_page.dart';
import 'sign_in_controller.dart';

class SessionRoot extends StatefulWidget {
  const SessionRoot({super.key, required this.session});

  final MockSession session;

  @override
  State<SessionRoot> createState() => _SessionRootState();
}

class _SessionRootState extends State<SessionRoot> {
  SignInController? _signIn;

  /// Which signed-out state [_signIn] was made for. Soft logout and a plain
  /// sign-in are different screens, so moving between them starts over.
  AccountState? _signInFor;

  MockSession get _session => widget.session;

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSession);
    _follow();
  }

  void _onSession() {
    // Leaving the app takes its panels and sheets with it: they belong to a
    // shell that is about to go, and would otherwise sit over sign-in
    // talking to disposed controllers.
    if (_session.account != AccountState.signedIn && _signIn == null) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
    setState(_follow);
  }

  /// Keeps [_signIn] matching the session: one controller per signed-out
  /// state, none while signed in.
  void _follow() {
    final account = _session.account;
    final wanted = account != AccountState.signedIn;
    final old = _signIn;
    if (old != null && (!wanted || _signInFor != account)) {
      _signIn = null;
      // Not disposed on the spot: a sign-in completes from inside one of the
      // controller's own timers, which is still running.
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
    if (wanted && _signIn == null) {
      _signInFor = account;
      _signIn = SignInController(
        server: MockSession.server,
        softLogout: _session.softLogout,
        onSignedIn: _session.signedIn,
        consumeFailure: _session.consumeFailure,
      );
    }
  }

  @override
  void dispose() {
    _session.removeListener(_onSession);
    _signIn?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final signIn = _signIn;
    if (signIn == null) return AppShell(session: _session);
    return LoginPage(
      key: ObjectKey(signIn),
      controller: signIn,
      onSignOutInstead: _session.signOut,
    );
  }
}
