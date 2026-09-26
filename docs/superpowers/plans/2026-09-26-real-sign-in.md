# Real Sign-in Implementation Plan (SDK phase 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sign in to a real homeserver — Kanidm SSO on loaf.moe, and password for servers and service accounts that take one — with the session kept across launches, signed out for real, and this device's trust read from the SDK.

**Architecture:** The sign-in screen's state machine (`SignInController`) stays; the three questions it asks a server move behind a `Homeserver` interface with two answers: `MockHomeserver` (today's fixtures and timers) and `MatrixHomeserver` (plain-HTTP discovery, then `Client.login`). Likewise `MockSession`'s public surface becomes a `LoafSession` interface, answered by `MockSession` or by `MatrixSession` over the app's one `Client`. `--dart-define=LOAF_BACKEND=matrix` picks the real pair; the mock stays the default until the rooms are real (phase 2). Signed in for real, the shell still shows fixture rooms. That is expected.

**Tech Stack:** Flutter 3.47.5 via `mise exec -- flutter`; `matrix` 13.0.0, `flutter_vodozemac` 0.8.1, `sqflite_common_ffi` 2.4.3, `path_provider`, `http`, `flutter_web_auth_2` 5.1.0, `url_launcher` 6.3.2; tests use the SDK's `FakeMatrixApi` and `package:http/testing.dart`'s `MockClient`.

**Spec:** `docs/superpowers/specs/2026-09-20-loaf-native-design.md` — "Stack", "Layering", "Sign-in and verification" → "Discovery" and "The sign-in screen", and "Known risks". Roadmap: `docs/superpowers/plans/2026-09-26-sdk-wiring-roadmap.md`.

**Rehearsed.** Every task below was run end to end on a scratch copy of this repo on 2026-09-26: 458 tests green (the 421 existing ones untouched), `flutter analyze` clean, `flutter build macos` and `flutter build ios --simulator` both succeed with `LOAF_BACKEND=matrix`, and the built macOS app launches, opens its database in the sandbox container and reaches the sign-in screen. If a step here disagrees with what you see, the code moved since. Stop and say so rather than improvising.

## Global Constraints

- Only files under `lib/matrix/` (and `lib/main.dart`, which picks the backend) import `package:matrix`, `flutter_vodozemac`, `flutter_web_auth_2`, `url_launcher` or `sqflite_common_ffi`. `lib/ui/` never imports `lib/matrix/`.
- The 421 tests that exist today must pass **unchanged**. They are the proof that the seams kept behaviour. Never edit an existing test to make it pass; add new tests beside them.
- Copy is lowercase and warm, and uses the accent red only through `ErrorNote`. The server line shows the name typed, never a delegated base URL.
- Split by `isDesktop` from `lib/ui/platform.dart`, never by input device.
- `lib/matrix/` tests use `test()`, not `testWidgets()`: they need real I/O (sqlite, loopback sockets), which the widget tester's fake clock stalls.
- Shell examples must work in Nushell. Run `mise exec -- flutter analyze`, `mise exec -- flutter test`, and `mise exec -- dart format lib test` before each checkpoint.
- Each task ends at a checkpoint with a suggested conventional commit. Commit only when Chris has said to for this run. Every commit body explains the why and ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Test accounts: the fake server in tests is `fakeServer.notExisting` (user `test`, any password). For Task 8, Chris signs in with his own account over SSO. A password service account is his to supply by hand; never write its password into a file.

## Review Focus

1. **Answers arriving after the question changed.** A probe, password or SSO answer that lands after the person connected elsewhere, cancelled, or left the screen must change nothing and never sign in. Pinned in Task 2 ("an answer to an old question is dropped", "sso answering after a connect elsewhere never signs in") and Task 4 ("an answer after cancel is dropped").
2. **"Set up recovery" shown to an account that has an identity.** Straight after sign-in the device keys are not loaded yet. Reading that as "no identity" would offer to create one, and doing so would reset the real one. Pinned in Task 7 ("keys not yet known never read as no identity") and by listening for `SyncStatus.finished`, which fires after keys update; `onSync` fires before.
3. **The login screen flashing on token refresh.** The SDK announces `softLoggedOut` while it refreshes a token. That must not count as signed out. Pinned in Task 7 ("a token refresh in flight does not sign out").
4. **Discovery answering for the wrong server.** `Client.getVersions` caches under one key for every server, so discovery is plain HTTP, and sign-in goes to the base URL its own name resolved to. Pinned in Task 5 ("a server never probed is not signed in to") and by the three failure-kind tests.
5. **Launching offline.** A stored session must restore signed-in with no network. This was rehearsed (`init` returns signed-in in about 10 ms; sync reports an error and retries), and is checked by hand in Task 8.

## File Map

| File | Task | Responsibility |
|---|---|---|
| `pubspec.yaml`, `macos/Runner/*.entitlements` | 1 | dependencies; outgoing network, and the loopback listener in Release |
| `lib/matrix/client_factory.dart` | 1 | opens the one `Client` over sqlite |
| `lib/ui/auth/homeserver.dart` | 2 | the `Homeserver` interface and `SignInOutcome` values |
| `lib/ui/mock/mock_homeserver.dart` | 2 | fixture answers on timers, moved out of the controller |
| `lib/ui/auth/sign_in_controller.dart` | 2 | asks a `Homeserver`; drops stale answers |
| `lib/ui/auth/sign_in_state.dart` | 2 | gains `failure` |
| `lib/ui/auth/login_page.dart` | 3 | says a `failure` |
| `lib/matrix/sso_browser.dart` | 4 | system sheet (phone) and browser plus loopback (computer) |
| `lib/matrix/matrix_homeserver.dart` | 5 | discovery, password and SSO sign-in against a real server |
| `lib/ui/auth/loaf_session.dart` | 6 | the `LoafSession` interface and its enums |
| `lib/ui/mock/mock_session.dart`, `lib/ui/auth/session_root.dart`, `lib/ui/shell/app_shell.dart` | 6 | speak `LoafSession` |
| `lib/matrix/matrix_session.dart`, `lib/main.dart` | 7 | the real session, picked by `LOAF_BACKEND` |

---

### Task 1: Dependencies, entitlements and the client factory

**Files:**
- Modify: `pubspec.yaml`, `macos/Runner/DebugProfile.entitlements`, `macos/Runner/Release.entitlements`, `docs/superpowers/specs/2026-09-20-loaf-native-design.md` (Stack table)
- Create: `lib/matrix/client_factory.dart`
- Test: `test/matrix/client_factory_test.dart`

**Interfaces:**
- Produces: `Future<Client> openClient({http.Client? httpClient, String? databasePath})`. It returns an un-`init`ed `Client` named `'loaf'`. Pass `databasePath: inMemoryDatabasePath` (from `package:sqflite_common_ffi/sqflite_ffi.dart`) in tests.

- [ ] **Step 1: Add the dependencies**

```bash
mise exec -- flutter pub add matrix:^13.0.0 flutter_vodozemac:^0.8.1 sqflite_common_ffi:^2.4.3 path_provider:^2.1.5 http:^1.6.0 flutter_web_auth_2:^5.1.0 url_launcher:^6.3.2
```

