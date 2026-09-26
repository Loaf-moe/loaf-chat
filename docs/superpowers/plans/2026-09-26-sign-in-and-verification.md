# Sign-in and Verification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the static login mockup into a clickable sign-in → verify journey on fake data: discovery, several SSO providers, desktop browser wait, password errors, soft logout, device verification (emoji, recovery key, reset), set up recovery, and the incoming "is this you?" prompt.

**Architecture:** Views stay pure over plain state values (`SignInState`, `VerifyState`). Two fake drivers (`SignInController`, `VerificationController`, both `ChangeNotifier`s like `CallController`) play the flows out on timers. A `MockSession` holds the account (signed out / soft logged out / signed in) and device trust (no identity / unverified / verified). `SessionRoot` shows `LoginPage` or `AppShell` from it. `MockDebug` levers reach the rare states.

**Tech Stack:** Flutter (via `mise exec -- flutter`), `lucide_icons_flutter`, `flutter_test`. No SDK, no network.

**Spec:** `docs/superpowers/specs/2026-09-20-loaf-native-design.md` — section "Sign-in and verification" (line ~236) and the MSC3967 entry under "Known risks".

## Global Constraints

- Mockup only: hardcoded fixtures, timers, no `package:matrix`, no network, no real clipboard files or browsers.
- Copy is lowercase, in a warm voice. The accent red is spent only on attention notices, filled primary buttons, spinners that already use it, and reset's destructive button. Focus outlines use `borderStrong`, never the accent.
- Split by platform with `isDesktop` from `lib/ui/platform.dart`, never by input device. Desktop keeps text selection (the recovery key is `SelectableText` there). Every face ships in both forms at once.
- Never hardcode text metrics. Chris runs iOS at the smallest text size, and the tests check large text scale where a layout could break.
- The server line always shows the name typed, never a delegated base URL.
- Only one control is "the" primary per face. Several identity providers are equal outlined buttons, because the server's order is not a preference.
- Tests use `TargetPlatformVariant` for platform splits. A widget test that owns a timer-driven controller disposes it as its **last line**, since the pending-timer check runs before tear-downs. Parsing is also tested by typing character by character.
- Shell commands are Nushell-compatible. Run `mise exec -- flutter analyze` and `mise exec -- flutter test`.
- **Commits happen only when Chris asks.** Each task ends in a checkpoint with a suggested message: a conventional commit with a body explaining the why, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Mock secrets, for trying the flows by hand: any password except `wrong` signs in. The recovery key is `EsTc 5rr9 Tj3W 8ZkN oAYy 1mfA hKbu m2Cq 6ZMy F8Ws dNvf cDbu`, and the passphrase is `bread before breakfast`.

## Review Focus

1. **Starting something new while a timer is in flight.** Connecting to another server during the browser wait, or going back while waiting for another device, must cancel the pending finish. A stale timer must never sign you in or jump steps. Pinned in Task 2 and Task 6.
2. **Putting the verify panel away mid-flow** (Escape, or a drag down) while a timer is pending. There should be no exception, nothing trusted, and the notice still there. Pinned in Task 9.
3. **Signing out, or the session expiring, while a panel is open.** The panel must go with the shell, and no disposed controller may be touched. Pinned in Task 9.
4. **Pasting a recovery key with odd whitespace** (newlines, double spaces, a trailing space). It must still unlock. Pinned in Task 6.
5. **Long names everywhere**: a long server in the row, in "looking for…", in the delegation message and in the browser wait. They must ellipsise or wrap, never overflow. Pinned in Task 4.

## File Map

| File | Responsibility |
|---|---|
| `lib/ui/auth/sign_in_state.dart` (new) | Sign-in value types, server-name parsing, failure copy |
| `lib/ui/mock/accounts.dart` (new) | Fixtures: servers, sessions, recovery secrets, SAS emoji |
| `lib/ui/auth/sign_in_controller.dart` (new) | Fake homeserver for sign-in, on timers |
| `lib/ui/widgets/loaf_field.dart` (new) | The app's single-line field (moved out of login) |
| `lib/ui/widgets/error_note.dart` (new) | The red-bordered note (moved out of login) |
| `lib/ui/widgets/loaf_button.dart` (modify) | `leading` widget slot for provider marks |
| `lib/ui/auth/login_page.dart` (rewrite) | Draws `SignInState`, including soft logout |
| `lib/ui/auth/browser_wait.dart` (new) | Desktop "finish in your browser" face |
| `lib/ui/mock/mock_session.dart` (new) | Account plus device trust plus incoming request |
| `lib/ui/auth/session_root.dart` (new) | Login or shell, from the session |
| `lib/main.dart` (modify) | Opens on `SessionRoot` |
| `lib/ui/verify/verify_state.dart` (new) | Verify value types |
| `lib/ui/verify/verification_controller.dart` (new) | Fake verification, on timers |
| `lib/ui/verify/emoji_compare.dart` (new) | The 7 emoji, shared by both ends |
| `lib/ui/verify/recovery_key.dart` (new) | Key grouping, display, entry field |
| `lib/ui/verify/verify_steps.dart` (new) | Step bodies: choose, wait, compare, cancelled, recovery, restoring, done |
| `lib/ui/verify/reset_identity.dart` (new) | Reset confirm plus re-auth steps |
| `lib/ui/verify/recovery_setup.dart` (new) | Set-up intro plus show-key steps |
| `lib/ui/verify/incoming_verification.dart` (new) | "Is this you?" plus not-me steps |
| `lib/ui/verify/verify_panel.dart` (new) | Panel host: header, back, dispatch, self-close |
| `lib/ui/shell/app_shell.dart` (modify) | Session-driven notices, opening panels, levers |
| `lib/ui/shell/app_notice.dart` (modify) | `AppNotice.setUpRecovery` |
| `lib/ui/shell/mock_debug.dart` (modify) | Four new levers |

---

### Task 1: Sign-in values, parsing and server fixtures

**Files:**
- Create: `lib/ui/auth/sign_in_state.dart`
- Create: `lib/ui/mock/accounts.dart`
- Test: `test/sign_in_state_test.dart`

**Interfaces:**
- Produces:
  - `IdentityProvider(String id, String name)` with `.initial`.
  - `ServerFlows({List<IdentityProvider> providers, bool password})` with `.sso`.
  - `enum ServerProblem { unreachable, notMatrix, delegationBroken }`.
  - `sealed ServerCheck`, implemented by `ServerProbing()`, `ServerFound(ServerFlows flows)` and `ServerFailed(ServerProblem problem, {String? delegatedTo})` with `.messageFor(String server)`.
  - `enum SignInActivity { idle, inBrowser, finishingSso, checkingPassword }`.
  - `SoftLogout({Member member, String userId})`.
  - `SignInState({server, check, activity, provider, wrongPassword, retryIn, softLogout, repointing})` with `copyWith`.
  - `String? serverNameFrom(String)` and `String? serverFromUserId(String)`.
  - `const loafMoeProvider`, `const mockServers`, `const mockWrongPassword`.

