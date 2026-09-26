/// The three questions sign-in asks a homeserver, and the answers it can
/// get. [SignInController] owns the screen's state machine; a [Homeserver]
/// only answers. The mock answers from fixtures on timers, the SDK from the
/// network, and the controller cannot tell them apart.
library;

import 'package:flutter/foundation.dart';

import 'sign_in_state.dart';

/// How a sign-in attempt ended.
@immutable
sealed class SignInOutcome {
  const SignInOutcome();
}

class SignedIn extends SignInOutcome {
  const SignedIn();
}

/// `M_FORBIDDEN` for a password.
class WrongPassword extends SignInOutcome {
  const WrongPassword();
}

/// `M_LIMIT_EXCEEDED`: the server will not check again for [retryIn].
class RateLimited extends SignInOutcome {
  const RateLimited(this.retryIn);

  final Duration retryIn;
}

/// The person closed the sheet or cancelled the browser wait. Not an error,
/// so nothing is said.
class SignInCancelled extends SignInOutcome {
  const SignInCancelled();
}

/// Anything else, already worded for the screen.
class SignInFailed extends SignInOutcome {
  const SignInFailed(this.message);

  final String message;
}

/// Implementations never throw: every failure is an answer.
abstract interface class Homeserver {
  /// `.well-known`, `/versions` and `/login` for [server], a bare name as
  /// typed.
  Future<ServerCheck> probe(String server);

  /// [server] has been probed and found to take passwords.
  ///
  /// [onCommitting], if given, is called once, just before the attempt
  /// passes the point where it can no longer be stopped; after it,
  /// [cancelSso] and [close] no longer change the outcome.
  Future<SignInOutcome> password(
    String server,
    String user,
    String password, {
    void Function()? onCommitting,
  });

  /// Resolves when the provider hands back, or with [SignInCancelled] once
  /// [cancelSso] is called. [desktop] picks the real browser over the
  /// system sheet.
  ///
  /// [onCommitting], if given, is called once, just before the attempt
  /// passes the point where it can no longer be stopped; after it,
  /// [cancelSso] and [close] no longer change the outcome.
  Future<SignInOutcome> sso(
    String server,
    IdentityProvider provider, {
    required bool desktop,
    void Function()? onCommitting,
  });

  /// Desktop: opens the pending SSO page in the browser again.
  void reopenSso();

  /// Abandons a pending [sso]. Does nothing when none is pending.
  void cancelSso();

  /// The sign-in screen is going: stop everything in flight.
  void close();
}