Expected: `matrix 13.0.0` and the rest resolve. `pubspec.lock` and `macos/Flutter/GeneratedPluginRegistrant.swift` change; that is expected. `flutter_web_auth_2` brings `desktop_webview_window` on macOS, which prints Swift deprecation warnings at build time. Those are harmless.

- [ ] **Step 2: Let the macOS app reach the network**

The sandbox blocks outgoing connections without `network.client`. The desktop SSO listener needs `network.server`, which Release lacks today. In `macos/Runner/DebugProfile.entitlements`, add inside `<dict>` after the existing `network.server` entry:

```xml
	<key>com.apple.security.network.client</key>
	<true/>
```

In `macos/Runner/Release.entitlements`, add inside `<dict>` after `app-sandbox`:

```xml
	<key>com.apple.security.network.client</key>
	<true/>
	<key>com.apple.security.network.server</key>
	<true/>
```

- [ ] **Step 3: Correct the spec's SDK version**

In the spec's Stack table, change `` | `matrix` ^12.0.1 | `` to `` | `matrix` ^13.0.0 | ``. In the paragraph "Why matrix-dart-sdk…", change "As of v12.0.1 (2026-09-02)" to "As of v13.0.0 (2026-09-22)".

- [ ] **Step 4: Write the failing test**

`test/matrix/client_factory_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('a new database opens signed out', () async {
    final client = await openClient(
      httpClient: FakeMatrixApi(),
      databasePath: inMemoryDatabasePath,
    );
    addTearDown(client.dispose);
    await client.init(waitForFirstSync: false);
    expect(client.onLoginStateChanged.value, LoginState.loggedOut);
  });

  test('two in-memory clients do not share a database', () async {
    Future<Client> fresh() async {
      final c = await openClient(
        httpClient: FakeMatrixApi(),
        databasePath: inMemoryDatabasePath,
      );
      FakeMatrixApi.client = c;
      addTearDown(c.dispose);
      await c.init(waitForFirstSync: false);
      return c;
    }

    final a = await fresh();
    await a.checkHomeserver(
      Uri.https('fakeServer.notExisting'),
      checkWellKnown: false,
    );
    await a.login(
      LoginType.mLoginPassword,
      identifier: AuthenticationUserIdentifier(user: 'test'),
      password: 'x',
    );
    final b = await fresh();
    expect(a.isLogged(), isTrue);
    expect(b.isLogged(), isFalse);
  });
}
```

- [ ] **Step 5: Run it to see it fail**

Run: `mise exec -- flutter test test/matrix/client_factory_test.dart`
Expected: a compile failure, because `package:loaf_native/matrix/client_factory.dart` does not exist yet.

- [ ] **Step 6: Write the factory**

`lib/matrix/client_factory.dart`:

```dart
/// Opens the app's one [Client]. Everything that touches `package:matrix`
/// lives under `lib/matrix/`, so an SDK upgrade stays in one directory.
library;

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// [databasePath] defaults to a file in the app's support directory; tests
/// pass `inMemoryDatabasePath`. [httpClient] is for tests too.
Future<Client> openClient({
  http.Client? httpClient,
  String? databasePath,
}) async {
  // The sqlite3 package bundles sqlite through build hooks on every
  // platform, so one ffi factory serves iOS, macOS and Linux alike.
  sqfliteFfiInit();
  final path =
      databasePath ??
      '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}loaf.sqlite';
  final database = await MatrixSdkDatabase.init(
    'loaf',
    database: await databaseFactoryFfi.openDatabase(
      path,
      // Each in-memory open must be its own database, or tests share one.
      options: OpenDatabaseOptions(singleInstance: false),
    ),
    sqfliteFactory: databaseFactoryFfi,
  );
  return Client('loaf', database: database, httpClient: httpClient);
}
```

- [ ] **Step 7: Run the tests**

Run: `mise exec -- flutter test test/matrix/client_factory_test.dart`, then `mise exec -- flutter test` and `mise exec -- flutter analyze`.
Expected: 2 new tests pass; the whole suite is 423 green; analyze reports no issues. The SDK prints `[Matrix]` log lines, which is normal.

- [ ] **Step 8: Checkpoint**