- [ ] **Step 1: Write the failing test** — `test/sign_in_state_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/auth/sign_in_state.dart';
import 'package:loaf_native/ui/mock/accounts.dart';

void main() {
  group('serverNameFrom', () {
    test('takes a bare name, trimmed and lowercased', () {
      expect(serverNameFrom('loaf.moe'), 'loaf.moe');
      expect(serverNameFrom('  Loaf.MOE '), 'loaf.moe');
    });

    test('takes the host of a url, keeping a port', () {
      expect(serverNameFrom('https://matrix.loaf.moe/_matrix/'), 'matrix.loaf.moe');
      expect(serverNameFrom('HTTP://localhost:8008'), 'localhost:8008');
      expect(serverNameFrom('loaf.moe:8448'), 'loaf.moe:8448');
    });

    test('takes the domain of a full user id', () {
      expect(serverNameFrom('@chris:loaf.moe'), 'loaf.moe');
    });

    test('is null until there is a name in it', () {
      for (final input in [
        '', '  ', 'loaf', 'loaf.', '.moe', '@chris', '@chris:', '@:loaf.moe',
        'https://', 'https:', 'loaf moe.x',
      ]) {
        expect(serverNameFrom(input), isNull, reason: '"$input"');
      }
    });

    test('survives every prefix of what people type', () {
      // Half-typed input is the normal case: the matrix.to crash only showed
      // up typing character by character.
      const typed = {
        '@chris:loaf.moe': 'loaf.moe',
        'https://matrix.loaf.moe/path': 'matrix.loaf.moe',
        'loaf.moe:8448': 'loaf.moe:8448',
      };
      for (final MapEntry(key: full, value: want) in typed.entries) {
        for (var i = 0; i < full.length; i++) {
          serverNameFrom(full.substring(0, i));
        }
        expect(serverNameFrom(full), want);
      }
    });
  });

  group('serverFromUserId', () {
    test('only answers for a full id', () {
      expect(serverFromUserId('chris'), isNull);
      expect(serverFromUserId('@chris'), isNull);
      expect(serverFromUserId('@chris:'), isNull);
      expect(serverFromUserId('@chris:loaf.moe'), 'loaf.moe');
      expect(serverFromUserId('@chris:loaf.moe:8448'), 'loaf.moe:8448');
    });
  });

  test('each discovery failure says something different', () {
    expect(
      const ServerFailed(ServerProblem.unreachable).messageFor('x.test'),
      'nothing answered at x.test',
    );
    expect(
      const ServerFailed(ServerProblem.notMatrix).messageFor('x.test'),
      "x.test isn't a matrix server",
    );
    expect(
      const ServerFailed(
        ServerProblem.delegationBroken,
        delegatedTo: 'matrix.x.test',
      ).messageFor('x.test'),
      "x.test points to matrix.x.test, which didn't answer",
    );
  });

  test('the fixture servers cover every face', () {
    final loaf = mockServers['loaf.moe']! as ServerFound;
    expect(loaf.flows.providers, [loafMoeProvider]);
    expect(loaf.flows.password, isTrue);
    expect((mockServers['many-doors.test']! as ServerFound).flows.providers.length, greaterThan(1));
    expect((mockServers['sso-only.test']! as ServerFound).flows.password, isFalse);
    expect((mockServers['passwords.test']! as ServerFound).flows.sso, isFalse);
    expect(mockServers['example.com'], isA<ServerFailed>());
    expect(mockServers['broken.test'], isA<ServerFailed>());
  });

  test('a provider without an icon falls back to its initial', () {
    expect(const IdentityProvider('x', 'authentik').initial, 'A');
  });
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `mise exec -- flutter test test/sign_in_state_test.dart`
Expected: FAIL to compile, because `sign_in_state.dart` and `accounts.dart` don't exist yet.

- [ ] **Step 3: Implement** `lib/ui/auth/sign_in_state.dart`:

```dart
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

  SignInState copyWith({
    SignInActivity? activity,
    IdentityProvider? provider,
    bool? wrongPassword,
    Duration? retryIn,
    bool clearRetry = false,
    String? repointing,
  }) => SignInState(
    server: server,
    check: check,
    activity: activity ?? this.activity,
    provider: provider ?? this.provider,
    wrongPassword: wrongPassword ?? this.wrongPassword,
    retryIn: clearRetry ? null : (retryIn ?? this.retryIn),
    softLogout: softLogout,
    repointing: repointing ?? this.repointing,
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
```

`lib/ui/mock/accounts.dart`:

```dart
/// Fixtures for sign-in and verification: the homeservers the mock knows,
/// and this account's secrets.
///
/// To try the flows by hand, type one of [mockServers]' names into the
/// server picker, and sign in with any password except [mockWrongPassword].
library;

import '../auth/sign_in_state.dart';

/// loaf.moe delegates SSO to Kanidm and names it after itself.
const loafMoeProvider = IdentityProvider('kanidm', 'loaf.moe');

/// One server per face the sign-in screen has to get right. Any other name
/// answers nothing.
const mockServers = <String, ServerCheck>{
  'loaf.moe': ServerFound(
    ServerFlows(providers: [loafMoeProvider], password: true),
  ),
  'many-doors.test': ServerFound(
    ServerFlows(
      providers: [
        IdentityProvider('oidc-github', 'GitHub'),
        IdentityProvider('oidc-google', 'Google'),
        IdentityProvider('oidc-gitlab', 'GitLab'),
        IdentityProvider('oidc-apple', 'Apple'),
      ],
      password: true,
    ),
  ),
  'sso-only.test': ServerFound(
    ServerFlows(providers: [IdentityProvider('oidc', 'Authentik')]),
  ),
  'passwords.test': ServerFound(ServerFlows(password: true)),
  'example.com': ServerFailed(ServerProblem.notMatrix),
  'broken.test': ServerFailed(
    ServerProblem.delegationBroken,
    delegatedTo: 'matrix.broken.test',
  ),
};

/// The one password the mock homeserver turns away (`M_FORBIDDEN`).
const mockWrongPassword = 'wrong';
```

- [ ] **Step 4: Run it and watch it pass**

Run: `mise exec -- flutter test test/sign_in_state_test.dart`
Expected: PASS.

- [ ] **Step 5: Checkpoint.** Suggested commit: `feat(ui): sign-in states and server-name parsing as plain values`.

---

### Task 2: SignInController, the fake homeserver

**Files:**
- Create: `lib/ui/auth/sign_in_controller.dart`
- Test: `test/sign_in_controller_test.dart`

**Interfaces:**
- Consumes: everything from Task 1.
- Produces:
  - `SignInController({String server = 'loaf.moe', SoftLogout? softLogout, required VoidCallback onSignedIn, bool Function() consumeFailure, Map<String, ServerCheck> servers = mockServers, bool? desktop})`. It probes `server` at once.
  - `@visibleForTesting SignInController.at(SignInState state, {VoidCallback? onSignedIn, bool Function() consumeFailure, Map<String, ServerCheck> servers, bool? desktop})`. It starts with nothing in flight.
  - Members: `state`, `connect(String input)`, `retry()`, `usernameChanged(String)`, `continueWithSso(IdentityProvider)`, `reopenBrowser()`, `cancelSso()` and `signInWithPassword(String user, String password)`.
  - Constants: `probeDelay` 700ms, `repointDebounce` 400ms, `browserDelay` 3s, `ssoSheetDelay` 900ms, `passwordDelay` 700ms, `rateLimit` 30s and `triesBeforeLimit` 3.

- [ ] **Step 1: Write the failing test** — `test/sign_in_controller_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/auth/sign_in_controller.dart';
import 'package:loaf_native/ui/auth/sign_in_state.dart';
import 'package:loaf_native/ui/mock/accounts.dart';

/// Widget tests only for the fake clock. Each disposes its controller as its
/// last line: the pending-timer check runs before tear-downs.
void main() {
  late int signedIn;
  setUp(() => signedIn = 0);

  SignInController make({String server = 'loaf.moe', bool desktop = false, bool Function()? fail}) =>
      SignInController(
        server: server,
        onSignedIn: () => signedIn++,
        consumeFailure: fail ?? () => false,
        desktop: desktop,
      );

  SignInController at(String server, {bool desktop = false, bool Function()? fail}) =>
      SignInController.at(
        SignInState(server: server, check: mockServers[server]!),
        onSignedIn: () => signedIn++,
        consumeFailure: fail ?? () => false,
        desktop: desktop,
      );

  group('discovery', () {
    testWidgets('opens probing, then shows what the server offers', (tester) async {
      final c = make();
      expect(c.state.check, isA<ServerProbing>());
      await tester.pump(SignInController.probeDelay);
      final found = c.state.check as ServerFound;
      expect(found.flows.providers, [loafMoeProvider]);
      c.dispose();
    });

    testWidgets('each failure is its own problem', (tester) async {
      final c = make(server: 'nowhere.test');
      await tester.pump(SignInController.probeDelay);
      expect((c.state.check as ServerFailed).problem, ServerProblem.unreachable);

      c.connect('example.com');
      await tester.pump(SignInController.probeDelay);
      expect((c.state.check as ServerFailed).problem, ServerProblem.notMatrix);

      c.connect('broken.test');
      await tester.pump(SignInController.probeDelay);
      final broken = c.state.check as ServerFailed;
      expect(broken.problem, ServerProblem.delegationBroken);
      expect(broken.delegatedTo, 'matrix.broken.test');
      c.dispose();
    });

    testWidgets('connect keeps the name typed, from a url or an id', (tester) async {
      final c = at('loaf.moe');
      c.connect('https://Many-Doors.test/anything');
      expect(c.state.server, 'many-doors.test');
      await tester.pump(SignInController.probeDelay);
      c.connect('@chris:passwords.test');
      expect(c.state.server, 'passwords.test');
      await tester.pump(SignInController.probeDelay);
      c.dispose();
    });

    testWidgets('connect ignores input that names no server', (tester) async {
      final c = at('loaf.moe');
      c.connect('@chris');
      expect(c.state.server, 'loaf.moe');
      expect(c.state.check, isA<ServerFound>());
      c.dispose();
    });
  });

  group('a full id in the username', () {
    testWidgets('re-points the server once typing pauses', (tester) async {
      final c = at('passwords.test');
      const full = '@chris:loaf.moe';
      for (var i = 1; i <= full.length; i++) {
        c.usernameChanged(full.substring(0, i));
        await tester.pump(const Duration(milliseconds: 100));
      }
      // Each keystroke restarted the wait, so nothing half-typed was probed.
      expect(c.state.repointing, isNull);
      expect(c.state.server, 'passwords.test');

      await tester.pump(SignInController.repointDebounce);
      expect(c.state.repointing, 'loaf.moe');
      expect(c.state.check, isA<ServerFound>(), reason: 'the form stays up');

      await tester.pump(SignInController.probeDelay);
      expect(c.state.server, 'loaf.moe');
      expect(c.state.repointing, isNull);
      c.dispose();
    });

    testWidgets('a plain username leaves the server alone', (tester) async {
      final c = at('passwords.test');
      c.usernameChanged('chris');
      await tester.pump(SignInController.repointDebounce);
      expect(c.state.repointing, isNull);
      c.dispose();
    });
  });

  group('sso', () {
    testWidgets('a computer waits on the browser', (tester) async {
      final c = at('loaf.moe', desktop: true);
      c.continueWithSso(loafMoeProvider);
      expect(c.state.activity, SignInActivity.inBrowser);
      expect(c.state.provider, loafMoeProvider);
      await tester.pump(SignInController.browserDelay);
      expect(signedIn, 1);
      c.dispose();
    });

    testWidgets('a phone finishes in the system sheet', (tester) async {
      final c = at('loaf.moe');
      c.continueWithSso(loafMoeProvider);
      expect(c.state.activity, SignInActivity.finishingSso);
      await tester.pump(SignInController.ssoSheetDelay);
      expect(signedIn, 1);
      c.dispose();
    });

    testWidgets('opening the browser again restarts the wait', (tester) async {
      final c = at('loaf.moe', desktop: true);
      c.continueWithSso(loafMoeProvider);
      await tester.pump(const Duration(seconds: 2));
      c.reopenBrowser();
      await tester.pump(const Duration(seconds: 2));
      expect(signedIn, 0);
      await tester.pump(const Duration(seconds: 1));
      expect(signedIn, 1);
      c.dispose();
    });

    testWidgets('cancel stops the pending sign-in', (tester) async {
      final c = at('loaf.moe', desktop: true);
      c.continueWithSso(loafMoeProvider);
      c.cancelSso();
      expect(c.state.activity, SignInActivity.idle);
      await tester.pump(SignInController.browserDelay);
      expect(signedIn, 0);
      c.dispose();
    });

    testWidgets('connecting elsewhere mid-wait drops the old sign-in', (tester) async {
      final c = at('loaf.moe', desktop: true);
      c.continueWithSso(loafMoeProvider);
      c.connect('passwords.test');
      await tester.pump(SignInController.browserDelay);
      expect(signedIn, 0);
      expect(c.state.server, 'passwords.test');
      c.dispose();
    });
  });

  group('password', () {
    testWidgets('a right password signs in', (tester) async {
      final c = at('passwords.test');
      c.signInWithPassword('chris', 'hunter2');
      expect(c.state.activity, SignInActivity.checkingPassword);
      await tester.pump(SignInController.passwordDelay);
      expect(signedIn, 1);
      c.dispose();
    });

    testWidgets('an empty field does nothing', (tester) async {
      final c = at('passwords.test');
      c.signInWithPassword(' ', 'x');
      c.signInWithPassword('chris', '');
      expect(c.state.activity, SignInActivity.idle);
      c.dispose();
    });

    testWidgets('the wrong password is turned away', (tester) async {
      final c = at('passwords.test');
      c.signInWithPassword('chris', mockWrongPassword);
      await tester.pump(SignInController.passwordDelay);
      expect(c.state.wrongPassword, isTrue);
      expect(c.state.activity, SignInActivity.idle);
      expect(signedIn, 0);
      c.dispose();
    });

    testWidgets('the failure lever turns a right password away once', (tester) async {
      var armed = true;
      final c = at('passwords.test', fail: () {
        final f = armed;
        armed = false;
        return f;
      });
      c.signInWithPassword('chris', 'hunter2');
      await tester.pump(SignInController.passwordDelay);
      expect(c.state.wrongPassword, isTrue);
      c.signInWithPassword('chris', 'hunter2');
      await tester.pump(SignInController.passwordDelay);
      expect(signedIn, 1);
      c.dispose();
    });

    testWidgets('too many tries counts down before it checks again', (tester) async {
      final c = at('passwords.test');
      for (var i = 0; i < SignInController.triesBeforeLimit; i++) {
        c.signInWithPassword('chris', mockWrongPassword);
        await tester.pump(SignInController.passwordDelay);
      }
      expect(c.state.retryIn, SignInController.rateLimit);
      expect(c.state.wrongPassword, isFalse);

      c.signInWithPassword('chris', 'hunter2');
      expect(c.state.activity, SignInActivity.idle, reason: 'refused while limited');

      await tester.pump(const Duration(seconds: 1));
      expect(c.state.retryIn, const Duration(seconds: 29));
      await tester.pump(const Duration(seconds: 29));
      expect(c.state.retryIn, isNull);
      c.dispose();
    });
  });
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `mise exec -- flutter test test/sign_in_controller_test.dart`
Expected: FAIL to compile, because `sign_in_controller.dart` doesn't exist yet.

- [ ] **Step 3: Implement** `lib/ui/auth/sign_in_controller.dart`:

```dart
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
    _repoint = Timer(repointDebounce, () {
      _set(_state.copyWith(repointing: name));
      _after(
        probeDelay,
        () => _set(
          SignInState(
            server: name,
            check: _lookUp(name),
            softLogout: _state.softLogout,
          ),
        ),
      );
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
    _after(desktop ? browserDelay : ssoSheetDelay, onSignedIn);
  }

  /// Desktop: the browser tab was closed or lost. Opening it again restarts
  /// the wait rather than stacking a second one.
  void reopenBrowser() {
    if (_state.activity != SignInActivity.inBrowser) return;
    _after(browserDelay, onSignedIn);
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
        onSignedIn();
        return;
      }
      _wrongInARow++;
      if (_wrongInARow >= triesBeforeLimit) {
        _wrongInARow = 0;
        _startLimit();
        return;
      }
      _set(
        _state.copyWith(activity: SignInActivity.idle, wrongPassword: true),
      );
    });
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
```

- [ ] **Step 4: Run it and watch it pass**

Run: `mise exec -- flutter test test/sign_in_controller_test.dart`
Expected: PASS.

- [ ] **Step 5: Checkpoint.** Suggested commit: `feat(ui): a fake homeserver that plays sign-in out on timers`.

---

### Task 3: The sign-in screen draws the controller

Moves `_Field` and `_ErrorNote` into shared widgets, gives `LoafButton` a `leading` slot, and rewrites `LoginPage` onto `SignInController`: discovery, several providers, the password form with autofill and Enter, re-pointing from a full id, and password errors.

**Files:**
- Create: `lib/ui/widgets/loaf_field.dart`
- Create: `lib/ui/widgets/error_note.dart`
- Modify: `lib/ui/widgets/loaf_button.dart` (add `leading`)
- Rewrite: `lib/ui/auth/login_page.dart`
- Rewrite: `test/login_page_test.dart`

**Interfaces:**
- Consumes: Tasks 1 and 2.
- Produces:
  - `LoafField({required TextEditingController controller, required String hint, required IconData icon, bool obscure, bool autofocus, VoidCallback? onSubmit, ValueChanged<String>? onChanged, Iterable<String>? autofillHints, TextInputAction? textInputAction, Widget? trailing})`.
  - `ErrorNote({required String message})`.
  - `LoafButton(..., Widget? leading)`.
  - `LoginPage({required SignInController controller, VoidCallback? onSignOutInstead})`.

- [ ] **Step 1: Write the failing test.** Replace `test/login_page_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/auth/login_page.dart';
import 'package:loaf_native/ui/auth/sign_in_controller.dart';
import 'package:loaf_native/ui/auth/sign_in_state.dart';
import 'package:loaf_native/ui/mock/accounts.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/widgets/loaf_button.dart';

const _phone = Size(390, 844);
const _mac = Size(1280, 800);

SignInState _on(String server, {SignInActivity activity = SignInActivity.idle, bool wrongPassword = false, Duration? retryIn}) =>
    SignInState(
      server: server,
      check: mockServers[server] ?? const ServerFailed(ServerProblem.unreachable),
      activity: activity,
      provider: loafMoeProvider,
      wrongPassword: wrongPassword,
      retryIn: retryIn,
    );

/// Pumps [controller] into a LoginPage. The probing faces spin forever, so
/// this pumps a fixed time instead of settling.
Future<void> _pump(WidgetTester tester, SignInController controller, {Size size = _phone, VoidCallback? onSignOutInstead}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: loafLightTheme(),
      darkTheme: loafDarkTheme(),
      themeMode: ThemeMode.dark,
      home: LoginPage(controller: controller, onSignOutInstead: onSignOutInstead),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  final faces = <String, SignInState>{
    'probing': const SignInState(server: 'loaf.moe', check: ServerProbing()),
    'sso and password': _on('loaf.moe'),
    'many providers': _on('many-doors.test'),
    'sso only': _on('sso-only.test'),
    'password only': _on('passwords.test'),
    'unreachable': _on('nowhere.test'),
    'not matrix': _on('example.com'),
    'broken delegation': _on('broken.test'),
    'finishing sso': _on('loaf.moe', activity: SignInActivity.finishingSso),
    'checking password': _on('passwords.test', activity: SignInActivity.checkingPassword),
    'wrong password': _on('passwords.test', wrongPassword: true),
    'rate limited': _on('passwords.test', retryIn: const Duration(seconds: 30)),
    'no usable flow': const SignInState(server: 'odd.test', check: ServerFound(ServerFlows())),
  };
  for (final MapEntry(key: name, value: state) in faces.entries) {
    for (final size in [_phone, _mac]) {
      testWidgets('$name lays out at ${size.width.toInt()} wide', (tester) async {
        final c = SignInController.at(state);
        await _pump(tester, c, size: size);
        expect(tester.takeException(), isNull);
        c.dispose();
      });
    }
  }

  testWidgets('picking a homeserver replaces the sign-in controls', (tester) async {
    final c = SignInController.at(_on('loaf.moe'));
    await _pump(tester, c);
    expect(find.text('continue with loaf.moe'), findsOneWidget);

    await tester.tap(find.text('loaf.moe'));
    await tester.pump(const Duration(milliseconds: 100));
    // The picker takes over rather than stacking under the button.
    expect(find.text('continue with loaf.moe'), findsNothing);
    expect(find.text('where does your account live?'), findsOneWidget);

    await tester.tap(find.text('cancel'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('continue with loaf.moe'), findsOneWidget);
    c.dispose();
  });

  testWidgets('connect probes the server typed', (tester) async {
    final c = SignInController.at(_on('loaf.moe'));
    await _pump(tester, c);
    await tester.tap(find.text('loaf.moe'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byType(TextField), 'many-doors.test');
    await tester.tap(find.text('connect'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('looking for many-doors.test'), findsOneWidget);

    await tester.pump(SignInController.probeDelay);
    expect(find.textContaining('continue with'), findsNWidgets(4));
    c.dispose();
  });

  testWidgets('connect does nothing until the field names a server', (tester) async {
    final c = SignInController.at(_on('loaf.moe'));
    await _pump(tester, c);
    await tester.tap(find.text('loaf.moe'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byType(TextField), '@chris');
    await tester.tap(find.text('connect'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('where does your account live?'), findsOneWidget);
    c.dispose();
  });

  testWidgets('several providers are equals: none gets the filled button', (tester) async {
    final c = SignInController.at(_on('many-doors.test'));
    await _pump(tester, c);
    final providers = tester
        .widgetList<LoafButton>(find.byType(LoafButton))
        .where((b) => b.label.startsWith('continue with'));
    expect(providers, hasLength(4));
    expect(providers.every((b) => b.emphasis == LoafButtonEmphasis.outlined), isTrue);
    // Their marks stand in for icons the mock cannot load.
    expect(find.text('G'), findsWidgets);
    c.dispose();
  });

  testWidgets('no password link where the server takes no password', (tester) async {
    final c = SignInController.at(_on('sso-only.test'));
    await _pump(tester, c);
    expect(find.text('use a username and password'), findsNothing);
    c.dispose();
  });

  testWidgets('each failure shows its own message and a retry', (tester) async {
    final c = SignInController.at(_on('broken.test'));
    await _pump(tester, c);
    expect(find.text("broken.test points to matrix.broken.test, which didn't answer"), findsOneWidget);
    expect(find.text('try again'), findsOneWidget);
    c.dispose();
  });

  testWidgets('typing a full id re-points the server and keeps the form', (tester) async {
    final c = SignInController.at(_on('passwords.test'));
    await _pump(tester, c);
    final username = find.widgetWithText(TextField, 'username');
    const full = '@chris:loaf.moe';
    for (var i = 1; i <= full.length; i++) {
      await tester.enterText(username, full.substring(0, i));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
    }
    await tester.pump(SignInController.repointDebounce);
    expect(find.text('looking for '), findsOneWidget);

    await tester.pump(SignInController.probeDelay);
    // loaf.moe offers SSO first, but you were already in the form.
    expect(find.text(full), findsOneWidget);
    expect(find.widgetWithText(TextField, 'password'), findsOneWidget);
    expect(find.text('loaf.moe'), findsOneWidget);
    c.dispose();
  });

  testWidgets('Enter in the password field signs in', (tester) async {
    var signedIn = false;
    final c = SignInController.at(_on('passwords.test'), onSignedIn: () => signedIn = true);
    await _pump(tester, c);
    await tester.enterText(find.widgetWithText(TextField, 'username'), 'chris');
    await tester.enterText(find.widgetWithText(TextField, 'password'), 'hunter2');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(SignInController.passwordDelay);
    expect(signedIn, isTrue);
    c.dispose();
  });

  testWidgets('the fields offer themselves to password managers', (tester) async {
    final c = SignInController.at(_on('passwords.test'));
    await _pump(tester, c);
    final fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields[0].autofillHints, contains(AutofillHints.username));
    expect(fields[1].autofillHints, contains(AutofillHints.password));
    expect(find.byType(AutofillGroup), findsOneWidget);
    c.dispose();
  });

  testWidgets('a wrong password says so under the fields', (tester) async {
    final c = SignInController.at(_on('passwords.test'));
    await _pump(tester, c);
    await tester.enterText(find.widgetWithText(TextField, 'username'), 'chris');
    await tester.enterText(find.widgetWithText(TextField, 'password'), mockWrongPassword);
    await tester.tap(find.text('sign in'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('signing in…'), findsOneWidget);
    await tester.pump(SignInController.passwordDelay);
    expect(find.text("that username and password didn't match"), findsOneWidget);
    c.dispose();
  });

  testWidgets('a rate limit counts down on a disabled button', (tester) async {
    final c = SignInController.at(_on('passwords.test', retryIn: const Duration(seconds: 30)));
    await _pump(tester, c);
    final button = tester.widget<LoafButton>(find.widgetWithText(LoafButton, 'try again in 30s'));
    expect(button.onTap, isNull);
    expect(find.text('too many tries'), findsOneWidget);
    c.dispose();
  });

  testWidgets('a server with no usable way in says so', (tester) async {
    final c = SignInController.at(const SignInState(server: 'odd.test', check: ServerFound(ServerFlows())));
    await _pump(tester, c);
    expect(find.text('odd.test offers no sign-in loaf can use'), findsOneWidget);
    c.dispose();
  });
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `mise exec -- flutter test test/login_page_test.dart`
Expected: FAIL to compile, because `LoginPage` has no `controller` and `LoafButton` has no `leading`.

- [ ] **Step 3: Add `leading` to `LoafButton`** in `lib/ui/widgets/loaf_button.dart`:
  - Add the constructor parameter `this.leading,` after `this.icon,`.
  - Add the field, with its doc comment:
    ```dart
      /// Drawn where [icon] would be, for marks that are not icons (an identity
      /// provider's initial). Takes precedence over [icon].
      final Widget? leading;
    ```
  - In the build `Row`, replace `if (widget.icon != null) ...[` and its two children with:

```dart
                  if (widget.leading != null) ...[
                    widget.leading!,
                    const SizedBox(width: LoafSpace.x2),
                  ] else if (widget.icon != null) ...[
                    Icon(widget.icon, size: 18, color: labelColor),
                    const SizedBox(width: LoafSpace.x2),
                  ],
```

- [ ] **Step 4: Create `lib/ui/widgets/loaf_field.dart`.** It's the old `_Field`, with the extra hooks:

```dart
/// A single-line input in the app's shape: an icon, the text, and room for a
/// trailing control. Sign-in and recovery both use it.
library;

import 'package:flutter/material.dart';

import '../theme/loaf_theme.dart';

class LoafField extends StatelessWidget {
  const LoafField({
    super.key,
    required this.controller,
    required this.hint,
    required this.icon,
    this.obscure = false,
    this.autofocus = false,
    this.onSubmit,
    this.onChanged,
    this.autofillHints,
    this.textInputAction,
    this.trailing,
  });

  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final bool obscure;
  final bool autofocus;
  final VoidCallback? onSubmit;
  final ValueChanged<String>? onChanged;
  final Iterable<String>? autofillHints;
  final TextInputAction? textInputAction;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x3),
      decoration: BoxDecoration(
        color: tokens.card,
        borderRadius: BorderRadius.circular(LoafRadius.lg),
        border: Border.all(color: tokens.border),
      ),
      child: Row(
        children: [
          Icon(icon, size: 17, color: tokens.textMuted),
          const SizedBox(width: LoafSpace.x2),
          Expanded(
            child: TextField(
              controller: controller,
              obscureText: obscure,
              autofocus: autofocus,
              autofillHints: autofillHints,
              textInputAction: textInputAction,
              onChanged: onChanged,
              onSubmitted: (_) => onSubmit?.call(),
              style: loafBody(15, 400, height: 1.4).copyWith(color: tokens.textBody),
              decoration: InputDecoration(
                // Collapsed, so the field contributes exactly its line box and
                // the Row's centring does the vertical work. The composer needs
                // an asymmetric nudge because it bottom-aligns against taller
                // controls; that constant is specific to that layout and does
                // not transfer here.
                isCollapsed: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                hintText: hint,
                hintStyle: loafBody(15, 400, height: 1.4).copyWith(color: tokens.textMuted),
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
```

(`?trailing` is Dart 3.8's null-aware element, which the `^3.13` SDK floor allows. If `flutter analyze` objects, use `if (trailing != null) trailing!`.)

- [ ] **Step 5: Create `lib/ui/widgets/error_note.dart`.** It's the old `_ErrorNote`, now public:

```dart
/// Something went wrong, said once in the brand's one red. Used under forms,
/// never as a banner.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/loaf_theme.dart';

class ErrorNote extends StatelessWidget {
  const ErrorNote({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(LoafSpace.x3),
      decoration: BoxDecoration(
        color: tokens.accentSoft,
        borderRadius: BorderRadius.circular(LoafRadius.md),
        border: Border.all(color: tokens.accent),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.triangleAlert, size: 16, color: tokens.accent),
          const SizedBox(width: LoafSpace.x2),
          Expanded(
            child: Text(message, style: loafBody(13, 400).copyWith(color: tokens.textBody)),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 6: Rewrite `lib/ui/auth/login_page.dart`.** Keep `_Wordmark` and `_Heading`'s "come on *in*" exactly as they are. `_Heading` gains a soft-logout branch in Task 4; for now it keeps `editingServer`. Delete `LoginLook`, `_Field`, `_ErrorNote` and `_ProbingNote`. The new top of the file, the state class, and the new private widgets:

```dart
/// Sign-in, as a design mockup: [SignInController] plays a fake homeserver
/// and this draws whatever state it reports.
///
/// Homeservers differ in what they accept, so the screen renders whatever
/// `/_matrix/client/v3/login` reports. loaf.moe advertises `m.login.sso`
/// (delegated to Kanidm, named "loaf.moe") and `m.login.password`; other
/// servers offer one, the other, or several identity providers. See
/// "Sign-in and verification" in the design spec.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/loaf_theme.dart';
import '../widgets/error_note.dart';
import '../widgets/loaf_button.dart';
import '../widgets/loaf_field.dart';
import 'sign_in_controller.dart';
import 'sign_in_state.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.controller, this.onSignOutInstead});

  final SignInController controller;

  /// Soft logout only: give up on this account, and this device's keys with
  /// it.
  final VoidCallback? onSignOutInstead;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _server = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();

  /// Which face of the form is showing. Presentation only, like the drawer
  /// or a collapsed category.
  var _showingPassword = false;
  var _editingServer = false;

  SignInController get _c => widget.controller;

  @override
  void dispose() {
    _server.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  void _editServer() {
    _server.text = _c.state.server;
    setState(() => _editingServer = true);
  }

  void _connect() {
    if (serverNameFrom(_server.text) == null) return;
    _c.connect(_server.text);
    setState(() => _editingServer = false);
  }

  void _usernameChanged(String text) {
    // Someone typing here has chosen the form: a re-point to a server that
    // leads with SSO must not pull it out from under them.
    _showingPassword = true;
    _c.usernameChanged(text);
  }

  void _submitPassword() {
    final soft = _c.state.softLogout;
    _c.signInWithPassword(soft?.userId ?? _user.text, _password.text);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Scaffold(
      backgroundColor: tokens.page,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(LoafSpace.x6),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: ListenableBuilder(
                listenable: _c,
                builder: (context, _) => Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _faces(tokens, _c.state),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _faces(LoafTokens tokens, SignInState s) {
    final check = s.check;
    final failed = check is ServerFailed ? check : null;
    return [
      const _Wordmark(),
      const SizedBox(height: LoafSpace.x6),
      _Heading(tokens: tokens, editingServer: _editingServer),
      const SizedBox(height: LoafSpace.x8),
      // Choosing a homeserver replaces the sign-in controls rather than
      // sitting under them: otherwise the screen asks two questions at once.
      if (_editingServer)
        ..._serverSection()
      else ...[
        ..._authSection(tokens, s),
        const SizedBox(height: LoafSpace.x5),
        _ServerRow(
          tokens: tokens,
          server: s.repointing ?? s.server,
          looking: s.repointing != null,
          onEdit: _editServer,
        ),
        if (failed != null) ...[
          const SizedBox(height: LoafSpace.x3),
          ErrorNote(message: failed.messageFor(s.server)),
        ],
      ],
    ];
  }

  /// The homeserver picker, shown instead of the sign-in controls.
  List<Widget> _serverSection() => [
    LoafField(
      controller: _server,
      hint: 'homeserver',
      icon: LucideIcons.server,
      autofocus: true,
      onSubmit: _connect,
    ),
    const SizedBox(height: LoafSpace.x3),
    LoafButton(label: 'connect', onTap: _connect),
    Padding(
      padding: const EdgeInsets.only(top: LoafSpace.x3),
      child: LoafButton(
        label: 'cancel',
        onTap: () => setState(() => _editingServer = false),
        emphasis: LoafButtonEmphasis.quiet,
        size: LoafButtonSize.small,
      ),
    ),
  ];

  List<Widget> _authSection(LoafTokens tokens, SignInState s) {
    switch (s.check) {
      case ServerProbing():
        return [_WorkingNote(tokens: tokens, label: 'looking for ${s.server}')];
      case ServerFailed():
        return [LoafButton(label: 'try again', icon: LucideIcons.refreshCw, onTap: _c.retry)];
      case ServerFound(:final flows):
        if (!flows.sso && !flows.password) {
          return [ErrorNote(message: '${s.server} offers no sign-in loaf can use')];
        }
        if (s.activity == SignInActivity.finishingSso) {
          return [_WorkingNote(tokens: tokens, label: 'signing in…')];
        }
        if (flows.password && (_showingPassword || !flows.sso)) {
          return _passwordForm(s, flows);
        }
        return _ssoButtons(flows);
    }
  }

  List<Widget> _passwordForm(SignInState s, ServerFlows flows) {
    final soft = s.softLogout != null;
    final busy = s.activity == SignInActivity.checkingPassword;
    final wait = s.retryIn;
    final label = wait != null
        ? 'try again in ${wait.inSeconds}s'
        : busy
        ? 'signing in…'
        : 'sign in';
    return [
      AutofillGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // A soft-logged-out device already knows whose it is.
            if (!soft) ...[
              LoafField(
                controller: _user,
                hint: 'username',
                icon: LucideIcons.atSign,
                autofillHints: const [AutofillHints.username],
                textInputAction: TextInputAction.next,
                onChanged: _usernameChanged,
              ),
              const SizedBox(height: LoafSpace.x2),
            ],
            LoafField(
              controller: _password,
              hint: 'password',
              icon: LucideIcons.keyRound,
              obscure: true,
              autofillHints: const [AutofillHints.password],
              textInputAction: TextInputAction.done,
              onSubmit: _submitPassword,
            ),
          ],
        ),
      ),
      if (s.wrongPassword) ...[
        const SizedBox(height: LoafSpace.x3),
        ErrorNote(
          message: soft
              ? "that password didn't match"
              : "that username and password didn't match",
        ),
      ],
      if (wait != null) ...[
        const SizedBox(height: LoafSpace.x3),
        const ErrorNote(message: 'too many tries'),
      ],
      const SizedBox(height: LoafSpace.x3),
      LoafButton(label: label, onTap: busy || wait != null ? null : _submitPassword),
      if (flows.sso)
        Padding(
          padding: const EdgeInsets.only(top: LoafSpace.x3),
          child: LoafButton(
            label: flows.providers.length == 1
                ? 'back to ${flows.providers.single.name}'
                : 'back to other ways in',
            onTap: () => setState(() => _showingPassword = false),
            emphasis: LoafButtonEmphasis.quiet,
            size: LoafButtonSize.small,
          ),
        ),
    ];
  }

  List<Widget> _ssoButtons(ServerFlows flows) {
    final providers = flows.providers;
    return [
      if (providers.length == 1)
        LoafButton(
          label: 'continue with ${providers.single.name}',
          icon: LucideIcons.logIn,
          onTap: () => _c.continueWithSso(providers.single),
        )
      else
        // The server's order is not a preference, so no provider gets the
        // filled button.
        for (final (i, p) in providers.indexed) ...[
          if (i > 0) const SizedBox(height: LoafSpace.x2),
          LoafButton(
            label: 'continue with ${p.name}',
            leading: _ProviderMark(provider: p),
            emphasis: LoafButtonEmphasis.outlined,
            onTap: () => _c.continueWithSso(p),
          ),
        ],
      // Offered only where it leads somewhere: a server advertising no
      // m.login.password gets no link to a form it would reject.
      if (flows.password)
        Padding(
          padding: const EdgeInsets.only(top: LoafSpace.x3),
          child: LoafButton(
            label: 'use a username and password',
            onTap: () => setState(() => _showingPassword = true),
            emphasis: LoafButtonEmphasis.quiet,
            size: LoafButtonSize.small,
          ),
        ),
    ];
  }
}

/// An identity provider's initial, standing in for its mxc icon.
class _ProviderMark extends StatelessWidget {
  const _ProviderMark({required this.provider});

  final IdentityProvider provider;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Container(
      width: 20,
      height: 20,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: tokens.sunken, shape: BoxShape.circle),
      child: Text(provider.initial, style: loafBody(11, 600).copyWith(color: tokens.textStrong)),
    );
  }
}
```

Replace `_ServerRow` with a version that can show it's looking:

```dart
/// The homeserver, as a quiet line under the sign-in controls. Most people
/// never touch it, so it does not get to look like a form until tapped.
class _ServerRow extends StatelessWidget {
  const _ServerRow({required this.tokens, required this.server, required this.looking, required this.onEdit});

  final LoafTokens tokens;
  final String server;

  /// A full id in the username named this server and it is being checked.
  final bool looking;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      onTap: onEdit,
      behavior: HitTestBehavior.opaque,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (looking) ...[
            SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(strokeWidth: 1.5, color: tokens.textMuted),
            ),
            const SizedBox(width: LoafSpace.x2),
          ],
          Text(looking ? 'looking for ' : 'on ', style: loafBody(13, 400).copyWith(color: tokens.textMuted)),
          Flexible(
            child: Text(
              server,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: loafBody(13, 600).copyWith(color: tokens.textBody),
            ),
          ),
          if (!looking) ...[
            const SizedBox(width: LoafSpace.x1),
            Icon(LucideIcons.pencil, size: 13, color: tokens.textMuted),
          ],
        ],
      ),
    ),
  );
}
```

Rename `_ProbingNote` to `_WorkingNote(tokens, label)`. The body is unchanged, except that the `Text` shows `label` instead of `'looking for $server'`.

- [ ] **Step 7: Keep `main.dart` compiling.** It doesn't import `LoginPage` yet, so there's nothing to change. Confirm with `grep -rn LoginLook lib test`, which should find nothing.

- [ ] **Step 8: Run the tests and watch them pass**

Run: `mise exec -- flutter test test/login_page_test.dart`
Expected: PASS. Then run `mise exec -- flutter analyze`. Expected: no issues.

- [ ] **Step 9: Checkpoint.** Suggested commit: `feat(ui): the sign-in screen draws a fake homeserver's answers`. The body should mention several providers as equals, re-pointing from a full id, and autofill.

---

### Task 4: The desktop browser wait, soft logout, and long names

**Files:**
- Create: `lib/ui/auth/browser_wait.dart`
- Modify: `lib/ui/auth/login_page.dart`
- Test: `test/login_page_test.dart` (append)

**Interfaces:**
- Consumes: Task 3.
- Produces: `BrowserWait({required String name, required VoidCallback onReopen, required VoidCallback onCancel})`. The verify panel's reset step reuses it in Task 8.

- [ ] **Step 1: Write the failing tests.** Append these inside `main()` in `test/login_page_test.dart`, and add `import 'package:loaf_native/ui/mock/fixtures.dart';` to the imports:

```dart
  testWidgets(
    'a computer waits on the browser, and can open it again',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      var signedIn = false;
      final c = SignInController.at(_on('loaf.moe'), onSignedIn: () => signedIn = true);
      await _pump(tester, c, size: _mac);
      await tester.tap(find.text('continue with loaf.moe'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('finish in your browser'), findsOneWidget);
      expect(find.text('open it again'), findsOneWidget);

      await tester.tap(find.text('cancel'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('continue with loaf.moe'), findsOneWidget);

      await tester.tap(find.text('continue with loaf.moe'));
      await tester.pump(SignInController.browserDelay);
      expect(signedIn, isTrue);
      c.dispose();
    },
  );

  testWidgets(
    'a phone never shows the browser wait',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      final c = SignInController.at(_on('loaf.moe'));
      await _pump(tester, c);
      await tester.tap(find.text('continue with loaf.moe'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('finish in your browser'), findsNothing);
      expect(find.text('signing in…'), findsOneWidget);
      await tester.pump(SignInController.ssoSheetDelay);
      c.dispose();
    },
  );

  group('soft logout', () {
    SignInState soft(String server) => SignInState(
      server: server,
      check: mockServers[server]!,
      softLogout: const SoftLogout(member: currentUser, userId: '@faore:loaf.moe'),
    );

    testWidgets('is locked to the account, with no server to change', (tester) async {
      final c = SignInController.at(soft('loaf.moe'));
      await _pump(tester, c);
      expect(find.text('sign in again as @faore:loaf.moe'), findsOneWidget);
      expect(find.text(currentUser.initials), findsOneWidget);
      expect(find.text('on '), findsNothing);
      expect(find.text('continue with loaf.moe'), findsOneWidget);

      await tester.tap(find.text('use a username and password'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.widgetWithText(TextField, 'username'), findsNothing);
      expect(find.widgetWithText(TextField, 'password'), findsOneWidget);
      c.dispose();
    });

    testWidgets('signing out instead asks first', (tester) async {
      var out = false;
      final c = SignInController.at(soft('loaf.moe'));
      await _pump(tester, c, onSignOutInstead: () => out = true);
      await tester.tap(find.text('sign out instead'));
      await tester.pumpAndSettle();
      expect(find.textContaining("this device's encryption keys"), findsOneWidget);

      await tester.tap(find.text('keep signing in'));
      await tester.pumpAndSettle();
      expect(out, isFalse);

      await tester.tap(find.text('sign out instead'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('sign out'));
      await tester.pumpAndSettle();
      expect(out, isTrue);
      c.dispose();
    });

    for (final size in [_phone, _mac]) {
      testWidgets('lays out at ${size.width.toInt()} wide', (tester) async {
        final c = SignInController.at(soft('loaf.moe'));
        await _pump(tester, c, size: size);
        expect(tester.takeException(), isNull);
        c.dispose();
      });
    }
  });

  group('long names', () {
    const long = 'a-very-long-homeserver-name-that-goes-on-and-on.example.org';

    testWidgets('fit in the row, the probe, the failure and the wait', (tester) async {
      for (final state in [
        const SignInState(server: long, check: ServerProbing()),
        const SignInState(server: long, check: ServerFailed(ServerProblem.delegationBroken, delegatedTo: 'matrix.$long')),
        SignInState(server: 'passwords.test', check: mockServers['passwords.test']!, repointing: long),
        const SignInState(
          server: long,
          check: ServerFound(ServerFlows(providers: [IdentityProvider('x', long)])),
          activity: SignInActivity.inBrowser,
          provider: IdentityProvider('x', long),
        ),
      ]) {
        final c = SignInController.at(state);
        await _pump(tester, c);
        expect(tester.takeException(), isNull, reason: '$state');
        c.dispose();
      }
    });
  });
```

- [ ] **Step 2: Run them and watch them fail**

Run: `mise exec -- flutter test test/login_page_test.dart`
Expected: FAIL. The texts "finish in your browser" and "sign in again as …" aren't found.

- [ ] **Step 3: Create `lib/ui/auth/browser_wait.dart`:**

```dart
/// Desktop SSO: the real browser has the conversation, and this only waits
/// for it to hand back. The verify panel's reset reuses it for
/// re-authentication.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/loaf_theme.dart';
import '../widgets/loaf_button.dart';

class BrowserWait extends StatelessWidget {
  const BrowserWait({super.key, required this.name, required this.onReopen, required this.onCancel});

  /// Who the browser is signing in with: the identity provider's name.
  final String name;
  final VoidCallback onReopen;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(LucideIcons.externalLink, size: 28, color: tokens.textMuted),
        const SizedBox(height: LoafSpace.x3),
        Text(
          'finish in your browser',
          textAlign: TextAlign.center,
          style: loafDisplay(22, 600).copyWith(color: tokens.textStrong),
        ),
        const SizedBox(height: LoafSpace.x2),
        Text(
          "we opened $name in your browser. come back once you're signed in.",
          textAlign: TextAlign.center,
          style: loafBody(15, 400).copyWith(color: tokens.textMuted),
        ),
        const SizedBox(height: LoafSpace.x6),
        LoafButton(
          label: 'open it again',
          icon: LucideIcons.externalLink,
          emphasis: LoafButtonEmphasis.outlined,
          onTap: onReopen,
        ),
        const SizedBox(height: LoafSpace.x3),
        LoafButton(
          label: 'cancel',
          onTap: onCancel,
          emphasis: LoafButtonEmphasis.quiet,
          size: LoafButtonSize.small,
        ),
      ],
    );
  }
}
```

- [ ] **Step 4: Wire the faces into `login_page.dart`.**
  - Import `'../widgets/adaptive_panel.dart'`, `'../mock/fixtures.dart'` and `'browser_wait.dart'`.
  - Add a method to `_LoginPageState`:

```dart
  Future<void> _confirmSignOut(SoftLogout soft) async {
    final yes = await showAdaptivePanel<bool>(
      context,
      maxHeight: 320,
      child: _SignOutInstead(userId: soft.userId),
    );
    if (yes == true) widget.onSignOutInstead?.call();
  }
```

Replace `_faces` with:

```dart
  List<Widget> _faces(LoafTokens tokens, SignInState s) {
    // The browser has the conversation now; the screen only waits for it.
    if (s.activity == SignInActivity.inBrowser) {
      return [
        const _Wordmark(),
        const SizedBox(height: LoafSpace.x8),
        BrowserWait(
          name: s.provider?.name ?? s.server,
          onReopen: _c.reopenBrowser,
          onCancel: _c.cancelSso,
        ),
      ];
    }
    final soft = s.softLogout;
    final check = s.check;
    final failed = check is ServerFailed ? check : null;
    return [
      if (soft == null) const _Wordmark() else _Avatar(member: soft.member),
      const SizedBox(height: LoafSpace.x6),
      _Heading(tokens: tokens, softLogout: soft, editingServer: _editingServer),
      const SizedBox(height: LoafSpace.x8),
      // Choosing a homeserver replaces the sign-in controls rather than
      // sitting under them: otherwise the screen asks two questions at once.
      if (_editingServer)
        ..._serverSection()
      else ...[
        ..._authSection(tokens, s),
        // A soft-logged-out device belongs to its account's server.
        if (soft == null) ...[
          const SizedBox(height: LoafSpace.x5),
          _ServerRow(
            tokens: tokens,
            server: s.repointing ?? s.server,
            looking: s.repointing != null,
            onEdit: _editServer,
          ),
        ],
        if (failed != null) ...[
          const SizedBox(height: LoafSpace.x3),
          ErrorNote(message: failed.messageFor(s.server)),
        ],
        if (soft != null) ...[
          const SizedBox(height: LoafSpace.x5),
          LoafButton(
            label: 'sign out instead',
            onTap: () => _confirmSignOut(soft),
            emphasis: LoafButtonEmphasis.quiet,
            size: LoafButtonSize.small,
          ),
        ],
      ],
    ];
  }
```

`_Heading` gains `this.softLogout` (a `SoftLogout?`). When it's set, the display line reads "welcome " plus an italic accent "back" (the same `TextSpan` pattern as "come on *in*"), and the subtitle reads `'sign in again as ${softLogout!.userId}'`. Give the subtitle `maxLines: 2` and `overflow: TextOverflow.ellipsis` so a long id can't overflow. Otherwise it behaves as before.

Add the new private widgets:

```dart
/// Soft logout leads with who you are, since the screen is locked to them.
class _Avatar extends StatelessWidget {
  const _Avatar({required this.member});

  final Member member;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Center(
      child: Container(
        width: 64,
        height: 64,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: member.color, shape: BoxShape.circle, boxShadow: tokens.shadowMd),
        child: Text(member.initials, style: loafBody(24, 600).copyWith(color: Colors.white)),
      ),
    );
  }
}

class _SignOutInstead extends StatelessWidget {
  const _SignOutInstead({required this.userId});

  final String userId;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(LoafSpace.x5),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('sign out of $userId?', style: loafBody(17, 600).copyWith(color: tokens.textStrong)),
          const SizedBox(height: LoafSpace.x2),
          Text(
            "this device's encryption keys go with it. anything only this "
            "device could read stays unreadable unless it's in key backup.",
            style: loafBody(14, 400).copyWith(color: tokens.textMuted),
          ),
          const SizedBox(height: LoafSpace.x5),
          LoafButton(label: 'sign out', onTap: () => Navigator.pop(context, true)),
          const SizedBox(height: LoafSpace.x2),
          LoafButton(
            label: 'keep signing in',
            onTap: () => Navigator.pop(context, false),
            emphasis: LoafButtonEmphasis.quiet,
            size: LoafButtonSize.small,
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 5: Run the tests and watch them pass**

Run: `mise exec -- flutter test test/login_page_test.dart`, then `mise exec -- flutter analyze`.
Expected: PASS, with no issues.

- [ ] **Step 6: Checkpoint.** Suggested commit: `feat(ui): a browser wait on computers and a welcome back for soft logout`.

---

### Task 5: MockSession and SessionRoot put sign-in in front of the app

**Files:**
- Create: `lib/ui/mock/mock_session.dart`
- Create: `lib/ui/auth/session_root.dart`
- Modify: `lib/main.dart`
- Modify: `lib/ui/shell/app_shell.dart` (the `session` param, the notice read from trust, and two levers)
- Modify: `lib/ui/shell/mock_debug.dart` (`signOut`, `expireSession`)
- Test: `test/mock_session_test.dart`, `test/session_root_test.dart`

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces:
  - `enum AccountState { signedOut, softLoggedOut, signedIn }`.
  - `enum DeviceTrust { noIdentity, unverified, verified }`.
  - `IncomingRequest({required String device, required DateTime at})`.
  - `MockSession({AccountState account, DeviceTrust trust})`. Its members are `account`, `trust`, `incoming`, `me`, `userId`, `softLogout`, `failNext()`, `consumeFailure()`, `signOut()`, `expireSession()`, `signedIn()`, `markVerified()`, and the constant `static const server = 'loaf.moe'`.
  - `SessionRoot({required MockSession session})`.
  - `AppShell({Key? key, MockSession? session})`.

- [ ] **Step 1: Write the failing tests.** First, `test/mock_session_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/mock/mock_session.dart';

void main() {
  test('opens signed in on an unverified device', () {
    final s = MockSession();
    expect(s.account, AccountState.signedIn);
    expect(s.trust, DeviceTrust.unverified);
    expect(s.userId, '@faore:loaf.moe');
    expect(s.softLogout, isNull);
  });

  test('signing out loses the device, so the next one starts unverified', () {
    final s = MockSession(trust: DeviceTrust.verified)..signOut();
    expect(s.account, AccountState.signedOut);
    s.signedIn();
    expect(s.trust, DeviceTrust.unverified);
  });

  test('a soft logout keeps the keys, so trust survives it', () {
    final s = MockSession(trust: DeviceTrust.verified)..expireSession();
    expect(s.account, AccountState.softLoggedOut);
    expect(s.softLogout!.userId, '@faore:loaf.moe');
    s.signedIn();
    expect(s.trust, DeviceTrust.verified);
  });

  test('only a signed-in session can expire', () {
    final s = MockSession()..signOut()..expireSession();
    expect(s.account, AccountState.signedOut);
  });

  test('the failure lever is spent once', () {
    final s = MockSession()..failNext();
    expect(s.consumeFailure(), isTrue);
    expect(s.consumeFailure(), isFalse);
  });

  test('verifying marks the device trusted', () {
    final s = MockSession()..markVerified();
    expect(s.trust, DeviceTrust.verified);
  });
}
```

Then `test/session_root_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/auth/session_root.dart';
import 'package:loaf_native/ui/auth/sign_in_controller.dart';
import 'package:loaf_native/ui/mock/mock_session.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

const _wide = Size(1440, 900);

/// Tests that end on the sign-in screen pump past its probe first, so no
/// timer is left pending.
Future<MockSession> _pumpRoot(WidgetTester tester, {MockSession? session, Size size = _wide}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final s = session ?? MockSession();
  await tester.pumpWidget(
    MaterialApp(
      theme: loafLightTheme(),
      darkTheme: loafDarkTheme(),
      themeMode: ThemeMode.dark,
      home: SessionRoot(session: s),
    ),
  );
  await tester.pumpAndSettle();
  return s;
}

void main() {
  testWidgets('a signed-in session opens on the app', (tester) async {
    await _pumpRoot(tester);
    expect(find.text('The Starter Pack'), findsOneWidget);
  });

  testWidgets('signing out swaps in sign-in, and signing in swaps back', (tester) async {
    final s = await _pumpRoot(tester);
    s.signOut();
    await tester.pump();
    expect(find.text('looking for loaf.moe'), findsOneWidget);

    await tester.pump(SignInController.probeDelay);
    await tester.tap(find.text('continue with loaf.moe'));
    await tester.pump(SignInController.ssoSheetDelay);
    await tester.pumpAndSettle();
    expect(find.text('The Starter Pack'), findsOneWidget);
    expect(find.byTooltip('verify this session'), findsOneWidget);
  });

  testWidgets('an expired session asks for this account again', (tester) async {
    final s = await _pumpRoot(tester);
    s.expireSession();
    await tester.pump();
    await tester.pump(SignInController.probeDelay);
    expect(find.text('sign in again as @faore:loaf.moe'), findsOneWidget);

    await tester.tap(find.text('sign out instead'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('sign out'));
    await tester.pump();
    await tester.pump(SignInController.probeDelay);
    // A fresh sign-in: the server can be changed again.
    expect(find.text('sign in again as @faore:loaf.moe'), findsNothing);
    expect(find.text('on '), findsOneWidget);
  });

  testWidgets('a verified device shows no verify notice', (tester) async {
    await _pumpRoot(tester, session: MockSession(trust: DeviceTrust.verified));
    expect(find.byTooltip('verify this session'), findsNothing);
  });

  testWidgets('the debug menu can sign you out', (tester) async {
    await _pumpRoot(tester);
    await tester.tap(find.byTooltip('Debug'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('sign out'));
    await tester.pump();
    await tester.pump(SignInController.probeDelay);
    expect(find.text('continue with loaf.moe'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `mise exec -- flutter test test/mock_session_test.dart test/session_root_test.dart`
Expected: FAIL to compile, because the files don't exist yet.

- [ ] **Step 3: Create `lib/ui/mock/mock_session.dart`:**

```dart
/// Who is signed in and how far this device is trusted — mockup only.
/// Stands in for the SDK's login state and cross-signing status. Debug
/// levers move it where the fixtures never go on their own.
library;

import 'package:flutter/foundation.dart';

import '../auth/sign_in_state.dart';
import 'fixtures.dart';

enum AccountState { signedOut, softLoggedOut, signedIn }

/// How far this device is trusted, which decides the rail's encryption
/// notice.
enum DeviceTrust {
  /// The account has no cross-signing identity yet: set up recovery.
  noIdentity,

  /// There is an identity and this device is not signed by it: verify.
  unverified,

  verified,
}

/// Another of your devices asking this one to vouch for it.
@immutable
class IncomingRequest {
  const IncomingRequest({required this.device, required this.at});

  final String device;
  final DateTime at;
}

class MockSession extends ChangeNotifier {
  MockSession({
    AccountState account = AccountState.signedIn,
    DeviceTrust trust = DeviceTrust.unverified,
  }) : _account = account,
       _trust = trust;

  /// The mock account's homeserver.
  static const server = 'loaf.moe';

  AccountState _account;
  DeviceTrust _trust;
  IncomingRequest? _incoming;
  var _failNext = false;

  AccountState get account => _account;
  DeviceTrust get trust => _trust;
  IncomingRequest? get incoming => _incoming;

  Member get me => currentUser;
  String get userId => '${currentUser.id}:$server';

  SoftLogout? get softLogout => _account == AccountState.softLoggedOut
      ? SoftLogout(member: me, userId: userId)
      : null;

  /// The debug "fail the next connection" lever.
  void failNext() => _failNext = true;

  /// Spends the lever, if armed.
  bool consumeFailure() {
    final fail = _failNext;
    _failNext = false;
    return fail;
  }

  void signOut() {
    _account = AccountState.signedOut;
    // Signing out deletes the device, and its keys with it: the next one
    // starts unverified.
    _trust = DeviceTrust.unverified;
    _incoming = null;
    notifyListeners();
  }

  /// The server rejected the token with `soft_logout: true`.
  void expireSession() {
    if (_account != AccountState.signedIn) return;
    _account = AccountState.softLoggedOut;
    _incoming = null;
    notifyListeners();
  }

  /// Trust stays as it was left: unverified after a sign-out, and kept after
  /// a soft logout, whose keys never left.
  void signedIn() {
    _account = AccountState.signedIn;
    notifyListeners();
  }

  void markVerified() {
    _trust = DeviceTrust.verified;
    notifyListeners();
  }
}
```

- [ ] **Step 4: Create `lib/ui/auth/session_root.dart`:**

```dart
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
```

- [ ] **Step 5: Open the app on `SessionRoot`** in `lib/main.dart`:
  - Add the imports `'ui/auth/session_root.dart'` and `'ui/mock/mock_session.dart'`, and drop the `app_shell.dart` import.
  - Below `themeMode`, add:

```dart
/// The mock's one account. Lives as long as the app, like [themeMode].
final session = MockSession();
```

Replace the comment and the child of `CallbackShortcuts` with:

```dart
        // Sign-in or the app, as the session says. The debug menu's levers
        // move between them.
        child: Focus(autofocus: true, child: SessionRoot(session: session)),
```

- [ ] **Step 6: Let `AppShell` take the session** (`lib/ui/shell/app_shell.dart`):
  - Import `'../mock/mock_session.dart'`.
  - Constructor and field:

```dart
class AppShell extends StatefulWidget {
  const AppShell({super.key, this.session});

  /// Who is signed in, and how far this device is trusted. The app passes
  /// its one session; left out (tests, previews), the shell makes its own.
  final MockSession? session;
```

  - In `_AppShellState`, add `late final MockSession _session = widget.session ?? MockSession();`.
  - In `initState`, add `_session.addListener(_onChange);`.
  - In `dispose`, add `_session.removeListener(_onChange); if (widget.session == null) _session.dispose();`.
  - Delete `final _showVerify = true;`. Its doc line "Mockup state: which app notices are showing." now refers only to `_showUpdate`, so change it to "Mockup state: whether the update notice is showing."
  - In `_notices`, replace `if (_showVerify) AppNotice.verify(onAction: () {}),` with:

```dart
    if (_session.trust == DeviceTrust.unverified)
      AppNotice.verify(onAction: () {}),
```

  - In `_debug`, extend the switch:

```dart
      case MockDebug.failNext:
        // One "make the next thing fail" lever: the next call, sign-in or
        // verification, whichever comes first for each.
        _calls.failNextConnection();
        _session.failNext();
      // ...existing cases unchanged...
      case MockDebug.signOut:
        _session.signOut();
      case MockDebug.expireSession:
        _session.expireSession();
```

- [ ] **Step 7: Add the levers** in `lib/ui/shell/mock_debug.dart`:
  - Update the library doc to "…a server that shares no presence, a session signed out or expired."
  - Append `signOut, expireSession,` to the enum.
  - Append to `items`:

```dart
    item(MockDebug.signOut, LucideIcons.logOut, 'sign out'),
    item(MockDebug.expireSession, LucideIcons.timerOff, 'expire the session'),
```

- [ ] **Step 8: Run the tests and watch them pass**

Run: `mise exec -- flutter test test/mock_session_test.dart test/session_root_test.dart test/app_shell_test.dart`, then `mise exec -- flutter analyze`.
Expected: PASS, with no issues. `app_shell_test` still pumps `const AppShell()`, which now makes its own unverified session.

- [ ] **Step 9: Checkpoint.** Suggested commit: `feat(ui): sign-in sits in front of the app, and levers move between them`.

---

### Task 6: Verification values, fixtures and VerificationController

**Files:**
- Create: `lib/ui/verify/verify_state.dart`
- Create: `lib/ui/verify/verification_controller.dart`
- Modify: `lib/ui/mock/accounts.dart` (append the verification fixtures)
- Test: `test/verification_controller_test.dart`

**Interfaces:**
- Consumes: `SignInController.browserDelay` and `ssoSheetDelay`, and `mockWrongPassword`.
- Produces:
  - `enum VerifyPurpose { verify, setUp, incoming }`.
  - `enum VerifyStep { choose, waitingForDevice, incomingPrompt, compareEmoji, waitingForOther, cancelled, notMe, recoveryKey, restoring, resetConfirm, resetAuth, setUpIntro, showKey, done }`.
  - `SasEmoji(String emoji, String name)`.
  - `VerifyState({required step, checking, rejected, restored, totalKeys, keySaved, inBrowser, closing})`.
  - `VerificationController({required purpose, required onTrusted, otherSessions, incomingDevice, reauthByPassword, consumeFailure, desktop})` and `@visibleForTesting .at(VerifyState, {...same, all optional})`.
  - Controller members: `state`, `canGoBack`, `worksUnseen`, `emoji`, `newRecoveryKey`, `doneMessage`, `back()`, `useAnotherDevice()`, `useRecoveryKey()`, `cantDoEither()`, `emojiMatch()`, `emojiMismatch()`, `tryAgain()`, `submitKey(String)`, `confirmReset()`, `reauthWithPassword(String)`, `reauthWithSso()`, `reopenBrowser()`, `cancelBrowser()`, `createKey()`, `keyKept()`, `finishSetUp()`, `acceptIncoming()` and `rejectIncoming()`.
  - Fixtures: `mockOtherSessions()`, `mockNewDevice()`, `mockRecoveryKey`, `mockRecoveryPassphrase`, `mockNewRecoveryKey`, `mockBackupKeys`, `mockSasEmoji` and `unlocksRecovery(String)`.

- [ ] **Step 1: Write the failing test** — `test/verification_controller_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/auth/sign_in_controller.dart';
import 'package:loaf_native/ui/mock/accounts.dart';
import 'package:loaf_native/ui/verify/verification_controller.dart';
import 'package:loaf_native/ui/verify/verify_state.dart';

/// Widget tests for the fake clock; each disposes its controller last.
void main() {
  late int trusted;
  setUp(() => trusted = 0);

  VerificationController make(VerifyPurpose purpose, {bool Function()? fail, bool byPassword = false, bool desktop = false}) =>
      VerificationController(
        purpose: purpose,
        onTrusted: () => trusted++,
        otherSessions: const ["faore's MacBook"],
        incomingDevice: 'loaf on iPhone',
        reauthByPassword: byPassword,
        consumeFailure: fail ?? () => false,
        desktop: desktop,
      );

  test('each purpose starts where it should', () {
    for (final (purpose, step) in [
      (VerifyPurpose.verify, VerifyStep.choose),
      (VerifyPurpose.setUp, VerifyStep.setUpIntro),
      (VerifyPurpose.incoming, VerifyStep.incomingPrompt),
    ]) {
      final c = make(purpose);
      expect(c.state.step, step);
      c.dispose();
    }
  });

  group('another device', () {
    testWidgets('waits, compares, confirms, then closes itself', (tester) async {
      final c = make(VerifyPurpose.verify);
      c.useAnotherDevice();
      expect(c.state.step, VerifyStep.waitingForDevice);
      await tester.pump(VerificationController.acceptDelay);
      expect(c.state.step, VerifyStep.compareEmoji);
      expect(c.emoji, hasLength(7));

      c.emojiMatch();
      expect(c.state.step, VerifyStep.waitingForOther);
      expect(trusted, 0);
      await tester.pump(VerificationController.confirmDelay);
      expect(trusted, 1);
      expect(c.state.step, VerifyStep.done);
      expect(c.state.closing, isFalse);
      await tester.pump(VerificationController.doneLinger);
      expect(c.state.closing, isTrue);
      c.dispose();
    });

    testWidgets('a mismatch trusts nothing', (tester) async {
      final c = make(VerifyPurpose.verify);
      c.useAnotherDevice();
      await tester.pump(VerificationController.acceptDelay);
      c.emojiMismatch();
      expect(c.state.step, VerifyStep.cancelled);
      await tester.pump(VerificationController.confirmDelay);
      expect(trusted, 0);
      c.dispose();
    });

    testWidgets('the failure lever makes the request go unanswered', (tester) async {
      var armed = true;
      final c = make(VerifyPurpose.verify, fail: () {
        final f = armed;
        armed = false;
        return f;
      });
      c.useAnotherDevice();
      await tester.pump(VerificationController.acceptDelay);
      expect(c.state.step, VerifyStep.cancelled);
      c.tryAgain();
      await tester.pump(VerificationController.acceptDelay);
      expect(c.state.step, VerifyStep.compareEmoji);
      c.dispose();
    });

    testWidgets('going back while waiting drops the pending answer', (tester) async {
      final c = make(VerifyPurpose.verify);
      c.useAnotherDevice();
      expect(c.canGoBack, isTrue);
      c.back();
      await tester.pump(VerificationController.acceptDelay);
      expect(c.state.step, VerifyStep.choose);
      c.dispose();
    });

    test('there is no going back mid-comparison', () {
      final c = VerificationController.at(const VerifyState(step: VerifyStep.compareEmoji));
      expect(c.canGoBack, isFalse);
      c.dispose();
    });
  });

  group('recovery key', () {
    testWidgets('a wrong key is turned away', (tester) async {
      final c = make(VerifyPurpose.verify)..useRecoveryKey();
      c.submitKey('EsTc nope');
      expect(c.state.checking, isTrue);
      await tester.pump(VerificationController.keyCheckDelay);
      expect(c.state.rejected, isTrue);
      expect(trusted, 0);
      c.dispose();
    });

    testWidgets('the key unlocks however it was pasted, then history restores', (tester) async {
      final c = make(VerifyPurpose.verify)..useRecoveryKey();
      final messy = '  ${mockRecoveryKey.replaceAll(' ', '\n')}  \n';
      c.submitKey(messy);
      await tester.pump(VerificationController.keyCheckDelay);
      // Trusted as soon as the key opens secret storage; history follows.
      expect(trusted, 1);
      expect(c.state.step, VerifyStep.restoring);
      expect(c.worksUnseen, isTrue);

      await tester.pump(VerificationController.restoreTick * 3);
      expect(c.state.restored, greaterThan(0));
      expect(c.state.totalKeys, mockBackupKeys);

      await tester.pump(VerificationController.restoreTick * 20);
      expect(c.state.step, VerifyStep.done);
      await tester.pump(VerificationController.doneLinger);
      c.dispose();
    });

    testWidgets('the passphrase unlocks too', (tester) async {
      final c = make(VerifyPurpose.verify)..useRecoveryKey();
      c.submitKey(mockRecoveryPassphrase);
      await tester.pump(VerificationController.keyCheckDelay);
      expect(c.state.step, VerifyStep.restoring);
      c.dispose();
    });

    test('back returns to the choice', () {
      final c = make(VerifyPurpose.verify)..useRecoveryKey()..back();
      expect(c.state.step, VerifyStep.choose);
      c.dispose();
    });
  });

  group('reset', () {
    testWidgets('a password account types its password, then saves a new key', (tester) async {
      final c = make(VerifyPurpose.verify, byPassword: true)..cantDoEither();
      expect(c.state.step, VerifyStep.resetConfirm);
      c.confirmReset();
      expect(c.state.step, VerifyStep.resetAuth);
      c.back();
      expect(c.state.step, VerifyStep.resetConfirm);
      c.confirmReset();

      c.reauthWithPassword(mockWrongPassword);
      await tester.pump(VerificationController.keyCheckDelay);
      expect(c.state.rejected, isTrue);

      c.reauthWithPassword('hunter2');
      await tester.pump(VerificationController.keyCheckDelay);
      expect(c.state.step, VerifyStep.showKey);

      c.finishSetUp();
      expect(c.state.step, VerifyStep.showKey, reason: 'not before the key is kept');
      c.keyKept();
      c.finishSetUp();
      expect(trusted, 1);
      expect(c.state.step, VerifyStep.done);
      await tester.pump(VerificationController.doneLinger);
      c.dispose();
    });

    testWidgets('an sso account goes through the browser on a computer', (tester) async {
      final c = make(VerifyPurpose.verify, desktop: true)..cantDoEither()..confirmReset();
      c.reauthWithSso();
      expect(c.state.inBrowser, isTrue);
      c.cancelBrowser();
      expect(c.state.inBrowser, isFalse);
      c.reauthWithSso();
      await tester.pump(SignInController.browserDelay);
      expect(c.state.step, VerifyStep.showKey);
      c.dispose();
    });
  });

  testWidgets('setting up: create, keep, finish', (tester) async {
    final c = make(VerifyPurpose.setUp)..createKey();
    expect(c.state.step, VerifyStep.showKey);
    expect(c.newRecoveryKey, mockNewRecoveryKey);
    c.keyKept();
    expect(c.state.keySaved, isTrue);
    c.finishSetUp();
    expect(trusted, 1);
    expect(c.doneMessage, 'recovery is set up');
    await tester.pump(VerificationController.doneLinger);
    c.dispose();
  });

  group('incoming', () {
    testWidgets('vouching for the new device trusts nothing here', (tester) async {
      final c = make(VerifyPurpose.incoming)..acceptIncoming();
      expect(c.state.step, VerifyStep.compareEmoji);
      c.emojiMatch();
      await tester.pump(VerificationController.confirmDelay);
      expect(c.state.step, VerifyStep.done);
      expect(trusted, 0);
      expect(c.doneMessage, 'loaf on iPhone is verified');
      await tester.pump(VerificationController.doneLinger);
      c.dispose();
    });

    test("that's not me cancels", () {
      final c = make(VerifyPurpose.incoming)..rejectIncoming();
      expect(c.state.step, VerifyStep.notMe);
      expect(c.canGoBack, isFalse);
      c.dispose();
    });
  });

  testWidgets('disposing mid-restore leaves no timer behind', (tester) async {
    final c = make(VerifyPurpose.verify)..useRecoveryKey();
    c.submitKey(mockRecoveryKey);
    await tester.pump(VerificationController.keyCheckDelay);
    c.dispose();
  });
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `mise exec -- flutter test test/verification_controller_test.dart`
Expected: FAIL to compile.

- [ ] **Step 3: Create `lib/ui/verify/verify_state.dart`:**

```dart
/// What a verification panel can be showing, as plain values. See
/// "Verifying a session" in the design spec.
library;

import 'package:flutter/foundation.dart';

/// Why the panel is open: to verify this session, to give a fresh account an
/// identity, or to vouch for another device of yours.
enum VerifyPurpose { verify, setUp, incoming }

enum VerifyStep {
  choose,

  /// `m.key.verification.request` is out; nobody has accepted yet.
  waitingForDevice,

  /// Another device asks this one to vouch for it.
  incomingPrompt,

  /// SAS: the 7 emoji both ends show.
  compareEmoji,

  /// This end said they match; the other has not yet.
  waitingForOther,

  /// A mismatch, a refusal or no answer. Nothing was trusted.
  cancelled,

  /// Incoming, refused as not you.
  notMe,

  recoveryKey,

  /// Secret storage unlocked; key backup is being pulled in.
  restoring,

  resetConfirm,

  /// User-interactive auth before new cross-signing keys go up.
  resetAuth,

  setUpIntro,
  showKey,
  done,
}

/// One SAS emoji and the name printed under it, so two people can read the
/// comparison aloud.
@immutable
class SasEmoji {
  const SasEmoji(this.emoji, this.name);

  final String emoji;
  final String name;
}

@immutable
class VerifyState {
  const VerifyState({
    required this.step,
    this.checking = false,
    this.rejected = false,
    this.restored = 0,
    this.totalKeys = 0,
    this.keySaved = false,
    this.inBrowser = false,
    this.closing = false,
  });

  final VerifyStep step;

  /// A key or password is being checked.
  final bool checking;

  /// The last key or password was wrong.
  final bool rejected;

  /// Key backup progress, while [step] is restoring.
  final int restored;
  final int totalKeys;

  /// The new recovery key was copied or saved at least once.
  final bool keySaved;

  /// Reset's SSO re-auth is in the real browser (desktop).
  final bool inBrowser;

  /// Done has lingered long enough to be read; the panel should go.
  final bool closing;
}
```

- [ ] **Step 4: Append the verification fixtures to `lib/ui/mock/accounts.dart`.**
  - Add the imports `'../platform.dart'` and `'../verify/verify_state.dart'`.
  - Extend the library doc with: "Unlock with [mockRecoveryKey] or [mockRecoveryPassphrase]."
  - Append:

```dart
/// This account's other sessions, which "use another device" can ask. The
/// device you are on is never among them.
List<String> mockOtherSessions() => [
  isDesktop ? "faore's iPhone" : "faore's MacBook",
  'Element on Pixel',
];

/// The device the "new sign-in" lever pretends is asking: whichever kind
/// this one isn't.
String mockNewDevice() => isDesktop ? 'loaf on iPhone' : 'loaf on MacBook';

/// The account's recovery key: base58, 12 groups of four.
const mockRecoveryKey =
    'EsTc 5rr9 Tj3W 8ZkN oAYy 1mfA hKbu m2Cq 6ZMy F8Ws dNvf cDbu';

/// The passphrase protecting the same secret storage, made in another client.
const mockRecoveryPassphrase = 'bread before breakfast';

/// What setting up recovery (or a reset) generates.
const mockNewRecoveryKey =
    'EsU1 kP4q 9dXz Rw2m Hn7b Vt3c Yf8g Ja5s Lk6e Qx4r Zu9w Mh2p';

/// Room keys in key backup, for the restore count.
const mockBackupKeys = 3380;

const mockSasEmoji = [
  SasEmoji('🐶', 'dog'),
  SasEmoji('🍕', 'pizza'),
  SasEmoji('🚀', 'rocket'),
  SasEmoji('🔑', 'key'),
  SasEmoji('🌵', 'cactus'),
  SasEmoji('🎸', 'guitar'),
  SasEmoji('☂️', 'umbrella'),
];

/// Whether [text] opens secret storage: the recovery key however it was
/// spaced, wrapped or pasted, or the passphrase.
bool unlocksRecovery(String text) {
  final squashed = text.replaceAll(RegExp(r'\s'), '');
  return squashed == mockRecoveryKey.replaceAll(' ', '') ||
      text.trim() == mockRecoveryPassphrase;
}
```

- [ ] **Step 5: Create `lib/ui/verify/verification_controller.dart`:**

```dart
/// A verification panel's fake counterpart — mockup only. Stands in for the
/// SDK's key verification and secret storage. The steps are the ones the
/// protocol walks, played out on timers against mock/accounts.dart. See
/// "Verifying a session" in the design spec.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../auth/sign_in_controller.dart';
import '../mock/accounts.dart';
import '../platform.dart';
import 'verify_state.dart';

class VerificationController extends ChangeNotifier {
  VerificationController({
    required this.purpose,
    required this.onTrusted,
    this.otherSessions = const [],
    this.incomingDevice,
    this.reauthByPassword = false,
    this.consumeFailure = _never,
    bool? desktop,
  }) : desktop = desktop ?? isDesktop,
       _state = VerifyState(
         step: switch (purpose) {
           VerifyPurpose.verify => VerifyStep.choose,
           VerifyPurpose.setUp => VerifyStep.setUpIntro,
           VerifyPurpose.incoming => VerifyStep.incomingPrompt,
         },
       );

  /// Starts in [state] with nothing in flight, so a test can pin any step.
  @visibleForTesting
  VerificationController.at(
    VerifyState state, {
    this.purpose = VerifyPurpose.verify,
    VoidCallback? onTrusted,
    this.otherSessions = const [],
    this.incomingDevice,
    this.reauthByPassword = false,
    this.consumeFailure = _never,
    bool? desktop,
  }) : onTrusted = onTrusted ?? _nothing,
       desktop = desktop ?? isDesktop,
       _state = state;

  static bool _never() => false;
  static void _nothing() {}

  static const acceptDelay = Duration(seconds: 2);
  static const confirmDelay = Duration(milliseconds: 1200);
  static const keyCheckDelay = Duration(milliseconds: 600);
  static const restoreTick = Duration(milliseconds: 120);
  static const restorePerTick = 169;
  static const doneLinger = Duration(milliseconds: 1200);

  final VerifyPurpose purpose;

  /// Called once this device is trusted: signed by a verified identity, or
  /// owner of a new one. Never for [VerifyPurpose.incoming], which vouches
  /// for another device instead.
  final VoidCallback onTrusted;
  final List<String> otherSessions;

  /// Incoming only: the device asking to be verified.
  final String? incomingDevice;

  /// Reset's re-authentication: a password account types its password; an
  /// SSO account goes through the browser.
  final bool reauthByPassword;

  /// The debug "fail the next connection" lever.
  final bool Function() consumeFailure;
  final bool desktop;

  List<SasEmoji> get emoji => mockSasEmoji;
  String get newRecoveryKey => mockNewRecoveryKey;

  String get doneMessage => switch (purpose) {
    VerifyPurpose.verify => 'this session is verified',
    VerifyPurpose.setUp => 'recovery is set up',
    VerifyPurpose.incoming => '${incomingDevice ?? 'that device'} is verified',
  };

  VerifyState _state;
  VerifyState get state => _state;

  /// The one step-changing thing in flight; starting anything new cancels
  /// it, so a stale timer can never jump a step.
  Timer? _work;
  Timer? _restore;

  void _set(VerifyState s) {
    _state = s;
    notifyListeners();
  }

  void _go(VerifyStep step) => _set(VerifyState(step: step));

  void _after(Duration delay, VoidCallback run) {
    _work?.cancel();
    _work = Timer(delay, run);
  }

  bool get canGoBack => switch (_state.step) {
    VerifyStep.waitingForDevice ||
    VerifyStep.recoveryKey ||
    VerifyStep.resetConfirm ||
    VerifyStep.cancelled => purpose == VerifyPurpose.verify,
    VerifyStep.resetAuth => !_state.inBrowser,
    _ => false,
  };

  /// Whether closing the panel should leave this running: history keeps
  /// restoring with nobody watching.
  bool get worksUnseen => _state.step == VerifyStep.restoring;

  void back() {
    if (!canGoBack) return;
    _work?.cancel();
    _go(
      _state.step == VerifyStep.resetAuth
          ? VerifyStep.resetConfirm
          : VerifyStep.choose,
    );
  }

  void useAnotherDevice() {
    _go(VerifyStep.waitingForDevice);
    // No answer and a refusal look the same from here: nothing was trusted.
    _after(
      acceptDelay,
      () => _go(consumeFailure() ? VerifyStep.cancelled : VerifyStep.compareEmoji),
    );
  }

  void tryAgain() => useAnotherDevice();

  void useRecoveryKey() => _go(VerifyStep.recoveryKey);

  void cantDoEither() => _go(VerifyStep.resetConfirm);

  void emojiMatch() {
    if (_state.step != VerifyStep.compareEmoji) return;
    _go(VerifyStep.waitingForOther);
    _after(confirmDelay, () {
      if (purpose != VerifyPurpose.incoming) onTrusted();
      _done();
    });
  }

  void emojiMismatch() {
    if (_state.step != VerifyStep.compareEmoji) return;
    _work?.cancel();
    _go(VerifyStep.cancelled);
  }

  void submitKey(String text) {
    if (_state.step != VerifyStep.recoveryKey || _state.checking) return;
    if (text.trim().isEmpty) return;
    _set(const VerifyState(step: VerifyStep.recoveryKey, checking: true));
    _after(keyCheckDelay, () {
      if (!unlocksRecovery(text) || consumeFailure()) {
        _set(const VerifyState(step: VerifyStep.recoveryKey, rejected: true));
        return;
      }
      // Secret storage opened: the device signs itself now, and history
      // follows from key backup.
      onTrusted();
      _startRestore();
    });
  }

  void _startRestore() {
    var restored = 0;
    _set(const VerifyState(step: VerifyStep.restoring, totalKeys: mockBackupKeys));
    _restore = Timer.periodic(restoreTick, (t) {
      restored = math.min(restored + restorePerTick, mockBackupKeys);
      if (restored >= mockBackupKeys) {
        t.cancel();
        _done();
        return;
      }
      _set(VerifyState(step: VerifyStep.restoring, restored: restored, totalKeys: mockBackupKeys));
    });
  }

  void confirmReset() {
    if (_state.step != VerifyStep.resetConfirm) return;
    _go(VerifyStep.resetAuth);
  }

  void reauthWithPassword(String password) {
    if (_state.step != VerifyStep.resetAuth || _state.checking) return;
    if (password.isEmpty) return;
    _set(const VerifyState(step: VerifyStep.resetAuth, checking: true));
    _after(
      keyCheckDelay,
      () => _set(
        password == mockWrongPassword
            ? const VerifyState(step: VerifyStep.resetAuth, rejected: true)
            : const VerifyState(step: VerifyStep.showKey),
      ),
    );
  }

  void reauthWithSso() {
    if (_state.step != VerifyStep.resetAuth || _state.inBrowser || _state.checking) return;
    _set(VerifyState(step: VerifyStep.resetAuth, inBrowser: desktop, checking: !desktop));
    _after(
      desktop ? SignInController.browserDelay : SignInController.ssoSheetDelay,
      () => _go(VerifyStep.showKey),
    );
  }

  void reopenBrowser() {
    if (!_state.inBrowser) return;
    _after(SignInController.browserDelay, () => _go(VerifyStep.showKey));
  }

  void cancelBrowser() {
    _work?.cancel();
    _go(VerifyStep.resetAuth);
  }

  void createKey() {
    if (_state.step != VerifyStep.setUpIntro) return;
    _go(VerifyStep.showKey);
  }

  /// The key was copied or saved.
  void keyKept() {
    if (_state.step != VerifyStep.showKey || _state.keySaved) return;
    _set(const VerifyState(step: VerifyStep.showKey, keySaved: true));
  }

  void finishSetUp() {
    if (_state.step != VerifyStep.showKey || !_state.keySaved) return;
    onTrusted();
    _done();
  }

  void acceptIncoming() {
    if (_state.step != VerifyStep.incomingPrompt) return;
    _go(VerifyStep.compareEmoji);
  }

  void rejectIncoming() {
    if (_state.step != VerifyStep.incomingPrompt) return;
    _go(VerifyStep.notMe);
  }

  void _done() {
    _go(VerifyStep.done);
    _after(doneLinger, () => _set(const VerifyState(step: VerifyStep.done, closing: true)));
  }

  @override
  void dispose() {
    _work?.cancel();
    _restore?.cancel();
    super.dispose();
  }
}
```

- [ ] **Step 6: Run the test and watch it pass**

Run: `mise exec -- flutter test test/verification_controller_test.dart`, then `mise exec -- flutter analyze`.
Expected: PASS, with no issues.

- [ ] **Step 7: Checkpoint.** Suggested commit: `feat(ui): a fake verification that walks the protocol's steps`.

---

### Task 7: The emoji comparison and the recovery-key widgets

**Files:**
- Create: `lib/ui/verify/emoji_compare.dart`
- Create: `lib/ui/verify/recovery_key.dart`
- Test: `test/verify_widgets_test.dart`

**Interfaces:**
- Consumes: `SasEmoji` and `mockSasEmoji` (Task 6), and `LoafField` (Task 3).
- Produces:
  - `EmojiCompare({required List<SasEmoji> emoji})`.
  - `String groupKey(String)`.
  - `RecoveryKeyDisplay({required String recoveryKey})`.
  - `RecoveryKeyField({required TextEditingController controller, required VoidCallback onSubmit})`.

- [ ] **Step 1: Write the failing test** — `test/verify_widgets_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/mock/accounts.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/verify/emoji_compare.dart';
import 'package:loaf_native/ui/verify/recovery_key.dart';

Future<void> _pump(WidgetTester tester, Widget child, {double width = 390, double textScale = 1}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: loafDarkTheme(),
      home: MediaQuery(
        data: MediaQueryData(size: Size(width, 844), textScaler: TextScaler.linear(textScale)),
        child: Scaffold(body: Padding(padding: const EdgeInsets.all(20), child: child)),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('EmojiCompare', () {
    testWidgets('shows all seven with their names, four over three', (tester) async {
      await _pump(tester, const EmojiCompare(emoji: mockSasEmoji));
      for (final e in mockSasEmoji) {
        expect(find.text(e.name), findsOneWidget);
      }
      final dog = tester.getRect(find.text('dog'));
      final pizza = tester.getRect(find.text('pizza'));
      final cactus = tester.getRect(find.text('cactus'));
      expect(dog.top, pizza.top);
      expect(cactus.top, greaterThan(dog.bottom));
    });

    testWidgets('holds at large text in a narrow panel', (tester) async {
      await _pump(tester, const EmojiCompare(emoji: mockSasEmoji), width: 340, textScale: 2);
      expect(tester.takeException(), isNull);
    });
  });

  test('groupKey regroups any spacing into fours', () {
    expect(groupKey('EsTc5rr9 Tj3W\n8ZkN'), 'EsTc 5rr9 Tj3W 8ZkN');
    expect(groupKey(mockRecoveryKey), mockRecoveryKey);
  });

  testWidgets(
    'a computer can select the key',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      await _pump(tester, const RecoveryKeyDisplay(recoveryKey: mockNewRecoveryKey));
      expect(find.byType(SelectableText), findsOneWidget);
    },
  );

  testWidgets(
    'a phone shows the key as plain text',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      await _pump(tester, const RecoveryKeyDisplay(recoveryKey: mockNewRecoveryKey));
      expect(find.byType(SelectableText), findsNothing);
      expect(find.text(mockNewRecoveryKey), findsOneWidget);
    },
  );

  group('RecoveryKeyField', () {
    testWidgets('is hidden until revealed, and submits', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      var submitted = false;
      await _pump(tester, RecoveryKeyField(controller: controller, onSubmit: () => submitted = true));
      expect(tester.widget<TextField>(find.byType(TextField)).obscureText, isTrue);

      await tester.tap(find.byTooltip('show'));
      await tester.pump();
      expect(tester.widget<TextField>(find.byType(TextField)).obscureText, isFalse);

      await tester.enterText(find.byType(TextField), 'x');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      expect(submitted, isTrue);
    });

    testWidgets(
      'only a phone gets a paste button',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        await _pump(tester, RecoveryKeyField(controller: controller, onSubmit: () {}));
        expect(find.byTooltip('paste'), findsOneWidget);
      },
    );

    testWidgets(
      'a computer pastes the usual way',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        await _pump(tester, RecoveryKeyField(controller: controller, onSubmit: () {}));
        expect(find.byTooltip('paste'), findsNothing);
      },
    );
  });
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `mise exec -- flutter test test/verify_widgets_test.dart`
Expected: FAIL to compile.

- [ ] **Step 3: Create `lib/ui/verify/emoji_compare.dart`:**

```dart
/// The 7 SAS emoji as both ends draw them. The new device and the one
/// vouching for it show exactly this widget, so "do they match" compares
/// like with like.
library;

import 'package:flutter/material.dart';

import '../theme/loaf_theme.dart';
import 'verify_state.dart';

class EmojiCompare extends StatelessWidget {
  const EmojiCompare({super.key, required this.emoji});

  final List<SasEmoji> emoji;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      _row(emoji.take(4).toList(), inset: false),
      const SizedBox(height: LoafSpace.x4),
      _row(emoji.skip(4).toList(), inset: true),
    ],
  );

  /// Cells share one width across both rows (flex 2 of 8), and the row of
  /// three is inset by half a cell each side, so the second row centres
  /// under the first. Names wrap rather than overflow at large text.
  Widget _row(List<SasEmoji> cells, {required bool inset}) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (inset) const Spacer(),
      for (final e in cells) Expanded(flex: 2, child: _Cell(e)),
      if (inset) const Spacer(),
    ],
  );
}

class _Cell extends StatelessWidget {
  const _Cell(this.e);

  final SasEmoji e;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(e.emoji, style: const TextStyle(fontSize: 34)),
        const SizedBox(height: LoafSpace.x1),
        Text(
          e.name,
          textAlign: TextAlign.center,
          style: loafBody(12, 500).copyWith(color: tokens.textMuted),
        ),
      ],
    );
  }
}
```

- [ ] **Step 4: Create `lib/ui/verify/recovery_key.dart`:**

```dart
/// The recovery key on screen: shown in fours for reading and copying by
/// eye, and typed or pasted back in to unlock.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../platform.dart';
import '../theme/loaf_theme.dart';
import '../widgets/loaf_field.dart';

/// [key] regrouped into fours, whatever spacing it arrived with.
String groupKey(String key) {
  final squashed = key.replaceAll(RegExp(r'\s'), '');
  final groups = [
    for (var i = 0; i < squashed.length; i += 4)
      squashed.substring(i, (i + 4).clamp(0, squashed.length)),
  ];
  return groups.join(' ');
}

class RecoveryKeyDisplay extends StatelessWidget {
  const RecoveryKeyDisplay({super.key, required this.recoveryKey});

  final String recoveryKey;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final text = groupKey(recoveryKey);
    final style = loafMono(16, weight: FontWeight.w500).copyWith(color: tokens.textStrong, height: 1.6);
    return Container(
      padding: const EdgeInsets.all(LoafSpace.x4),
      decoration: BoxDecoration(
        color: tokens.sunken,
        borderRadius: BorderRadius.circular(LoafRadius.lg),
        border: Border.all(color: tokens.border),
      ),
      // A computer never loses text selection; the spaces between groups are
      // where it wraps.
      child: isDesktop
          ? SelectableText(text, textAlign: TextAlign.center, style: style)
          : Text(text, textAlign: TextAlign.center, style: style),
    );
  }
}

class RecoveryKeyField extends StatefulWidget {
  const RecoveryKeyField({super.key, required this.controller, required this.onSubmit});

  final TextEditingController controller;
  final VoidCallback onSubmit;

  @override
  State<RecoveryKeyField> createState() => _RecoveryKeyFieldState();
}

class _RecoveryKeyFieldState extends State<RecoveryKeyField> {
  var _hidden = true;

  /// A phone's clipboard is a long-press away and fiddly in a masked field;
  /// a computer pastes with the usual shortcut.
  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || !mounted) return;
    widget.controller.text = text;
  }

  @override
  Widget build(BuildContext context) => LoafField(
    controller: widget.controller,
    hint: 'recovery key or passphrase',
    icon: LucideIcons.keyRound,
    obscure: _hidden,
    autofocus: true,
    textInputAction: TextInputAction.done,
    onSubmit: widget.onSubmit,
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!isDesktop) _IconTap(icon: LucideIcons.clipboardPaste, tooltip: 'paste', onTap: _paste),
        _IconTap(
          icon: _hidden ? LucideIcons.eye : LucideIcons.eyeOff,
          tooltip: _hidden ? 'show' : 'hide',
          onTap: () => setState(() => _hidden = !_hidden),
        ),
      ],
    ),
  );
}

class _IconTap extends StatelessWidget {
  const _IconTap({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(LoafSpace.x1),
            child: Icon(icon, size: 17, color: tokens.textMuted),
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 5: Run the test and watch it pass**

Run: `mise exec -- flutter test test/verify_widgets_test.dart`, then `mise exec -- flutter analyze`.
Expected: PASS, with no issues.

- [ ] **Step 6: Checkpoint.** Suggested commit: `feat(ui): the emoji both ends compare, and the recovery key on screen`.

---

### Task 8: The step bodies

Every step as a pure widget taking values and callbacks. The panel host (Task 9) only picks one.

**Files:**
- Create: `lib/ui/verify/verify_steps.dart` (shared primitives, plus choose, waiting, compare, cancelled, recovery, restoring and done)
- Create: `lib/ui/verify/reset_identity.dart`
- Create: `lib/ui/verify/recovery_setup.dart`
- Create: `lib/ui/verify/incoming_verification.dart`
- Test: `test/verify_steps_test.dart`

**Interfaces:**
- Consumes: Task 7's widgets, `BrowserWait` (Task 4), `LoafField` and `ErrorNote` (Task 3).
- Produces:
  - Shared primitives: `StepLead(String)`, `StepNote(String)`, `StepIcon(IconData, {bool loud})`, `WorkingLine(String)`, `RouteTile(...)` and `String thousands(int)`.
  - `ChooseStep({required List<String> otherSessions, required VoidCallback onDevice, required VoidCallback onRecoveryKey, required VoidCallback onNeither})`.
  - `WaitingStep({required String label, VoidCallback? onCancel})`.
  - `CompareStep({required List<SasEmoji> emoji, required String prompt, required VoidCallback onMatch, required VoidCallback onMismatch})`.
  - `CancelledStep({VoidCallback? onTryAgain, required VoidCallback onClose})`.
  - `RecoveryStep({required TextEditingController controller, required bool checking, required bool rejected, required VoidCallback onSubmit})`.
  - `RestoringStep({required int restored, required int total})` and `DoneStep({required String message})`.
  - `ResetConfirmStep({required VoidCallback onReset, required VoidCallback onCancel})`.
  - `ResetAuthStep({required bool byPassword, required TextEditingController password, required bool checking, required bool rejected, required bool inBrowser, required String providerName, required VoidCallback onPassword, required VoidCallback onSso, required VoidCallback onReopen, required VoidCallback onCancelBrowser})`.
  - `SetUpIntroStep({required VoidCallback onCreate})`.
  - `ShowKeyStep({required String recoveryKey, required bool saved, required VoidCallback onCopy, required VoidCallback onSave, required VoidCallback onDone})`.
  - `IncomingPromptStep({required String device, required VoidCallback onYes, required VoidCallback onNotMe})` and `NotMeStep({required VoidCallback onClose})`.

- [ ] **Step 1: Write the failing test** — `test/verify_steps_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/mock/accounts.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/verify/incoming_verification.dart';
import 'package:loaf_native/ui/verify/recovery_setup.dart';
import 'package:loaf_native/ui/verify/reset_identity.dart';
import 'package:loaf_native/ui/verify/verify_steps.dart';
import 'package:loaf_native/ui/widgets/loaf_button.dart';

/// Steps render inside a panel about 440 wide on a computer and full width on
/// a phone; both are checked. Spinners never settle, so this pumps a fixed
/// time.
Future<void> _pump(WidgetTester tester, Widget step, {double width = 390}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: loafDarkTheme(),
      home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(20), child: step)),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

void _noop() {}

void main() {
  final key = TextEditingController();
  final password = TextEditingController();
  tearDownAll(() {
    key.dispose();
    password.dispose();
  });

  final steps = <String, Widget>{
    'choose': const ChooseStep(otherSessions: ["faore's MacBook", 'Element on Pixel'], onDevice: _noop, onRecoveryKey: _noop, onNeither: _noop),
    'waiting': const WaitingStep(label: 'waiting for the other device to confirm', onCancel: _noop),
    'compare': const CompareStep(emoji: mockSasEmoji, prompt: 'do these match?', onMatch: _noop, onMismatch: _noop),
    'cancelled': const CancelledStep(onTryAgain: _noop, onClose: _noop),
    'recovery': RecoveryStep(controller: key, checking: false, rejected: true, onSubmit: _noop),
    'restoring': const RestoringStep(restored: 1204, total: 3380),
    'done': const DoneStep(message: 'this session is verified'),
    'reset confirm': const ResetConfirmStep(onReset: _noop, onCancel: _noop),
    'reset password': ResetAuthStep(byPassword: true, password: password, checking: false, rejected: true, inBrowser: false, providerName: 'loaf.moe', onPassword: _noop, onSso: _noop, onReopen: _noop, onCancelBrowser: _noop),
    'reset browser': ResetAuthStep(byPassword: false, password: password, checking: false, rejected: false, inBrowser: true, providerName: 'loaf.moe', onPassword: _noop, onSso: _noop, onReopen: _noop, onCancelBrowser: _noop),
    'set up intro': const SetUpIntroStep(onCreate: _noop),
    'show key': const ShowKeyStep(recoveryKey: mockNewRecoveryKey, saved: false, onCopy: _noop, onSave: _noop, onDone: _noop),
    'incoming': const IncomingPromptStep(device: 'loaf on iPhone', onYes: _noop, onNotMe: _noop),
    'not me': const NotMeStep(onClose: _noop),
  };
  for (final MapEntry(key: name, value: step) in steps.entries) {
    for (final width in [390.0, 440.0]) {
      testWidgets('$name lays out at ${width.toInt()} wide', (tester) async {
        await _pump(tester, step, width: width);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('the device route is offered only when there is a device to ask', (tester) async {
    await _pump(tester, const ChooseStep(otherSessions: [], onDevice: _noop, onRecoveryKey: _noop, onNeither: _noop));
    expect(find.text('use another device'), findsNothing);
    expect(find.text('use your recovery key'), findsOneWidget);
  });

  testWidgets('other sessions are listed under the device route', (tester) async {
    await _pump(tester, steps['choose']!);
    expect(find.text("faore's MacBook · Element on Pixel"), findsOneWidget);
  });

  testWidgets("i've saved it waits for a copy or a save", (tester) async {
    await _pump(tester, steps['show key']!);
    expect(tester.widget<LoafButton>(find.widgetWithText(LoafButton, "i've saved it")).onTap, isNull);

    await _pump(tester, const ShowKeyStep(recoveryKey: mockNewRecoveryKey, saved: true, onCopy: _noop, onSave: _noop, onDone: _noop));
    expect(tester.widget<LoafButton>(find.widgetWithText(LoafButton, "i've saved it")).onTap, isNotNull);
  });

  testWidgets('restoring counts with thousands separators', (tester) async {
    await _pump(tester, steps['restoring']!);
    expect(find.text('restored 1,204 of 3,380 keys'), findsOneWidget);
  });

  testWidgets('reset spends the accent on its destructive button', (tester) async {
    await _pump(tester, steps['reset confirm']!);
    final reset = tester.widget<LoafButton>(find.widgetWithText(LoafButton, 'reset my identity'));
    expect(reset.emphasis, LoafButtonEmphasis.filled);
  });

  testWidgets('a wrong key says so', (tester) async {
    await _pump(tester, steps['recovery']!);
    expect(find.text("that didn't unlock anything"), findsOneWidget);
  });

  test('thousands', () {
    expect(thousands(0), '0');
    expect(thousands(999), '999');
    expect(thousands(1204), '1,204');
    expect(thousands(1234567), '1,234,567');
  });
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `mise exec -- flutter test test/verify_steps_test.dart`
Expected: FAIL to compile.

- [ ] **Step 3: Create `lib/ui/verify/verify_steps.dart`:**

```dart
/// The verify panel's steps, as pure widgets: values in, callbacks out. The
/// panel host picks one from the controller's state. Also the small pieces
/// every step file shares.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/loaf_theme.dart';
import '../widgets/error_note.dart';
import '../widgets/loaf_button.dart';
import 'emoji_compare.dart';
import 'recovery_key.dart';
import 'verify_state.dart';

// ── Shared pieces ─────────────────────────────────────────────────────────

class StepLead extends StatelessWidget {
  const StepLead(this.text, {super.key, this.center = false});

  final String text;
  final bool center;

  @override
  Widget build(BuildContext context) => Text(
    text,
    textAlign: center ? TextAlign.center : TextAlign.start,
    style: loafBody(15, 500).copyWith(color: LoafTokens.of(context).textBody),
  );
}

class StepNote extends StatelessWidget {
  const StepNote(this.text, {super.key, this.center = false});

  final String text;
  final bool center;

  @override
  Widget build(BuildContext context) => Text(
    text,
    textAlign: center ? TextAlign.center : TextAlign.start,
    style: loafBody(13, 400).copyWith(color: LoafTokens.of(context).textMuted),
  );
}

class StepIcon extends StatelessWidget {
  const StepIcon(this.icon, {super.key, this.loud = false});

  final IconData icon;

  /// Spends the accent: for what leaves you worse off if ignored.
  final bool loud;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Center(child: Icon(icon, size: 32, color: loud ? tokens.accent : tokens.textMuted));
  }
}

class WorkingLine extends StatelessWidget {
  const WorkingLine(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 15,
          height: 15,
          child: CircularProgressIndicator(strokeWidth: 2, color: tokens.accent),
        ),
        const SizedBox(width: LoafSpace.x3),
        Flexible(
          child: Text(label, textAlign: TextAlign.center, style: loafBody(14, 400).copyWith(color: tokens.textMuted)),
        ),
      ],
    );
  }
}

/// One way to verify: a card you pick.
class RouteTile extends StatelessWidget {
  const RouteTile({super.key, required this.icon, required this.title, this.subtitle, required this.onTap});

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final subtitle = this.subtitle;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(LoafSpace.x3),
          decoration: BoxDecoration(
            color: tokens.sunken,
            borderRadius: BorderRadius.circular(LoafRadius.lg),
            border: Border.all(color: tokens.border),
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: tokens.textMuted),
              const SizedBox(width: LoafSpace.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: loafBody(15, 600).copyWith(color: tokens.textStrong)),
                    if (subtitle != null)
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: loafBody(13, 400).copyWith(color: tokens.textMuted),
                      ),
                  ],
                ),
              ),
              Icon(LucideIcons.chevronRight, size: 16, color: tokens.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

/// 3380 → "3,380".
String thousands(int n) {
  final s = n.toString();
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}

// ── Steps ─────────────────────────────────────────────────────────────────

class ChooseStep extends StatelessWidget {
  const ChooseStep({super.key, required this.otherSessions, required this.onDevice, required this.onRecoveryKey, required this.onNeither});

  final List<String> otherSessions;
  final VoidCallback onDevice;
  final VoidCallback onRecoveryKey;
  final VoidCallback onNeither;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const StepLead("prove it's you so this device can read your encrypted history."),
      const SizedBox(height: LoafSpace.x4),
      // Offered only where it leads somewhere, like the password link: with
      // no other session to ask, the request would wait forever.
      if (otherSessions.isNotEmpty) ...[
        RouteTile(
          icon: LucideIcons.monitorSmartphone,
          title: 'use another device',
          subtitle: otherSessions.join(' · '),
          onTap: onDevice,
        ),
        const SizedBox(height: LoafSpace.x2),
      ],
      RouteTile(
        icon: LucideIcons.keyRound,
        title: 'use your recovery key',
        subtitle: 'or its passphrase',
        onTap: onRecoveryKey,
      ),
      const SizedBox(height: LoafSpace.x4),
      LoafButton(
        label: "can't do either?",
        onTap: onNeither,
        emphasis: LoafButtonEmphasis.quiet,
        size: LoafButtonSize.small,
      ),
    ],
  );
}

class WaitingStep extends StatelessWidget {
  const WaitingStep({super.key, required this.label, this.onCancel});

  final String label;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: LoafSpace.x4),
      WorkingLine(label),
      if (onCancel != null) ...[
        const SizedBox(height: LoafSpace.x5),
        LoafButton(label: 'cancel', onTap: onCancel, emphasis: LoafButtonEmphasis.quiet, size: LoafButtonSize.small),
      ],
    ],
  );
}

