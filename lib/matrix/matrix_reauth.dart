/// The server's "who are you?" for one request, and the answers this app can
/// give it: the account password, or the SSO fallback page in the real browser.
library;

import 'dart:async';

import 'package:matrix/matrix.dart';

import '../ui/verify/verifier.dart';

/// The kind a UIA request can be answered with here, or null.
AuthKind? authKindFor(UiaRequest<Object?> uia) =>
    uia.nextStages.contains(AuthenticationTypes.password)
    ? AuthKind.password
    : uia.nextStages.contains(AuthenticationTypes.sso)
    ? AuthKind.sso
    : null;

/// A server's "who are you?" for one request, answered by password or by
/// the SSO fallback page in the real browser. Once an answer is on its
/// way nothing here takes it back.
class MatrixChallenge implements AuthChallenge {
  MatrixChallenge(
    this.client,
    this._uia,
    this.kind, {
    required this.retry,
    required this.onCancel,
    required Future<bool> Function(Uri url) openBrowser,
    // The method below takes the name, so the field can't be a named formal.
    // ignore: prefer_initializing_formals
  }) : _openBrowser = openBrowser;

  final Client client;
  final UiaRequest<Object?> _uia;
  final void Function() onCancel;
  final Future<bool> Function(Uri url) _openBrowser;

  @override
  final AuthKind kind;

  @override
  final bool retry;

  /// Once an answer is on its way to the server, nothing here can take it
  /// back: a stale tap (or a cancel that arrives after the right password
  /// already went up) must do nothing rather than fail an upload that may
  /// yet land — that would report "nothing was made" while the server
  /// replaced the identity anyway.
  bool get _live => _uia.state == UiaRequestState.waitForUser;

  @override
  void password(String password) {
    if (!_live) return;
    unawaited(
      _uia.completeStage(
        AuthenticationPassword(
          session: _uia.session,
          password: password,
          identifier: AuthenticationUserIdentifier(user: client.userID!),
        ),
      ),
    );
  }

  /// The server's own page for SSO, which signs you in and then tells you to
  /// go back to the app: it hands nothing back.
  @override
  void openBrowser() {
    if (!_live) return;
    unawaited(
      _openBrowser(
        client.homeserver!.resolveUri(
          Uri(
            path:
                '/_matrix/client/v3/auth/${AuthenticationTypes.sso}/fallback/web',
            queryParameters: {'session': _uia.session},
          ),
        ),
      ),
    );
  }

  @override
  void browserFinished() {
    if (!_live) return;
    unawaited(_uia.completeStage(AuthenticationData(session: _uia.session)));
  }

  @override
  void cancel() {
    if (!_live) return;
    onCancel();
    _uia.cancel();
  }
}