Suggested commit: `build: add matrix-dart-sdk and open its client` (body: SDK 13 rather than the spec's 12, one ffi sqlite factory everywhere, and the macOS network entitlements the sandbox needs).

---

### Task 2: The `Homeserver` seam

**Files:**
- Create: `lib/ui/auth/homeserver.dart`, `lib/ui/mock/mock_homeserver.dart`
- Modify: `lib/ui/auth/sign_in_controller.dart` (rewritten), `lib/ui/auth/sign_in_state.dart`
- Test: `test/sign_in_controller_test.dart` (append only)

**Interfaces:**
- Produces: `Homeserver` with `probe`, `password`, `sso`, `reopenSso`, `cancelSso` and `close`, and the sealed `SignInOutcome` family `SignedIn`, `WrongPassword`, `RateLimited(Duration retryIn)`, `SignInCancelled`, `SignInFailed(String message)`. Later tasks implement it (Task 5) and hand one out (Tasks 6 and 7).
- Produces: `SignInController({..., Homeserver? homeserver, ...})` and `SignInController.at(state, {..., Homeserver? homeserver, ...})`. Without a homeserver, both build a `MockHomeserver(servers:, consumeFailure:)`, so every existing call site and test works as before.
- Produces: `SignInState.failure` (`String?`), plus `copyWith(failure:, clearFailure:)`.

- [ ] **Step 1: Write the failing tests**

Append to `test/sign_in_controller_test.dart`. Add `import 'dart:async';` and `import 'package:loaf_native/ui/auth/homeserver.dart';` at the top. Then add this group as the last thing inside `main()`, and the constant and class after `main()`:

```dart
  group('answers arrive when they like', () {
    testWidgets('an answer to an old question is dropped', (tester) async {
      final hs = _Scripted();
      final c = SignInController(
        server: 'one.test',
        onSignedIn: () => signedIn++,
        homeserver: hs,
      );
      c.connect('two.test');
      hs.probes['one.test']!.complete(
        const ServerFailed(ServerProblem.notMatrix),
      );
      await tester.pump();
      expect(c.state.server, 'two.test');
      expect(c.state.check, isA<ServerProbing>());

      hs.probes['two.test']!.complete(
        const ServerFound(ServerFlows(password: true)),
      );
      await tester.pump();
      expect(c.state.check, isA<ServerFound>());
      c.dispose();
    });

    testWidgets('sso answering after a connect elsewhere never signs in', (
      tester,
    ) async {
      final hs = _Scripted();
      final c = SignInController.at(
        const SignInState(server: 'one.test', check: ServerFound(_both)),
        onSignedIn: () => signedIn++,
        homeserver: hs,
        desktop: true,
      );
      c.continueWithSso(const IdentityProvider('x', 'X'));
      c.connect('two.test');
      hs.ssoAnswer!.complete(const SignedIn());
      await tester.pump();
      expect(signedIn, 0);
      expect(hs.cancelled, isTrue);
      c.dispose();
    });

    testWidgets('a failure is said, and cleared by the next try', (
      tester,
    ) async {
      final hs = _Scripted();
      final c = SignInController.at(
        const SignInState(server: 'one.test', check: ServerFound(_both)),
        onSignedIn: () => signedIn++,
        homeserver: hs,
      );
      c.signInWithPassword('chris', 'x');
      hs.passwordAnswer!.complete(
        const SignInFailed("couldn't reach one.test"),
      );
      await tester.pump();
      expect(c.state.failure, "couldn't reach one.test");
      expect(c.state.activity, SignInActivity.idle);

      c.signInWithPassword('chris', 'x');
      expect(c.state.failure, isNull);
      hs.passwordAnswer!.complete(const SignedIn());
      await tester.pump();
      expect(signedIn, 1);
      c.dispose();
    });

    testWidgets("the server's own wait is counted down", (tester) async {
      final hs = _Scripted();
      final c = SignInController.at(
        const SignInState(server: 'one.test', check: ServerFound(_both)),
        homeserver: hs,
      );
      c.signInWithPassword('chris', 'x');
      hs.passwordAnswer!.complete(const RateLimited(Duration(seconds: 3)));
      await tester.pump();
      expect(c.state.retryIn, const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 3));
      expect(c.state.retryIn, isNull);
      c.dispose();
    });

    testWidgets('closing the screen closes the homeserver', (tester) async {
      final hs = _Scripted();
      SignInController(
        server: 'one.test',
        onSignedIn: () {},
        homeserver: hs,
      ).dispose();
      expect(hs.closed, isTrue);
    });
  });
```

```dart
const _both = ServerFlows(
  providers: [IdentityProvider('x', 'X')],
  password: true,
);

/// A homeserver whose every answer the test hands over by hand.
class _Scripted implements Homeserver {
  final probes = <String, Completer<ServerCheck>>{};
  Completer<SignInOutcome>? passwordAnswer;
  Completer<SignInOutcome>? ssoAnswer;
  var cancelled = false;
  var closed = false;

  @override
  Future<ServerCheck> probe(String server) =>
      (probes[server] = Completer()).future;

  @override
  Future<SignInOutcome> password(String server, String user, String pw) =>
      (passwordAnswer = Completer()).future;

  @override
  Future<SignInOutcome> sso(
    String server,
    IdentityProvider provider, {
    required bool desktop,
  }) => (ssoAnswer = Completer()).future;

  @override
  void reopenSso() {}

  @override
  void cancelSso() => cancelled = true;

  @override
  void close() => closed = true;
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `mise exec -- flutter test test/sign_in_controller_test.dart`
Expected: a compile failure, because `homeserver.dart` and the `homeserver:` parameter do not exist yet.

- [ ] **Step 3: Write the interface**

`lib/ui/auth/homeserver.dart`:

```dart
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
  Future<SignInOutcome> password(String server, String user, String password);

  /// Resolves when the provider hands back, or with [SignInCancelled] once
  /// [cancelSso] is called. [desktop] picks the real browser over the
  /// system sheet.
  Future<SignInOutcome> sso(
    String server,
    IdentityProvider provider, {
    required bool desktop,
  });

  /// Desktop: opens the pending SSO page in the browser again.
  void reopenSso();

  /// Abandons a pending [sso]. Does nothing when none is pending.
  void cancelSso();

  /// The sign-in screen is going: stop everything in flight.
  void close();
}
```

- [ ] **Step 4: Move the fixture answers into `MockHomeserver`**

`lib/ui/mock/mock_homeserver.dart`. Its counting of wrong passwords and its 30 s limit are exactly what `SignInController` did before; they move here because a real server does that counting itself:

```dart
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
  Future<SignInOutcome> password(String server, String user, String password) =>
      _later(passwordDelay, () {
        final wrong = password == mockWrongPassword || consumeFailure();
        if (!wrong) {
          _wrongInARow = 0;
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
  }) {
    cancelSso();
    final done = _sso = Completer<SignInOutcome>();
    _ssoDelay = desktop ? browserDelay : ssoSheetDelay;
    _waitForSso();
    return done.future;
  }

  void _waitForSso() {
    _ssoTimer?.cancel();
    _ssoTimer = Timer(_ssoDelay, () {
      final done = _sso;
      _sso = null;
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
```

- [ ] **Step 5: Give the state a `failure`**

In `lib/ui/auth/sign_in_state.dart`, add `this.failure,` as the last constructor parameter (after `this.repointing,`). Add this field after `repointing`:

```dart
  /// The last attempt went wrong in a way that is neither a wrong password
  /// nor a rate limit — nothing answered, or SSO came back empty — worded
  /// for the screen.
  final String? failure;
```

Add `String? failure, bool clearFailure = false,` to `copyWith`'s parameters, after `String? repointing,`. Add this line after `repointing: repointing ?? this.repointing,` in its body:

```dart
    failure: clearFailure ? null : (failure ?? this.failure),
```

- [ ] **Step 6: Rewrite the controller over a `Homeserver`**

Replace the whole of `lib/ui/auth/sign_in_controller.dart`. What changes:
- Every `_after(delay, …)` timer becomes a question put to `homeserver` through `_ask`, whose epoch counter drops stale answers. It replaces cancelling timers.
- The wrong-try counting moves to `MockHomeserver`.
- `_startLimit` takes the server's own wait.

The debounce, the queued password and every guard stay exactly as they were.

```dart
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
import '../platform.dart';
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
    bool? desktop,
  }) : homeserver =
           homeserver ??
           MockHomeserver(servers: servers, consumeFailure: consumeFailure),
       desktop = desktop ?? isDesktop,
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
    bool? desktop,
  }) : onSignedIn = onSignedIn ?? _nothing,
       homeserver =
           homeserver ??
           MockHomeserver(servers: servers, consumeFailure: consumeFailure),
       desktop = desktop ?? isDesktop,
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
  final bool desktop;

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
  void _ask<T>(Future<T> question, void Function(T answer) then) {
    final mine = ++_epoch;
    question.then((answer) {
      if (mine == _epoch) then(answer);
    });
  }

  /// The server picker's connect. Input that names no server is ignored.
  void connect(String input) {
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
        activity: desktop
            ? SignInActivity.inBrowser
            : SignInActivity.finishingSso,
        provider: provider,
        clearFailure: true,
      ),
    );
    _ask(
      homeserver.sso(_state.server, provider, desktop: desktop),
      _finish,
    );
  }

  /// Desktop: the browser tab was closed or lost.
  void reopenBrowser() {
    if (_state.activity != SignInActivity.inBrowser) return;
    homeserver.reopenSso();
  }

  void cancelSso() {
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
    _ask(homeserver.password(_state.server, user, password), _finish);
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
```

- [ ] **Step 7: Run the tests**

Run: `mise exec -- dart format lib test`, then `mise exec -- flutter test` and `mise exec -- flutter analyze`.
Expected: all 428 pass: the 423 from Task 1 plus these 5. Every existing sign-in controller test passes unedited. If one fails, the refactor changed behaviour: fix the code, not the test.

- [ ] **Step 8: Checkpoint**

Suggested commit: `refactor(ui): sign-in asks a Homeserver, and drops stale answers` (body: the state machine stays, the answers move behind an interface so the SDK can give them, and an epoch replaces timer cancelling).

---

### Task 3: The sign-in screen says a failure

**Files:**
- Modify: `lib/ui/auth/login_page.dart` (in `_faces`, beside the `ServerFailed` note)
- Test: `test/login_page_test.dart` (append only)

**Interfaces:**
- Consumes: `SignInState.failure` (Task 2).

- [ ] **Step 1: Write the failing tests**

In `test/login_page_test.dart`, add an entry to the `faces` map after `'no usable flow'`, so that it is laid out at phone and Mac widths:

```dart
    'failed': SignInState(
      server: 'loaf.moe',
      check: mockServers['loaf.moe']!,
      failure: "couldn't reach loaf.moe",
    ),
```

Then add this as the last test in `main()`:

```dart
  testWidgets('a failure is said under the controls', (tester) async {
    final c = SignInController.at(
      SignInState(
        server: 'loaf.moe',
        check: mockServers['loaf.moe']!,
        failure: "couldn't reach loaf.moe",
      ),
    );
    await _pump(tester, c);
    expect(find.text("couldn't reach loaf.moe"), findsOneWidget);
    expect(find.text('continue with loaf.moe'), findsOneWidget);
    c.dispose();
  });
```

- [ ] **Step 2: Run it to see it fail**

Run: `mise exec -- flutter test test/login_page_test.dart`
Expected: "a failure is said under the controls" fails, finding no widget with that text.

- [ ] **Step 3: Say it**

In `lib/ui/auth/login_page.dart`, directly after this block in `_faces`:

```dart
        if (failed != null) ...[
          const SizedBox(height: LoafSpace.x3),
          ErrorNote(message: failed.messageFor(s.server)),
        ],
```

add:

```dart
        if (s.failure case final failure?) ...[
          const SizedBox(height: LoafSpace.x3),
          ErrorNote(message: failure),
        ],
```

- [ ] **Step 4: Run the tests**

Run: `mise exec -- flutter test` and `mise exec -- flutter analyze`.
Expected: 431 pass: 428 plus the 2 layout variants and the new test.

- [ ] **Step 5: Checkpoint**

Suggested commit: `feat(ui): the sign-in screen says when an attempt failed`.

---

### Task 4: Where SSO happens

**Files:**
- Create: `lib/matrix/sso_browser.dart`
- Test: `test/matrix/sso_browser_test.dart`

**Interfaces:**
- Produces: `SsoBrowser` with `Future<String?> signIn(Uri Function(Uri redirect) urlFor)`, `void reopen()` and `void cancel()`. `signIn` resolves with the `loginToken`, or null if the person gave up.
- Produces: `SheetSsoBrowser({Future<String> Function(String url, String scheme)? authenticate})`, with `static const scheme = 'moe.loaf.native'`, and `LoopbackSsoBrowser({Future<bool> Function(Uri url)? open})`. Their injected functions stand in for `FlutterWebAuth2.authenticate` and `launchUrl` in tests.

loaf.moe (tuwunel) was checked on 2026-09-26 and accepts both `redirectUrl=http://127.0.0.1:<port>/sso` and `redirectUrl=moe.loaf.native://sso`, sending both on to Kanidm.

- [ ] **Step 1: Write the failing tests**

`test/matrix/sso_browser_test.dart`:

```dart
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/matrix/sso_browser.dart';

Uri _page(Uri redirect) => Uri.parse(
  'https://matrix.loaf.test/_matrix/client/v3/login/sso/redirect/x',
).replace(queryParameters: {'redirectUrl': redirect.toString()});

/// What the homeserver does at the end of SSO: send the browser to the
/// redirect URL with a login token added.
Future<int> _comeBack(Uri page, {String? token = 'tok'}) async {
  final redirect = Uri.parse(page.queryParameters['redirectUrl']!);
  final back = redirect.replace(queryParameters: {'loginToken': ?token});
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(back)).close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close();
  }
}

/// Waits for the browser to have been opened [times].
Future<void> _opened(List<Uri> opened, [int times = 1]) async {
  while (opened.length < times) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  group('loopback', () {
    test('the token the browser brings back resolves the sign-in', () async {
      final opened = <Uri>[];
      final browser = LoopbackSsoBrowser(
        open: (url) async {
          opened.add(url);
          return true;
        },
      );
      final pending = browser.signIn(_page);
      await _opened(opened);
      final redirect = Uri.parse(opened.single.queryParameters['redirectUrl']!);
      expect(redirect.host, '127.0.0.1');
      expect(await _comeBack(opened.single), 200);
      expect(await pending, 'tok');
    });

    test('a visit with no token is turned away and keeps waiting', () async {
      final opened = <Uri>[];
      final browser = LoopbackSsoBrowser(
        open: (url) async {
          opened.add(url);
          return true;
        },
      );
      final pending = browser.signIn(_page);
      await _opened(opened);
      expect(await _comeBack(opened.single, token: null), 404);
      expect(await _comeBack(opened.single), 200);
      expect(await pending, 'tok');
    });

    test('reopen opens the same page; cancel resolves null', () async {
      final opened = <Uri>[];
      final browser = LoopbackSsoBrowser(
        open: (url) async {
          opened.add(url);
          return true;
        },
      );
      final pending = browser.signIn(_page);
      await _opened(opened);
      browser.reopen();
      expect(opened, hasLength(2));
      expect(opened.last, opened.first);
      browser.cancel();
      expect(await pending, isNull);
      // The listener is gone with it.
      await expectLater(
        _comeBack(opened.first),
        throwsA(isA<SocketException>()),
      );
    });

    test('cancelling while the listener binds opens nothing', () async {
      final opened = <Uri>[];
      final browser = LoopbackSsoBrowser(
        open: (url) async {
          opened.add(url);
          return true;
        },
      );
      final pending = browser.signIn(_page);
      browser.cancel();
      expect(await pending, isNull);
      expect(opened, isEmpty);
    });

    test('a browser that will not open ends the attempt', () async {
      final browser = LoopbackSsoBrowser(open: (_) async => false);
      expect(await browser.signIn(_page), isNull);
    });
  });

  group('sheet', () {
    test('reads the token off the callback', () async {
      String? scheme;
      final browser = SheetSsoBrowser(
        authenticate: (url, s) async {
          scheme = s;
          final redirect = Uri.parse(url).queryParameters['redirectUrl'];
          expect(redirect, 'moe.loaf.native://sso');
          return '$redirect?loginToken=tok';
        },
      );
      expect(await browser.signIn(_page), 'tok');
      expect(scheme, SheetSsoBrowser.scheme);
    });

    test('closing the sheet is a cancel', () async {
      final browser = SheetSsoBrowser(
        authenticate: (_, _) async => throw PlatformException(code: 'CANCELED'),
      );
      expect(await browser.signIn(_page), isNull);
    });

    test('an answer after cancel is dropped', () async {
      final browser = SheetSsoBrowser(
        authenticate: (url, _) async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return 'moe.loaf.native://sso?loginToken=late';
        },
      );
      final pending = browser.signIn(_page);
      browser.cancel();
      expect(await pending, isNull);
    });
  });
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `mise exec -- flutter test test/matrix/sso_browser_test.dart`
Expected: a compile failure, because `sso_browser.dart` does not exist yet.

- [ ] **Step 3: Write the browsers**

`lib/matrix/sso_browser.dart`:

```dart
/// Where SSO happens, split by platform as the spec says: the system's
/// sign-in sheet on a phone, the real browser on a computer.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:url_launcher/url_launcher.dart';

abstract interface class SsoBrowser {
  /// Opens `urlFor(redirect)` and resolves with the `loginToken` the server
  /// sends back to [redirect], or null if the person gave up.
  Future<String?> signIn(Uri Function(Uri redirect) urlFor);

  /// Opens the pending page again, where that means anything.
  void reopen();

  /// Gives up on a pending [signIn], which resolves null.
  void cancel();
}

/// A phone: `ASWebAuthenticationSession` on iOS, a Custom Tab on Android.
/// The sheet is modal, so reopening means nothing and cancelling only
/// drops whatever it later returns.
class SheetSsoBrowser implements SsoBrowser {
  SheetSsoBrowser({
    Future<String> Function(String url, String scheme)? authenticate,
  }) : _authenticate = authenticate ?? _system;

  static Future<String> _system(String url, String scheme) =>
      FlutterWebAuth2.authenticate(url: url, callbackUrlScheme: scheme);

  /// The bundle id, which no other app can claim on iOS.
  static const scheme = 'moe.loaf.native';

  final Future<String> Function(String url, String scheme) _authenticate;
  var _attempt = 0;

  @override
  Future<String?> signIn(Uri Function(Uri redirect) urlFor) async {
    final mine = ++_attempt;
    try {
      final back = await _authenticate(
        urlFor(Uri.parse('$scheme://sso')).toString(),
        scheme,
      );
      if (mine != _attempt) return null;
      return Uri.parse(back).queryParameters['loginToken'];
    } on PlatformException {
      // CANCELED: the sheet was closed.
      return null;
    }
  }

  @override
  void reopen() {}

  @override
  void cancel() => _attempt++;
}

/// A computer: the real browser, returning to a one-shot listener on
/// 127.0.0.1. A loopback redirect needs no URL scheme registered with the
/// OS, which Linux has no single way to do.
class LoopbackSsoBrowser implements SsoBrowser {
  LoopbackSsoBrowser({Future<bool> Function(Uri url)? open})
    : _open = open ?? _launch;

  static Future<bool> _launch(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);

  final Future<bool> Function(Uri url) _open;
  HttpServer? _server;
  Uri? _page;
  Completer<String?>? _done;

  @override
  Future<String?> signIn(Uri Function(Uri redirect) urlFor) async {
    cancel();
    final done = _done = Completer<String?>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // Cancelled while binding: this attempt is already over.
    if (!identical(_done, done)) {
      await server.close(force: true);
      return done.future;
    }
    _server = server;
    final page = _page = urlFor(
      Uri(scheme: 'http', host: '127.0.0.1', port: server.port, path: '/sso'),
    );
    server.listen((request) async {
      final token = request.uri.path == '/sso'
          ? request.uri.queryParameters['loginToken']
          : null;
      request.response.statusCode = token == null
          ? HttpStatus.notFound
          : HttpStatus.ok;
      if (token != null) {
        request.response
          ..headers.contentType = ContentType.html
          ..write(_donePage);
      }
      await request.response.close();
      if (token != null && identical(_done, done)) _finish(token);
    });
    if (!await _open(page) && identical(_done, done)) _finish(null);
    return done.future;
  }

  @override
  void reopen() {
    final page = _page;
    if (_done != null && page != null) _open(page);
  }

  @override
  void cancel() => _finish(null);

  void _finish(String? token) {
    final done = _done;
    _done = null;
    _page = null;
    _server?.close(force: true);
    _server = null;
    done?.complete(token);
  }

  static const _donePage =
      '<!doctype html><meta charset="utf-8"><title>loaf</title>'
      '<body style="font-family:sans-serif;padding:3em">'
      "<p>you're signed in. you can close this tab and go back to loaf.</p>";
}
```

- [ ] **Step 4: Run the tests**

Run: `mise exec -- flutter test test/matrix/sso_browser_test.dart`, then `mise exec -- flutter test` and `mise exec -- flutter analyze`.
Expected: 8 new tests pass, 439 in all, and analyze is clean.

- [ ] **Step 5: Checkpoint**

Suggested commit: `feat(matrix): SSO in the system sheet on phones and the browser on computers` (body: the loopback redirect needs no OS URL-scheme registration, which Linux lacks a single way to do; loaf.moe accepts both redirect kinds).

---

### Task 5: `MatrixHomeserver`

**Files:**
- Create: `lib/matrix/matrix_homeserver.dart`
- Test: `test/matrix/matrix_homeserver_test.dart`

**Interfaces:**
- Consumes: `Homeserver` and the `SignInOutcome`s (Task 2); `openClient` (Task 1); `SsoBrowser` (Task 4).
- Produces: `MatrixHomeserver(Client client, {required SsoBrowser browser, required String deviceName, http.Client? httpClient})`. `httpClient` defaults to `client.httpClient`. Also the `@visibleForTesting` top-level functions `flowsFrom(Map<String, Object?>?) → ServerFlows`, `ssoUrl(String base, IdentityProvider, Uri redirect) → Uri` and `retryIn(int? ms) → Duration`.

Discovery deliberately avoids the SDK. `Client.getVersions` caches under one key for every server, so probing a second server would read the first one's answer. `Client.checkHomeserver` swallows well-known failures, so it cannot tell a broken delegation apart, and it `assert(false)`s on version mismatches in debug builds.

- [ ] **Step 1: Write the failing tests**

`test/matrix/matrix_homeserver_test.dart`:

```dart
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

  @override
  Future<String?> signIn(Uri Function(Uri redirect) urlFor) async => token;
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

Future<(MatrixHomeserver, _NoBrowser)> _make(http.Client http) async {
  final client = await openClient(
    httpClient: http,
    databasePath: inMemoryDatabasePath,
  );
  if (http is FakeMatrixApi) FakeMatrixApi.client = client;
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
      expect(
        await hs.password('loaf.test', 'chris', 'x'),
        isA<SignInFailed>(),
      );
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
  });
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `mise exec -- flutter test test/matrix/matrix_homeserver_test.dart`
Expected: a compile failure, because `matrix_homeserver.dart` does not exist yet.