class CompareStep extends StatelessWidget {
  const CompareStep({super.key, required this.emoji, required this.prompt, required this.onMatch, required this.onMismatch});

  final List<SasEmoji> emoji;
  final String prompt;
  final VoidCallback onMatch;
  final VoidCallback onMismatch;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      StepLead(prompt, center: true),
      const SizedBox(height: LoafSpace.x5),
      EmojiCompare(emoji: emoji),
      const SizedBox(height: LoafSpace.x6),
      LoafButton(label: 'they match', onTap: onMatch),
      const SizedBox(height: LoafSpace.x2),
      LoafButton(label: "they don't match", onTap: onMismatch, emphasis: LoafButtonEmphasis.quiet, size: LoafButtonSize.small),
    ],
  );
}

class CancelledStep extends StatelessWidget {
  const CancelledStep({super.key, this.onTryAgain, required this.onClose});

  final VoidCallback? onTryAgain;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const StepIcon(LucideIcons.triangleAlert),
      const SizedBox(height: LoafSpace.x3),
      const StepLead('nothing was trusted — the request was cancelled.', center: true),
      const SizedBox(height: LoafSpace.x5),
      if (onTryAgain != null) ...[
        LoafButton(label: 'try again', icon: LucideIcons.rotateCcw, emphasis: LoafButtonEmphasis.outlined, onTap: onTryAgain),
        const SizedBox(height: LoafSpace.x2),
      ],
      LoafButton(label: 'close', onTap: onClose, emphasis: LoafButtonEmphasis.quiet, size: LoafButtonSize.small),
    ],
  );
}