- [ ] **Step 3: Write it**

`lib/matrix/matrix_homeserver.dart`:

```dart
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
    final named = 'https://$server';
    var base = named;
    String? delegatedTo;
    try {
      final wellKnown = await _json('$named/.well-known/matrix/client');
      final url = (wellKnown?['m.homeserver'] as Map?)?['base_url'];
      if (url is String && Uri.tryParse(url)?.hasAuthority == true) {
        base = _trim(url);
        final host = Uri.parse(base).host;
        if (host != Uri.parse(named).host) delegatedTo = host;
      }
    } on _NoAnswer {
      // No file and nothing answering: the name itself is tried next.
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

  @override
  Future<SignInOutcome> password(
    String server,
    String user,
    String password,
  ) => _signIn(
    server,
    () => client.login(
      LoginType.mLoginPassword,
      identifier: AuthenticationUserIdentifier(user: user.trim()),
      password: password,
      initialDeviceDisplayName: deviceName,
    ),
  );

  @override
  Future<SignInOutcome> sso(
    String server,
    IdentityProvider provider, {
    required bool desktop,
  }) async {
    final base = _bases[server];
    if (base == null) return SignInFailed("couldn't reach $server");
    final token = await browser.signIn(
      (redirect) => ssoUrl(base, provider, redirect),
    );
    if (token == null) return const SignInCancelled();
    return _signIn(
      server,
      () => client.login(
        LoginType.mLoginToken,
        token: token,
        initialDeviceDisplayName: deviceName,
      ),
      // A refused token is not a wrong password.
      refused: "${provider.name} didn't finish signing you in",
    );
  }

  @override
  void reopenSso() => browser.reopen();

  @override
  void cancelSso() => browser.cancel();

  @override
  void close() => browser.cancel();

  Future<SignInOutcome> _signIn(
    String server,
    Future<void> Function() login, {
    String? refused,
  }) async {
    final base = _bases[server];
    if (base == null) return SignInFailed("couldn't reach $server");
    client.homeserver = Uri.parse(base);
    try {
      await login();
      return const SignedIn();
    } on MatrixException catch (e) {
      return switch (e.error) {
        MatrixError.M_FORBIDDEN when refused == null => const WrongPassword(),
        MatrixError.M_LIMIT_EXCEEDED => RateLimited(retryIn(e.retryAfterMs)),
        _ => SignInFailed(refused ?? "$server said no: ${e.errorMessage}"),
      };
    } on Exception {
      return SignInFailed("couldn't reach $server");
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
  for (final flow in (login?['flows'] as List? ?? const []).whereType<Map>()) {
    switch (flow['type']) {
      case 'm.login.password':
        password = true;
      case 'm.login.sso':
        final listed = (flow['identity_providers'] as List? ?? const [])
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
  return Uri.parse(
    '$base/_matrix/client/v3/login/sso/redirect$id',
  ).replace(queryParameters: {'redirectUrl': redirect.toString()});
}

/// `retry_after_ms`, rounded up to the whole seconds the button counts in.
/// A server that names no wait gets thirty seconds.
@visibleForTesting
Duration retryIn(int? ms) =>
    Duration(seconds: max(1, ((ms ?? 30000) / 1000).ceil()));
```