class RecoveryStep extends StatelessWidget {
  const RecoveryStep({super.key, required this.controller, required this.checking, required this.rejected, required this.onSubmit});

  final TextEditingController controller;
  final bool checking;
  final bool rejected;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const StepLead('enter your recovery key, or the passphrase that protects it.'),
      const SizedBox(height: LoafSpace.x4),
      RecoveryKeyField(controller: controller, onSubmit: onSubmit),
      if (rejected) ...[
        const SizedBox(height: LoafSpace.x3),
        const ErrorNote(message: "that didn't unlock anything"),
      ],
      const SizedBox(height: LoafSpace.x4),
      LoafButton(label: checking ? 'checking…' : 'unlock', onTap: checking ? null : onSubmit),
    ],
  );
}

class RestoringStep extends StatelessWidget {
  const RestoringStep({super.key, required this.restored, required this.total});

  final int restored;
  final int total;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const StepLead('restoring history'),
        const SizedBox(height: LoafSpace.x2),
        StepNote('restored ${thousands(restored)} of ${thousands(total)} keys'),
        const SizedBox(height: LoafSpace.x3),
        ClipRRect(
          borderRadius: BorderRadius.circular(LoafRadius.full),
          child: LinearProgressIndicator(
            value: total == 0 ? null : restored / total,
            minHeight: 6,
            color: tokens.accent,
            backgroundColor: tokens.sunken,
          ),
        ),
        const SizedBox(height: LoafSpace.x3),
        const StepNote('you can close this — it carries on.'),
      ],
    );
  }
}

class DoneStep extends StatelessWidget {
  const DoneStep({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: LoafSpace.x4),
        Icon(LucideIcons.circleCheckBig, size: 40, color: tokens.online),
        const SizedBox(height: LoafSpace.x3),
        Text(message, textAlign: TextAlign.center, style: loafBody(17, 600).copyWith(color: tokens.textStrong)),
        const SizedBox(height: LoafSpace.x4),
      ],
    );
  }
}
```

- [ ] **Step 4: Create `lib/ui/verify/reset_identity.dart`:**

```dart
/// Starting over: new cross-signing keys when every device and the recovery
/// key are gone. Explains its cost first, then re-authenticates.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/browser_wait.dart';
import '../theme/loaf_theme.dart';
import '../widgets/error_note.dart';
import '../widgets/loaf_button.dart';
import '../widgets/loaf_field.dart';
import 'verify_steps.dart';

class ResetConfirmStep extends StatelessWidget {
  const ResetConfirmStep({super.key, required this.onReset, required this.onCancel});

  final VoidCallback onReset;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const StepLead("if you've lost every device and your recovery key, you can start over with a new identity."),
      const SizedBox(height: LoafSpace.x3),
      const _Cost('people you talk to will see that your identity changed'),
      const SizedBox(height: LoafSpace.x2),
      const _Cost("encrypted history you can't reach now stays unreadable"),
      const SizedBox(height: LoafSpace.x5),
      // The filled button is the accent: this is its honest use.
      LoafButton(label: 'reset my identity', onTap: onReset),
      const SizedBox(height: LoafSpace.x2),
      LoafButton(label: 'cancel', onTap: onCancel, emphasis: LoafButtonEmphasis.quiet, size: LoafButtonSize.small),
    ],
  );
}