- [ ] **Step 4: Run the tests**

Run: `mise exec -- flutter test test/matrix/matrix_homeserver_test.dart`, then `mise exec -- flutter test` and `mise exec -- flutter analyze`.
Expected: 13 new tests pass, 452 in all, and analyze is clean.

- [ ] **Step 5: Checkpoint**

Suggested commit: `feat(matrix): discovery and sign-in against a real homeserver` (body: why discovery is plain HTTP, that is, the SDK's shared versions cache and its assert; and that sign-in goes to the base its own name resolved to).

---

### Task 6: The `LoafSession` seam

**Files:**
- Create: `lib/ui/auth/loaf_session.dart`
- Modify: `lib/ui/mock/mock_session.dart`, `lib/ui/auth/session_root.dart`, `lib/ui/shell/app_shell.dart`
- Test: none new. The existing `session_root_test`, `mock_session_test`, `verify_panel_test` and `app_shell_test` are this task's proof, and must pass unedited.

**Interfaces:**
- Produces: `LoafSession implements Listenable`, with `account`, `trust`, `softLogout`, `incoming`, `homeserverName`, `newHomeserver()`, `signedIn()`, `signOut()`, `markVerified()`, `clearIncoming()`, `consumeFailure()` and `dispose()`. `AccountState`, `DeviceTrust` and `IncomingRequest` move into this file. `mock_session.dart` re-exports them, so their existing importers compile unchanged.

- [ ] **Step 1: Write the interface**

`lib/ui/auth/loaf_session.dart`:

```dart
/// Who is signed in and how far this device is trusted: what the app shows
/// sign-in or the shell from, and which encryption notice the rail carries.
/// [MockSession] plays it on fixtures; `MatrixSession` reads it from the SDK.
library;

import 'package:flutter/foundation.dart';

import 'homeserver.dart';
import 'sign_in_state.dart';

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

abstract interface class LoafSession implements Listenable {
  AccountState get account;
  DeviceTrust get trust;
  SoftLogout? get softLogout;
  IncomingRequest? get incoming;

  /// The server the sign-in screen opens on.
  String get homeserverName;

  /// Answers for one visit to the sign-in screen, which closes it on leaving.
  Homeserver newHomeserver();

  /// The sign-in screen got a yes.
  void signedIn();

  void signOut();

  /// This device was just verified.
  void markVerified();

  /// The incoming verification request was answered or put away.
  void clearIncoming();

  /// The debug "fail the next connection" lever, for flows still mocked.
  bool consumeFailure();

  void dispose();
}
```

(The `[MockSession]` reference in the library doc resolves nowhere, and the analyzer accepts that in a library doc. Leave it; it tells the reader where to look.)

- [ ] **Step 2: Make `MockSession` one**

In `lib/ui/mock/mock_session.dart`:
- Delete the `AccountState` enum, the `DeviceTrust` enum with its doc comments, and the `IncomingRequest` class. They now live in `loaf_session.dart`.
- Replace the imports with:

```dart
import 'package:flutter/foundation.dart';

import '../auth/homeserver.dart';
import '../auth/loaf_session.dart';
import '../auth/sign_in_state.dart';
import 'accounts.dart';
import 'fixtures.dart';
import 'mock_homeserver.dart';

// Tests and the shell name these through the mock, as they always have.
export '../auth/loaf_session.dart'
    show AccountState, DeviceTrust, IncomingRequest;
```

- Change `class MockSession extends ChangeNotifier {` to `class MockSession extends ChangeNotifier implements LoafSession {`.
- Add `@override` above the `account`, `trust`, `incoming` and `softLogout` getters, and above `consumeFailure()`, `signOut()`, `signedIn()`, `markVerified()` and `clearIncoming()`.
- After the `incoming` getter, add:

```dart
  @override
  String get homeserverName => server;

  @override
  Homeserver newHomeserver() => MockHomeserver(consumeFailure: consumeFailure);
```

`static const server = 'loaf.moe'` stays as it is. The instance getter has a different name because Dart forbids a static and an instance member sharing one.

- [ ] **Step 3: Let `SessionRoot` take any session**

In `lib/ui/auth/session_root.dart`:
- Change the library doc's first line to `/// Sign-in or the app, whichever the [LoafSession] says. Owns the sign-in`.
- Replace `import '../mock/mock_session.dart';` with `import 'loaf_session.dart';` (keep the imports sorted).
- Change `final MockSession session;` to `final LoafSession session;`, and `MockSession get _session => widget.session;` to `LoafSession get _session => widget.session;`.
- In `_follow`, build the controller like this:

```dart
      _signIn = SignInController(
        server: _session.homeserverName,
        softLogout: _session.softLogout,
        onSignedIn: _session.signedIn,
        homeserver: _session.newHomeserver(),
      );
```

- [ ] **Step 4: Let `AppShell` take any session**

In `lib/ui/shell/app_shell.dart`:
- Add `import '../auth/loaf_session.dart';` and keep `import '../mock/mock_session.dart';`, since the debug levers still need `MockSession`.
- Change `final MockSession? session;` to `final LoafSession? session;`, and `late final MockSession _session = widget.session ?? MockSession();` to `late final LoafSession _session = widget.session ?? MockSession();`.
- In `_debug`, the account levers only move the mock. The `signOut` lever keeps calling `_session.signOut()`, which works for both. Replace these cases:

```dart
      case MockDebug.failNext:
        // One "make the next thing fail" lever: the next call, sign-in or
        // verification, whichever comes first for each.
        _calls.failNextConnection();
        if (_session case final MockSession mock) mock.failNext();
```

```dart
      case MockDebug.signOut:
        _session.signOut();
      // The account levers only move the mock; a real account's state
      // comes from its server.
      case MockDebug.expireSession:
        if (_session case final MockSession mock) mock.expireSession();
      case MockDebug.freshAccount:
        if (_session case final MockSession mock) mock.useFreshAccount();
      case MockDebug.newSignIn:
        if (_session case final MockSession mock) mock.receiveRequest();
```

- [ ] **Step 5: Run the tests**

Run: `mise exec -- dart format lib test`, then `mise exec -- flutter test` and `mise exec -- flutter analyze`.
Expected: still 452 pass with no test edited, and analyze is clean.

- [ ] **Step 6: Checkpoint**

Suggested commit: `refactor(ui): the app speaks LoafSession, not MockSession` (body: gives the SDK a place to stand; the debug levers that fake account events stay mock-only).

---

### Task 7: `MatrixSession`, chosen at launch

**Files:**
- Create: `lib/matrix/matrix_session.dart`
- Modify: `lib/main.dart`
- Test: `test/matrix/matrix_session_test.dart`

**Interfaces:**
- Consumes: everything above.
- Produces: `MatrixSession(Client client, {required SsoBrowser Function() browser, required String deviceName, String defaultServer = 'loaf.moe'})`, and `static Future<MatrixSession> open({required bool desktop})`. `open` initialises vodozemac, opens the client and restores any stored session. Also produces the top-level `String deviceNameFor({required bool desktop})`.

- [ ] **Step 1: Write the failing tests**

`test/matrix/matrix_session_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:loaf_native/matrix/matrix_session.dart';
import 'package:loaf_native/matrix/sso_browser.dart';
import 'package:loaf_native/ui/auth/homeserver.dart';
import 'package:loaf_native/ui/auth/loaf_session.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<MatrixSession> _session() async {
  final client = await openClient(
    httpClient: FakeMatrixApi(),
    databasePath: inMemoryDatabasePath,
  );
  FakeMatrixApi.client = client;
  await client.init(waitForFirstSync: false);
  final session = MatrixSession(
    client,
    browser: () => LoopbackSsoBrowser(open: (_) async => false),
    deviceName: 'loaf on test',
    defaultServer: 'fakeServer.notExisting',
  );
  addTearDown(session.dispose);
  return session;
}

/// Lets the SDK's streams deliver.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

Future<void> _signIn(MatrixSession s) async {
  final hs = s.newHomeserver();
  await hs.probe('fakeServer.notExisting');
  expect(
    await hs.password('fakeServer.notExisting', 'test', 'x'),
    isA<SignedIn>(),
  );
}

void main() {
  test('a fresh database is signed out', () async {
    final s = await _session();
    expect(s.account, AccountState.signedOut);
  });

  test('signing in through its homeserver signs the session in', () async {
    final s = await _session();
    var notified = 0;
    s.addListener(() => notified++);
    await _signIn(s);
    await s.client.onSyncStatus.stream.firstWhere(
      (u) => u.status == SyncStatus.finished,
    );
    await _settle();
    expect(s.account, AccountState.signedIn);
    // Read from loaded keys, not the not-yet-known default.
    final keys = s.client.userDeviceKeys[s.client.userID]!;
    expect(keys.outdated, isFalse);
    expect(keys.masterKey, isNotNull);
    // The fake account has an identity this new device is not signed by.
    expect(s.trust, DeviceTrust.unverified);
    expect(notified, greaterThan(0));
  });

  test('keys not yet known never read as no identity', () async {
    final s = await _session();
    await _signIn(s);
    // Straight after sign-in, before any sync has fetched device keys.
    expect(s.trust, isNot(DeviceTrust.noIdentity));
  });

  test('signing out signs the session out', () async {
    final s = await _session();
    await _signIn(s);
    await _settle();
    s.signOut();
    await _settle();
    expect(s.account, AccountState.signedOut);
  });

  test('a token refresh in flight does not sign out', () async {
    final s = await _session();
    await _signIn(s);
    await _settle();
    s.client.onLoginStateChanged.add(LoginState.softLoggedOut);
    await _settle();
    expect(s.account, AccountState.signedIn);
  });

  test('device names say where they are', () {
    expect(deviceNameFor(desktop: true), startsWith('loaf on '));
  });
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `mise exec -- flutter test test/matrix/matrix_session_test.dart`
Expected: a compile failure, because `matrix_session.dart` does not exist yet.

- [ ] **Step 3: Write the session**

`lib/matrix/matrix_session.dart`:

```dart
/// The real [LoafSession]: the app's one [Client], its login state and this
/// device's trust, read from the SDK rather than kept alongside it.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;
import 'package:matrix/matrix.dart';

import '../ui/auth/homeserver.dart';
import '../ui/auth/loaf_session.dart';
import '../ui/auth/sign_in_state.dart';
import 'client_factory.dart';
import 'matrix_homeserver.dart';
import 'sso_browser.dart';

class MatrixSession extends ChangeNotifier implements LoafSession {
  MatrixSession(
    this.client, {
    required this.browser,
    required this.deviceName,
    this.defaultServer = 'loaf.moe',
  }) {
    _subscriptions = [
      client.onLoginStateChanged.stream.listen((_) => _refresh()),
      // Device keys are updated after a sync is handled, and `finished`
      // comes after that; `onSync` fires too early to see them.
      client.onSyncStatus.stream
          .where((u) => u.status == SyncStatus.finished)
          .listen((_) => _refresh()),
    ];
    _account = _accountNow();
    _trust = _trustNow();
  }

  /// Opens the stored session, if any. Offline is fine: a stored session
  /// restores from the database and sync retries on its own.
  static Future<MatrixSession> open({required bool desktop}) async {
    // Before the client exists, so this device has encryption keys from its
    // very first sign-in rather than growing them later.
    await vod.init();
    final client = await openClient();
    await client.init(waitForFirstSync: false);
    return MatrixSession(
      client,
      browser: desktop ? LoopbackSsoBrowser.new : SheetSsoBrowser.new,
      deviceName: deviceNameFor(desktop: desktop),
    );
  }

  final Client client;

  /// Makes each sign-in visit its own browser, so a visit being put away
  /// can never cancel the next one's wait.
  final SsoBrowser Function() browser;

  final String deviceName;

  /// The server a signed-out app offers first.
  final String defaultServer;

  late final List<StreamSubscription<Object?>> _subscriptions;
  late AccountState _account;
  late DeviceTrust _trust;

  @override
  AccountState get account => _account;

  @override
  DeviceTrust get trust => _trust;

  /// The SDK refreshes an expired token itself and clears the session if it
  /// cannot, so there is no locked "welcome back" screen yet.
  @override
  SoftLogout? get softLogout => null;

  /// Verification requests are phase 4.
  @override
  IncomingRequest? get incoming => null;

  @override
  String get homeserverName => defaultServer;

  @override
  Homeserver newHomeserver() =>
      MatrixHomeserver(client, browser: browser(), deviceName: deviceName);

  /// The login state stream says so on its own.
  @override
  void signedIn() {}

  @override
  void signOut() {
    unawaited(_signOut());
  }

  Future<void> _signOut() async {
    try {
      await client.logout();
    } on Exception {
      // The server may be unreachable; logout clears this device either way.
    }
  }

  /// Trust is read from device keys, so there is nothing to record.
  @override
  void markVerified() {}

  @override
  void clearIncoming() {}

  @override
  bool consumeFailure() => false;

  AccountState _accountNow() => switch (client.onLoginStateChanged.value) {
    LoginState.loggedIn => AccountState.signedIn,
    // Announced while the SDK refreshes the token, which usually works.
    // Showing sign-in for it would flash the login screen on every refresh.
    LoginState.softLoggedOut => AccountState.signedIn,
    LoginState.loggedOut || null => AccountState.signedOut,
  };

  DeviceTrust _trustNow() {
    final userId = client.userID;
    final keys = userId == null ? null : client.userDeviceKeys[userId];
    // Until this account's keys are known, never claim it has no identity:
    // that notice offers to make one, and would reset a real one.
    if (keys == null || keys.outdated) return DeviceTrust.unverified;
    if (keys.masterKey == null) return DeviceTrust.noIdentity;
    return client.isUnknownSession
        ? DeviceTrust.unverified
        : DeviceTrust.verified;
  }

  void _refresh() {
    final account = _accountNow();
    final trust = _trustNow();
    if (account == _account && trust == _trust) return;
    _account = account;
    _trust = trust;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    unawaited(client.dispose());
    super.dispose();
  }
}

/// What other sessions call this one: "loaf on" this Mac's name, or the
/// kind of phone.
String deviceNameFor({required bool desktop}) {
  if (desktop) return 'loaf on ${Platform.localHostname.split('.').first}';
  return Platform.isIOS ? 'loaf on iPhone' : 'loaf on Android';
}
```

- [ ] **Step 4: Pick the backend at launch**

In `lib/main.dart`, add the imports `matrix/matrix_session.dart`, `ui/auth/loaf_session.dart` and `ui/platform.dart` (sorted with the others). Then replace:

```dart
/// The mock's one account. Lives as long as the app, like [themeMode].
final session = MockSession();

void main() => runApp(const LoafApp());
```

with:

```dart
/// `--dart-define=LOAF_BACKEND=matrix` talks to a real homeserver; anything
/// else plays the mock, which stays the default until the rooms are real.
const backend = String.fromEnvironment('LOAF_BACKEND', defaultValue: 'mock');

/// The app's one account. Lives as long as the app, like [themeMode].
late final LoafSession session;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The stored session restores from disk before the first frame, so a
  // signed-in app never flashes the sign-in screen.
  session = backend == 'matrix'
      ? await MatrixSession.open(desktop: isDesktop)
      : MockSession();
  runApp(const LoafApp());
}
```

- [ ] **Step 5: Run the tests and both builds**

Run: `mise exec -- dart format lib test`, then `mise exec -- flutter test` and `mise exec -- flutter analyze`.
Expected: 458 pass, and analyze is clean.

Then: `mise exec -- flutter build macos --debug --dart-define=LOAF_BACKEND=matrix` and `mise exec -- flutter build ios --simulator --debug --dart-define=LOAF_BACKEND=matrix`.
Expected: both end in `✓ Built`. The Swift deprecation warnings from `desktop_webview_window` are expected.

- [ ] **Step 6: Checkpoint**

Suggested commit: `feat: sign in to a real homeserver behind LOAF_BACKEND=matrix` (body: the session restores before the first frame; trust waits for device keys rather than guessing "no identity"; soft logout during token refresh stays signed in).

---

### Task 8: Look at it for real (Chris, with an agent driving)

No code. This needs Chris's Kanidm sign-in, so it cannot be delegated wholesale. An agent launches the app and reads its logs; Chris does the sign-ins.

- [ ] **macOS, SSO.** `mise exec -- flutter run -d macos --dart-define=LOAF_BACKEND=matrix`. The sign-in screen finds loaf.moe and shows "continue with loaf.moe". Pressing it opens the real browser at Kanidm, and the screen shows "finish in your browser". Once signed in, the tab says "you're signed in…" and the app switches to the shell. Also check "open it again" (the same page) and "cancel" (back to the button).
- [ ] **macOS, restore and offline.** Quit and relaunch: it opens signed in, with no sign-in flash. Turn Wi-Fi off and relaunch: it still opens signed in.
- [ ] **The rail notice.** A new device shows "verify this device", never "set up recovery", because Chris's account has an identity.
- [ ] **Sign out.** The debug menu's sign-out goes back to the sign-in screen. Element's sessions list no longer has the "loaf on …" device.
- [ ] **iOS simulator, SSO.** `mise exec -- flutter run -d <simulator> --dart-define=LOAF_BACKEND=matrix`. "Continue with loaf.moe" opens the system sign-in sheet; finishing lands in the shell, and closing the sheet goes back to the button with nothing said.
- [ ] **Password, on the service account** Chris supplies. A wrong password says "didn't match"; the right one signs in.
- [ ] **Errors.** A server that doesn't exist says "nothing answered at …". `example.com` says "isn't a matrix server".

If anything here fails, open a debugging session with the failure and its `[Matrix]` log lines. Do not patch on the spot.

---

## Self-Review Notes

- **Spec coverage (sign-in, discovery and SSO sections):**
  - `.well-known` → `/versions` → `/login`: Task 5.
  - Three distinct failures: Task 5.
  - The name typed kept on the server line: unchanged, since the controller keeps `state.server`.
  - One provider shows "continue with"; several show equal buttons: unchanged UI, fed real flows by Task 5.
  - Password only where advertised: `flowsFrom`.
  - SSO sheet on a phone, real browser plus "finish in your browser" on a computer: Tasks 4 and 5, reusing the existing `BrowserWait`.
  - `M_FORBIDDEN` and `M_LIMIT_EXCEEDED` with `retry_after_ms`: Task 5.
  - Enter submits and autofill hints: unchanged UI.
- **Deferred on purpose, and written into the roadmap:**
  - The soft-logout "welcome back" screen. The SDK refreshes the token or clears the session, so an app-level re-login keeping the device needs its own design.
  - MSC3861 OIDC. loaf.moe advertises `/auth_metadata`, but `m.login.sso` works today.
  - Verification and recovery against the SDK (phase 4). The mock verify flow still runs from the rail notice under `LOAF_BACKEND=matrix`, and it trusts nothing real.
  - Encrypting the sqlite database at rest.
- **Types:** `SignInOutcome` names, `Homeserver` members, `SsoBrowser Function()` and `LoafSession` members are identical everywhere they appear. `SignInController.at`'s `homeserver:` parameter is used by Task 2's tests.