class _Cost extends StatelessWidget {
  const _Cost(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(LucideIcons.triangleAlert, size: 14, color: tokens.textMuted),
        ),
        const SizedBox(width: LoafSpace.x2),
        Expanded(child: Text(text, style: loafBody(14, 400).copyWith(color: tokens.textBody))),
      ],
    );
  }
}

class ResetAuthStep extends StatelessWidget {
  const ResetAuthStep({
    super.key,
    required this.byPassword,
    required this.password,
    required this.checking,
    required this.rejected,
    required this.inBrowser,
    required this.providerName,
    required this.onPassword,
    required this.onSso,
    required this.onReopen,
    required this.onCancelBrowser,
  });

  final bool byPassword;
  final TextEditingController password;
  final bool checking;
  final bool rejected;
  final bool inBrowser;
  final String providerName;
  final VoidCallback onPassword;
  final VoidCallback onSso;
  final VoidCallback onReopen;
  final VoidCallback onCancelBrowser;

  @override
  Widget build(BuildContext context) {
    if (inBrowser) {
      return BrowserWait(name: providerName, onReopen: onReopen, onCancel: onCancelBrowser);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const StepLead("confirm it's you before the old identity goes."),
        const SizedBox(height: LoafSpace.x4),
        if (byPassword) ...[
          LoafField(
            controller: password,
            hint: 'password',
            icon: LucideIcons.keyRound,
            obscure: true,
            autofocus: true,
            autofillHints: const [AutofillHints.password],
            textInputAction: TextInputAction.done,
            onSubmit: onPassword,
          ),
          if (rejected) ...[
            const SizedBox(height: LoafSpace.x3),
            const ErrorNote(message: "that password didn't match"),
          ],
          const SizedBox(height: LoafSpace.x3),
          LoafButton(label: checking ? 'checking…' : 'continue', onTap: checking ? null : onPassword),
        ] else if (checking)
          const WorkingLine('signing in…')
        else
          LoafButton(label: 'continue with $providerName', icon: LucideIcons.logIn, onTap: onSso),
      ],
    );
  }
}
```

- [ ] **Step 5: Create `lib/ui/verify/recovery_setup.dart`:**

```dart
/// A fresh identity's recovery key: made, shown once, and kept before the
/// flow will finish, since losing it is the one mistake nothing recovers.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/loaf_theme.dart';
import '../widgets/loaf_button.dart';
import 'recovery_key.dart';
import 'verify_steps.dart';

class SetUpIntroStep extends StatelessWidget {
  const SetUpIntroStep({super.key, required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const StepIcon(LucideIcons.keyRound),
      const SizedBox(height: LoafSpace.x3),
      const StepLead('if you ever lose every device, your recovery key is how you get your encrypted history back.'),
      const SizedBox(height: LoafSpace.x2),
      const StepNote("keep it somewhere safe that isn't this device — a password manager is ideal."),
      const SizedBox(height: LoafSpace.x5),
      LoafButton(label: 'create my recovery key', onTap: onCreate),
    ],
  );
}

class ShowKeyStep extends StatelessWidget {
  const ShowKeyStep({super.key, required this.recoveryKey, required this.saved, required this.onCopy, required this.onSave, required this.onDone});

  final String recoveryKey;

  /// Copied or saved at least once.
  final bool saved;
  final VoidCallback onCopy;
  final VoidCallback onSave;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const StepLead("this is your recovery key. save it now — loaf can't show it again."),
      const SizedBox(height: LoafSpace.x4),
      RecoveryKeyDisplay(recoveryKey: recoveryKey),
      const SizedBox(height: LoafSpace.x3),
      Row(
        children: [
          Expanded(
            child: LoafButton(label: 'copy', icon: LucideIcons.copy, emphasis: LoafButtonEmphasis.outlined, size: LoafButtonSize.small, onTap: onCopy),
          ),
          const SizedBox(width: LoafSpace.x2),
          Expanded(
            child: LoafButton(label: 'save as file', icon: LucideIcons.download, emphasis: LoafButtonEmphasis.outlined, size: LoafButtonSize.small, onTap: onSave),
          ),
        ],
      ),
      const SizedBox(height: LoafSpace.x5),
      LoafButton(label: "i've saved it", onTap: saved ? onDone : null),
      if (!saved) ...[
        const SizedBox(height: LoafSpace.x2),
        const StepNote('copy or save it first', center: true),
      ],
    ],
  );
}
```

- [ ] **Step 6: Create `lib/ui/verify/incoming_verification.dart`:**

```dart
/// The other end: a verified device asked to vouch for a new sign-in.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/loaf_theme.dart';
import '../widgets/loaf_button.dart';
import 'verify_steps.dart';

class IncomingPromptStep extends StatelessWidget {
  const IncomingPromptStep({super.key, required this.device, required this.onYes, required this.onNotMe});

  final String device;
  final VoidCallback onYes;
  final VoidCallback onNotMe;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const StepIcon(LucideIcons.monitorSmartphone),
      const SizedBox(height: LoafSpace.x3),
      const StepLead('is this you?', center: true),
      const SizedBox(height: LoafSpace.x1),
      // The request carries no location, so none is pretended.
      StepNote('$device · signed in just now', center: true),
      const SizedBox(height: LoafSpace.x5),
      LoafButton(label: 'yes, verify it', onTap: onYes),
      const SizedBox(height: LoafSpace.x2),
      LoafButton(label: "that's not me", onTap: onNotMe, emphasis: LoafButtonEmphasis.quiet, size: LoafButtonSize.small),
    ],
  );
}

class NotMeStep extends StatelessWidget {
  const NotMeStep({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const StepIcon(LucideIcons.shieldAlert, loud: true),
      const SizedBox(height: LoafSpace.x3),
      const StepLead('nothing was trusted — the request was cancelled.', center: true),
      const SizedBox(height: LoafSpace.x2),
      const StepNote('someone may have your password. sign that device out in settings.', center: true),
      const SizedBox(height: LoafSpace.x5),
      LoafButton(label: 'close', emphasis: LoafButtonEmphasis.outlined, onTap: onClose),
    ],
  );
}
```

- [ ] **Step 7: Run the test and watch it pass**

Run: `mise exec -- flutter test test/verify_steps_test.dart`, then `mise exec -- flutter analyze`.
Expected: PASS, with no issues.

- [ ] **Step 8: Checkpoint.** Suggested commit: `feat(ui): every verification step as a widget`.

---

### Task 9: The verify panel, opened from the rail notice

**Files:**
- Create: `lib/ui/verify/verify_panel.dart`
- Modify: `lib/ui/shell/app_shell.dart`
- Test: `test/verify_panel_test.dart`, and add to `test/session_root_test.dart`

**Interfaces:**
- Consumes: Tasks 5–8.
- Produces:
  - `Future<bool?> showVerifyPanel(BuildContext, VerificationController)`. It completes `true` when the flow finished and closed itself, and `null` if the panel was put away early.
  - `AppShell._openVerification(VerifyPurpose, {String? device})`. Tasks 10 and 11 reuse it.

- [ ] **Step 1: Write the failing tests** — `test/verify_panel_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/mock/accounts.dart';
import 'package:loaf_native/ui/mock/mock_session.dart';
import 'package:loaf_native/ui/shell/app_shell.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/verify/verification_controller.dart';

const _wide = Size(1440, 900);
const _route = Duration(milliseconds: 400);

Future<MockSession> _pumpShell(WidgetTester tester) async {
  tester.view.physicalSize = _wide;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final s = MockSession();
  await tester.pumpWidget(
    MaterialApp(theme: loafLightTheme(), darkTheme: loafDarkTheme(), themeMode: ThemeMode.dark, home: AppShell(session: s)),
  );
  await tester.pumpAndSettle();
  return s;
}

/// Tile, then the notice's own verify button, then the panel.
Future<void> _openVerify(WidgetTester tester) async {
  await tester.tap(find.byTooltip('verify this session'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('verify'));
  await tester.pump(_route);
}

void main() {
  testWidgets('the notice opens the panel on its choice', (tester) async {
    await _pumpShell(tester);
    await _openVerify(tester);
    expect(find.text('use another device'), findsOneWidget);
    expect(find.text('use your recovery key'), findsOneWidget);
  });

  testWidgets('a recovery key verifies, restores, closes, and the notice goes', (tester) async {
    final s = await _pumpShell(tester);
    await _openVerify(tester);
    await tester.tap(find.text('use your recovery key'));
    await tester.pump(_route);
    expect(find.byTooltip('back'), findsOneWidget);

    await tester.enterText(find.byType(TextField), mockRecoveryKey);
    await tester.tap(find.text('unlock'));
    await tester.pump(VerificationController.keyCheckDelay);
    expect(s.trust, DeviceTrust.verified);
    expect(find.byTooltip('verify this session'), findsNothing);
    expect(find.text('restoring history'), findsOneWidget);

    await tester.pump(VerificationController.restoreTick * 21);
    expect(find.text('this session is verified'), findsWidgets);
    await tester.pump(VerificationController.doneLinger);
    await tester.pumpAndSettle();
    expect(find.text('restoring history'), findsNothing);
  });

  testWidgets('emoji: match on both screens, then done', (tester) async {
    final s = await _pumpShell(tester);
    await _openVerify(tester);
    await tester.tap(find.text('use another device'));
    await tester.pump(VerificationController.acceptDelay);
    expect(find.text('dog'), findsOneWidget);
    await tester.tap(find.text('they match'));
    await tester.pump(VerificationController.confirmDelay);
    expect(s.trust, DeviceTrust.verified);
    await tester.pump(VerificationController.doneLinger);
    await tester.pumpAndSettle();
  });

  testWidgets(
    'Escape puts the panel away on a computer',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      await _pumpShell(tester);
      await _openVerify(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('use your recovery key'), findsNothing);
    },
  );

  testWidgets(
    'putting it away mid-wait trusts nothing and leaves the notice',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      final s = await _pumpShell(tester);
      await _openVerify(tester);
      await tester.tap(find.text('use another device'));
      await tester.pump(_route);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(_route);
      await tester.pump(VerificationController.acceptDelay);
      expect(tester.takeException(), isNull);
      expect(s.trust, DeviceTrust.unverified);
      expect(find.byTooltip('verify this session'), findsOneWidget);

      // Opening again starts over rather than resuming a stale wait.
      await _openVerify(tester);
      expect(find.text('use another device'), findsOneWidget);
    },
  );
}
```

Append to `test/session_root_test.dart`, adding the imports `package:loaf_native/ui/verify/verification_controller.dart` and `package:loaf_native/ui/mock/accounts.dart`:

```dart
  testWidgets('signing out with the panel open takes the panel too', (tester) async {
    final s = await _pumpRoot(tester);
    await tester.tap(find.byTooltip('verify this session'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('verify'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('use your recovery key'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(find.byType(TextField), mockRecoveryKey);
    await tester.tap(find.text('unlock'));
    await tester.pump(VerificationController.keyCheckDelay);

    s.signOut();
    await tester.pump();
    await tester.pump(SignInController.probeDelay);
    expect(tester.takeException(), isNull);
    expect(find.text('restoring history'), findsNothing);
    expect(find.text('continue with loaf.moe'), findsOneWidget);
  });
```

- [ ] **Step 2: Run them and watch them fail**

Run: `mise exec -- flutter test test/verify_panel_test.dart test/session_root_test.dart`
Expected: FAIL. Tapping `verify` does nothing, because `onAction` is still a no-op.

- [ ] **Step 3: Create `lib/ui/verify/verify_panel.dart`:**

```dart
/// The panel every verification flow runs in: a sheet on a phone, a dialog
/// on a computer. It draws the controller's current step, offers back where
/// the step allows it, and closes itself once done has been read.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../mock/accounts.dart';
import '../platform.dart';
import '../theme/loaf_theme.dart';
import '../widgets/adaptive_panel.dart';
import '../widgets/toast.dart';
import 'incoming_verification.dart';
import 'recovery_setup.dart';
import 'reset_identity.dart';
import 'verification_controller.dart';
import 'verify_state.dart';
import 'verify_steps.dart';

/// Completes with true once the flow finished and closed itself, or null if
/// it was put away early.
Future<bool?> showVerifyPanel(BuildContext context, VerificationController controller) =>
    showAdaptivePanel<bool>(context, child: VerifyPanel(controller: controller));

class VerifyPanel extends StatefulWidget {
  const VerifyPanel({super.key, required this.controller});

  final VerificationController controller;

  @override
  State<VerifyPanel> createState() => _VerifyPanelState();
}

class _VerifyPanelState extends State<VerifyPanel> {
  final _key = TextEditingController();
  final _password = TextEditingController();
  var _popped = false;

  VerificationController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onChange);
  }

  void _onChange() {
    if (_c.state.closing && !_popped) {
      _popped = true;
      Navigator.of(context).pop(true);
    }
  }

  @override
  void dispose() {
    _c.removeListener(_onChange);
    _key.dispose();
    _password.dispose();
    super.dispose();
  }

  void _close() => Navigator.of(context).pop();

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _c.newRecoveryKey));
    if (!mounted) return;
    showToast(context, 'copied');
    _c.keyKept();
  }

  void _save() {
    // Mockup: a save dialog on a computer, the share sheet on a phone.
    showToast(context, isDesktop ? 'saved' : 'shared');
    _c.keyKept();
  }

  String _title(VerifyStep step) {
    final incoming = _c.purpose == VerifyPurpose.incoming;
    return switch (step) {
      VerifyStep.choose => 'verify this session',
      VerifyStep.incomingPrompt || VerifyStep.notMe => 'new sign-in',
      VerifyStep.waitingForDevice ||
      VerifyStep.compareEmoji ||
      VerifyStep.waitingForOther ||
      VerifyStep.cancelled => incoming ? 'new sign-in' : 'use another device',
      VerifyStep.recoveryKey || VerifyStep.restoring => 'use your recovery key',
      VerifyStep.resetConfirm || VerifyStep.resetAuth => 'reset your identity',
      VerifyStep.setUpIntro || VerifyStep.showKey =>
        _c.purpose == VerifyPurpose.setUp ? 'set up recovery' : 'save your new recovery key',
      VerifyStep.done => '',
    };
  }

  Widget _body(VerifyState s) => switch (s.step) {
    VerifyStep.choose => ChooseStep(
      otherSessions: _c.otherSessions,
      onDevice: _c.useAnotherDevice,
      onRecoveryKey: _c.useRecoveryKey,
      onNeither: _c.cantDoEither,
    ),
    VerifyStep.waitingForDevice => WaitingStep(
      label: "accept the request on another device where you're signed in",
      onCancel: _c.back,
    ),
    VerifyStep.incomingPrompt => IncomingPromptStep(
      device: _c.incomingDevice ?? 'a device',
      onYes: _c.acceptIncoming,
      onNotMe: _c.rejectIncoming,
    ),
    VerifyStep.compareEmoji => CompareStep(
      emoji: _c.emoji,
      prompt: _c.purpose == VerifyPurpose.incoming
          ? "do these match what's on the new device?"
          : "do these match what's on your other device?",
      onMatch: _c.emojiMatch,
      onMismatch: _c.emojiMismatch,
    ),
    VerifyStep.waitingForOther => const WaitingStep(label: 'waiting for the other device to confirm'),
    VerifyStep.cancelled => CancelledStep(
      onTryAgain: _c.purpose == VerifyPurpose.verify ? _c.tryAgain : null,
      onClose: _close,
    ),
    VerifyStep.notMe => NotMeStep(onClose: _close),
    VerifyStep.recoveryKey => RecoveryStep(
      controller: _key,
      checking: s.checking,
      rejected: s.rejected,
      onSubmit: () => _c.submitKey(_key.text),
    ),
    VerifyStep.restoring => RestoringStep(restored: s.restored, total: s.totalKeys),
    VerifyStep.resetConfirm => ResetConfirmStep(onReset: _c.confirmReset, onCancel: _c.back),
    VerifyStep.resetAuth => ResetAuthStep(
      byPassword: _c.reauthByPassword,
      password: _password,
      checking: s.checking,
      rejected: s.rejected,
      inBrowser: s.inBrowser,
      providerName: loafMoeProvider.name,
      onPassword: () => _c.reauthWithPassword(_password.text),
      onSso: _c.reauthWithSso,
      onReopen: _c.reopenBrowser,
      onCancelBrowser: _c.cancelBrowser,
    ),
    VerifyStep.setUpIntro => SetUpIntroStep(onCreate: _c.createKey),
    VerifyStep.showKey => ShowKeyStep(
      recoveryKey: _c.newRecoveryKey,
      saved: s.keySaved,
      onCopy: _copy,
      onSave: _save,
      onDone: _c.finishSetUp,
    ),
    VerifyStep.done => DoneStep(message: _c.doneMessage),
  };

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final s = _c.state;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(LoafSpace.x3, isDesktop ? LoafSpace.x4 : 0, LoafSpace.x5, LoafSpace.x3),
              child: Row(
                children: [
                  if (_c.canGoBack)
                    Tooltip(
                      message: 'back',
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _c.back,
                          child: Padding(
                            padding: const EdgeInsets.all(LoafSpace.x1),
                            child: Icon(LucideIcons.chevronLeft, size: 20, color: tokens.textMuted),
                          ),
                        ),
                      ),
                    )
                  else
                    const SizedBox(width: LoafSpace.x2),
                  const SizedBox(width: LoafSpace.x1),
                  Expanded(
                    child: Text(
                      _title(s.step),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: loafBody(17, 600).copyWith(color: tokens.textStrong),
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(LoafSpace.x5, 0, LoafSpace.x5, LoafSpace.x5),
                child: _body(s),
              ),
            ),
          ],
        );
      },
    );
  }
}
```

- [ ] **Step 4: Open it from the shell** (`lib/ui/shell/app_shell.dart`):
  - Import `'../mock/accounts.dart'`, `'../verify/verification_controller.dart'`, `'../verify/verify_panel.dart'`, `'../verify/verify_state.dart'` and `'../widgets/toast.dart'`. Skip any that are already imported.
  - Add this to the state:

```dart
  /// The verification flow in hand, kept only while it works unseen (history
  /// restoring after the panel was put away).
  VerificationController? _verification;

  Future<void> _openVerification(VerifyPurpose purpose, {String? device}) async {
    final kept = _verification;
    final VerificationController v;
    if (kept != null && kept.purpose == purpose) {
      v = kept;
    } else {
      kept?.dispose();
      v = VerificationController(
        purpose: purpose,
        otherSessions: mockOtherSessions(),
        incomingDevice: device,
        consumeFailure: _session.consumeFailure,
        onTrusted: _session.markVerified,
      );
    }
    _verification = v;
    final finished = await showVerifyPanel(context, v);
    if (!mounted) return;
    if (finished == true) showToast(context, v.doneMessage);
    // A flow put away mid-restore carries on; any other starts over next
    // time, rather than resuming a stale wait.
    if (!v.worksUnseen && identical(_verification, v)) {
      _verification = null;
      v.dispose();
    }
  }
```

  - In `dispose()`, add `_verification?.dispose();`.
  - In `_notices`, wire the verify notice: `AppNotice.verify(onAction: () => _openVerification(VerifyPurpose.verify)),`.

- [ ] **Step 5: Run the tests and watch them pass**

Run: `mise exec -- flutter test test/verify_panel_test.dart test/session_root_test.dart test/app_shell_test.dart test/app_notice_test.dart`, then `mise exec -- flutter analyze`.
Expected: PASS, with no issues.

If "signing out with the panel open" fails with a disposed-notifier error, check the order in `SessionRoot._onSession`: `popUntil` must run *before* `setState(_follow)`, so the route is gone before the shell unmounts.

- [ ] **Step 6: Checkpoint.** Suggested commit: `feat(ui): the verify notice opens a panel that walks verification`.

---

### Task 10: A fresh account sets up recovery

**Files:**
- Modify: `lib/ui/shell/app_notice.dart` (`AppNotice.setUpRecovery`)
- Modify: `lib/ui/mock/mock_session.dart` (`useFreshAccount`)
- Modify: `lib/ui/shell/app_shell.dart`, `lib/ui/shell/mock_debug.dart`
- Test: `test/mock_session_test.dart`, `test/app_notice_test.dart` and `test/verify_panel_test.dart` (append to each)

**Interfaces:**
- Consumes: Task 9's `_openVerification`.
- Produces: `AppNotice.setUpRecovery({VoidCallback? onAction})`, `MockSession.useFreshAccount()` and `MockDebug.freshAccount`.

- [ ] **Step 1: Write the failing tests.**
  - Append to `test/mock_session_test.dart`:

```dart
  test('a fresh account has no identity to verify against', () {
    final s = MockSession()..useFreshAccount();
    expect(s.trust, DeviceTrust.noIdentity);
  });
```

  - Append to `test/app_notice_test.dart`, next to the existing "verification cannot be put off" test and using the same `_pumpRail` helper:

```dart
  testWidgets('setting up recovery cannot be put off', (tester) async {
    await _pumpRail(tester, [AppNotice.setUpRecovery(onAction: () {})]);
    await tester.tap(find.byTooltip('set up recovery'));
    await tester.pumpAndSettle();
    expect(find.text('later'), findsNothing);
    expect(find.text('set up'), findsOneWidget);
  });
```

  - Append to `test/verify_panel_test.dart`:

```dart
  testWidgets('a fresh account sets up recovery, and only after keeping the key', (tester) async {
    final s = await _pumpShell(tester);
    s.useFreshAccount();
    await tester.pumpAndSettle();
    expect(find.byTooltip('verify this session'), findsNothing);

    await tester.tap(find.byTooltip('set up recovery'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('set up'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('create my recovery key'));
    await tester.pumpAndSettle();
    expect(find.text(mockNewRecoveryKey), findsOneWidget);

    await tester.tap(find.text("i've saved it"));
    await tester.pump();
    expect(s.trust, DeviceTrust.noIdentity, reason: 'not before the key is kept');

    await tester.tap(find.text('copy'));
    await tester.pump();
    await tester.tap(find.text("i've saved it"));
    await tester.pump();
    expect(s.trust, DeviceTrust.verified);
    await tester.pump(VerificationController.doneLinger);
    await tester.pumpAndSettle();
    expect(find.byTooltip('set up recovery'), findsNothing);
  });
```

- [ ] **Step 2: Run them and watch them fail**

Run: `mise exec -- flutter test test/mock_session_test.dart test/app_notice_test.dart test/verify_panel_test.dart`
Expected: FAIL. `useFreshAccount` and `setUpRecovery` are undefined.

- [ ] **Step 3: Implement.**
  - In `app_notice.dart`, after `AppNotice.verify`:

```dart
  /// A fresh account has no identity yet, so nothing protects its encrypted
  /// history. No dismiss, for the same reason as [AppNotice.verify].
  factory AppNotice.setUpRecovery({VoidCallback? onAction}) => AppNotice(
    icon: LucideIcons.keyRound,
    title: 'set up recovery',
    body: 'so you never lose your encrypted messages',
    actionLabel: 'set up',
    tone: NoticeTone.attention,
    onAction: onAction,
  );
```

  - In `mock_session.dart`:

```dart
  /// Becomes an account with no cross-signing identity, as a first sign-in
  /// through Kanidm would be.
  void useFreshAccount() {
    _trust = DeviceTrust.noIdentity;
    notifyListeners();
  }
```

  - In `app_shell.dart`'s `_notices`, after the verify entry:

```dart
    if (_session.trust == DeviceTrust.noIdentity)
      AppNotice.setUpRecovery(onAction: () => _openVerification(VerifyPurpose.setUp)),
```

  - In `mock_debug.dart`, append `freshAccount,` to the enum and `item(MockDebug.freshAccount, LucideIcons.userPlus, 'become a fresh account'),` to `items`. In `app_shell.dart`'s `_debug`, add `case MockDebug.freshAccount: _session.useFreshAccount();`.

- [ ] **Step 4: Run the tests and watch them pass**

Run: `mise exec -- flutter test test/mock_session_test.dart test/app_notice_test.dart test/verify_panel_test.dart`, then `mise exec -- flutter analyze`.
Expected: PASS, with no issues.

- [ ] **Step 5: Checkpoint.** Suggested commit: `feat(ui): a fresh account sets up recovery before anything else`.

---

### Task 11: "New sign-in: is this you?"

**Files:**
- Modify: `lib/ui/mock/mock_session.dart` (`receiveRequest`, `clearIncoming`)
- Modify: `lib/ui/shell/app_shell.dart`, `lib/ui/shell/mock_debug.dart`
- Test: `test/mock_session_test.dart` and `test/verify_panel_test.dart` (append to each)

**Interfaces:**
- Consumes: `_openVerification` (Task 9) and `mockNewDevice()` (Task 6).
- Produces: `MockSession.receiveRequest()`, `MockSession.clearIncoming()` and `MockDebug.newSignIn`.

- [ ] **Step 1: Write the failing tests.**
  - Append to `test/mock_session_test.dart`:

```dart
  test('a request arrives on a trusted device and can be cleared', () {
    final s = MockSession()..receiveRequest();
    // Only a verified device is asked to vouch for another.
    expect(s.trust, DeviceTrust.verified);
    expect(s.incoming, isNotNull);
    s.clearIncoming();
    expect(s.incoming, isNull);
  });
```

  - Append to `test/verify_panel_test.dart`:

```dart
  testWidgets('a new sign-in pops up at once and uses the same emoji', (tester) async {
    final s = await _pumpShell(tester);
    s.receiveRequest();
    await tester.pump();
    await tester.pump(_route);
    expect(find.text('is this you?'), findsOneWidget);
    expect(find.textContaining('signed in just now'), findsOneWidget);

    await tester.tap(find.text('yes, verify it'));
    await tester.pump(_route);
    expect(find.text('dog'), findsOneWidget);
    await tester.tap(find.text('they match'));
    await tester.pump(VerificationController.confirmDelay);
    await tester.pump(VerificationController.doneLinger);
    await tester.pumpAndSettle();
    expect(s.incoming, isNull);
    expect(find.textContaining('is verified'), findsOneWidget, reason: 'the toast');
  });

  testWidgets("that's not me cancels and points at settings", (tester) async {
    final s = await _pumpShell(tester);
    s.receiveRequest();
    await tester.pump();
    await tester.pump(_route);
    await tester.tap(find.text("that's not me"));
    await tester.pump(_route);
    expect(find.textContaining('sign that device out in settings'), findsOneWidget);
    await tester.tap(find.text('close'));
    await tester.pumpAndSettle();
    expect(s.incoming, isNull);
  });
```

- [ ] **Step 2: Run them and watch them fail**

Run: `mise exec -- flutter test test/mock_session_test.dart test/verify_panel_test.dart`
Expected: FAIL. `receiveRequest` is undefined.

- [ ] **Step 3: Implement.**
  - In `mock_session.dart`, import `'accounts.dart'` and add:

```dart
  /// Another of your devices asks this one to vouch for it. Only a verified
  /// device is asked, so this one becomes one.
  void receiveRequest() {
    _trust = DeviceTrust.verified;
    _incoming = IncomingRequest(device: mockNewDevice(), at: DateTime.now());
    notifyListeners();
  }

  /// Answered, refused or put away. Put away means ignored: the request
  /// times out on its own, as the protocol specifies.
  void clearIncoming() {
    if (_incoming == null) return;
    _incoming = null;
    notifyListeners();
  }
```

  - In `app_shell.dart`:
    - Change `_session.addListener(_onChange)` and `removeListener(_onChange)` to use `_onSessionChange`.
    - In `_openVerification`, just after `final finished = await showVerifyPanel(context, v);`, add `if (purpose == VerifyPurpose.incoming) _session.clearIncoming();`. It goes *before* the `mounted` check, because the session outlives the shell.
    - Change the `onTrusted` argument to `purpose == VerifyPurpose.incoming ? () {} : _session.markVerified`.
    - Add:

```dart
  IncomingRequest? _shownRequest;

  void _onSessionChange() {
    setState(() {});
    final request = _session.incoming;
    if (request == null || identical(request, _shownRequest)) return;
    _shownRequest = request;
    // Straight away rather than as a notice: it is time-bound, and you
    // usually asked for it on the other device seconds ago.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _openVerification(VerifyPurpose.incoming, device: request.device);
      }
    });
  }
```

  - In `mock_debug.dart`, append `newSignIn,` to the enum and `item(MockDebug.newSignIn, LucideIcons.monitorSmartphone, 'a new sign-in asks to verify'),` to `items`. In `_debug`, add `case MockDebug.newSignIn: _session.receiveRequest();`.

- [ ] **Step 4: Run the whole suite**

Run: `mise exec -- flutter analyze`, then `mise exec -- flutter test`.
Expected: no analyzer issues, and every test passes. That's the ~266 existing tests plus this feature's.

- [ ] **Step 5: Checkpoint.** Suggested commit: `feat(ui): a new sign-in asks a verified device to vouch for it`.

---

### Task 12: Look at it on both platforms

No code unless a look finds a bug. If one does, fix it test-first in the task that owns the file, and re-run the suite.

- [ ] **Step 1: iOS simulator.**
  - Run `mise exec -- flutter build ios --simulator --debug`.
  - Call the iOS Simulator tool's `attach` first, then `launch` `build/ios/iphonesimulator/Runner.app` on "iPhone 17 Pro". Retry taps that land before the app is ready.
  - Walk each journey and screenshot every face:
    1. 🐞 → sign out. Look at "looking for loaf.moe", then the SSO and password link. Use the pencil to open the picker and connect to `many-doors.test` (four equal buttons), `sso-only.test`, `passwords.test`, `example.com`, `broken.test` and `nowhere.test`.
    2. On `passwords.test`, type `@faore:loaf.moe` into username and watch the server line re-point. Sign in with `wrong` three times to reach the countdown, then sign in with anything else.
    3. From the rail notice → verify → another device: emoji, match, toast. Then 🐞 → sign out → sign in → verify with the recovery key (paste button); watch the restore; close mid-restore.
    4. 🐞 → expire the session: welcome back → sign out instead → confirm.
    5. 🐞 → become a fresh account → set up recovery → copy → i've saved it.
    6. 🐞 → a new sign-in asks to verify → yes → match. Then again, with "that's not me".
    7. Verify → can't do either → reset → continue with loaf.moe → save the key.
  - Check the smallest text size too, since that's how Chris runs it.

- [ ] **Step 2: macOS app.**
  - Run `osascript -e 'tell application id "moe.loaf.native" to quit'`, then `mise exec -- flutter build macos --debug`, then `open build/macos/Build/Products/Debug/loaf_native.app`.
  - Walk the same journeys. The desktop-only things to confirm:
    - The "finish in your browser" face, including open it again and cancel.
    - Every panel as a dialog.
    - The recovery key is selectable.
    - There's no paste button.
    - Enter submits the password.
  - Typing into Flutter fields needs `request_full_control` plus `computer_batch`, because the background `app_*` tools can't type there. Escape isn't delivered by the tool, so the widget tests cover it.
  - If capture fails or the window clamps small, the Mac is asleep: ask Chris to wake it.

- [ ] **Step 3: Report.** List what was seen on each platform, with screenshots, and name any bug found along with its fix and test. Commit only if Chris asks.

---

## Self-Review Notes

- **Spec coverage.** Each part of the spec maps to a task:
  - Discovery and its three failures: Tasks 1–3.
  - Several providers, the password link, and re-pointing from a full id: Task 3.
  - SSO on phone and desktop: Tasks 2 and 4.
  - Password errors and the rate limit, autofill and Enter: Task 3.
  - Soft logout: Task 4.
  - `MockSession` and the levers: Tasks 5, 10 and 11.
  - The verify routes, back, the done toast, and reset with UIA: Tasks 6, 8 and 9.
  - Both ends sharing `EmojiCompare`: Tasks 7, 8 and 11.
  - Setting up recovery, with the gate on "i've saved it": Tasks 8 and 10.
  - The incoming prompt, and closing as ignoring: Task 11.
- **Not built, on purpose.** Settings' existing "sign out" button stays unwired: settings is later in wave 3, and the lever covers it. The 10-minute request timeout isn't simulated, because closing clears the request.
