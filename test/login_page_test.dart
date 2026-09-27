import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/auth/homeserver.dart';
import 'package:loaf_native/ui/auth/login_page.dart';
import 'package:loaf_native/ui/auth/sign_in_controller.dart';
import 'package:loaf_native/ui/auth/sign_in_state.dart';
import 'package:loaf_native/ui/mock/accounts.dart';
import 'package:loaf_native/ui/mock/fixtures.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/widgets/loaf_button.dart';

const _phone = Size(390, 844);
const _mac = Size(1280, 800);

SignInState _on(
  String server, {
  SignInActivity activity = SignInActivity.idle,
  bool wrongPassword = false,
  Duration? retryIn,
}) => SignInState(
  server: server,
  check: mockServers[server] ?? const ServerFailed(ServerProblem.unreachable),
  activity: activity,
  provider: loafMoeProvider,
  wrongPassword: wrongPassword,
  retryIn: retryIn,
);

/// Pumps [controller] into a LoginPage. The probing faces spin forever, so
/// this pumps a fixed time instead of settling.
Future<void> _pump(
  WidgetTester tester,
  SignInController controller, {
  Size size = _phone,
  VoidCallback? onSignOutInstead,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: loafLightTheme(),
      darkTheme: loafDarkTheme(),
      themeMode: ThemeMode.dark,
      home: LoginPage(
        controller: controller,
        onSignOutInstead: onSignOutInstead,
      ),
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
    'checking password': _on(
      'passwords.test',
      activity: SignInActivity.checkingPassword,
    ),
    'wrong password': _on('passwords.test', wrongPassword: true),
    'rate limited': _on('passwords.test', retryIn: const Duration(seconds: 30)),
    'no usable flow': const SignInState(
      server: 'odd.test',
      check: ServerFound(ServerFlows()),
    ),
    'failed': SignInState(
      server: 'loaf.moe',
      check: mockServers['loaf.moe']!,
      failure: "couldn't reach loaf.moe",
    ),
    'committing': SignInState(
      server: 'sso-only.test',
      check: mockServers['sso-only.test']!,
      activity: SignInActivity.signedIn,
      provider: const IdentityProvider('oidc', 'Authentik'),
    ),
    'no sign-in info': _on('quiet.test'),
  };
  for (final MapEntry(key: name, value: state) in faces.entries) {
    for (final size in [_phone, _mac]) {
      testWidgets('$name lays out at ${size.width.toInt()} wide', (
        tester,
      ) async {
        final c = SignInController.at(state);
        await _pump(tester, c, size: size);
        expect(tester.takeException(), isNull);
        c.dispose();
      });
    }
  }

  testWidgets('picking a homeserver replaces the sign-in controls', (
    tester,
  ) async {
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

  testWidgets('connect does nothing until the field names a server', (
    tester,
  ) async {
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

  testWidgets('several providers are equals: none gets the filled button', (
    tester,
  ) async {
    final c = SignInController.at(_on('many-doors.test'));
    await _pump(tester, c);
    final providers = tester
        .widgetList<LoafButton>(find.byType(LoafButton))
        .where((b) => b.label.startsWith('continue with'));
    expect(providers, hasLength(4));
    expect(
      providers.every((b) => b.emphasis == LoafButtonEmphasis.outlined),
      isTrue,
    );
    // Their marks stand in for icons the mock cannot load.
    expect(find.text('G'), findsWidgets);
    c.dispose();
  });

  testWidgets('no password link where the server takes no password', (
    tester,
  ) async {
    final c = SignInController.at(_on('sso-only.test'));
    await _pump(tester, c);
    expect(find.text('use a username and password'), findsNothing);
    c.dispose();
  });

  testWidgets('each failure shows its own message and a retry', (tester) async {
    final c = SignInController.at(_on('broken.test'));
    await _pump(tester, c);
    expect(
      find.text(
        "broken.test points to matrix.broken.test, which didn't answer",
      ),
      findsOneWidget,
    );
    expect(find.text('try again'), findsOneWidget);
    c.dispose();
  });

  testWidgets('typing a full id re-points the server and keeps the form', (
    tester,
  ) async {
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
    final c = SignInController.at(
      _on('passwords.test'),
      onSignedIn: () => signedIn = true,
    );
    await _pump(tester, c);
    await tester.enterText(find.widgetWithText(TextField, 'username'), 'chris');
    await tester.enterText(
      find.widgetWithText(TextField, 'password'),
      'hunter2',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(SignInController.passwordDelay);
    expect(signedIn, isTrue);
    c.dispose();
  });

  testWidgets('the fields offer themselves to password managers', (
    tester,
  ) async {
    final c = SignInController.at(_on('passwords.test'));
    await _pump(tester, c);
    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .toList();
    expect(fields[0].autofillHints, contains(AutofillHints.username));
    expect(fields[1].autofillHints, contains(AutofillHints.password));
    expect(find.byType(AutofillGroup), findsOneWidget);
    c.dispose();
  });

  testWidgets('a wrong password says so under the fields', (tester) async {
    final c = SignInController.at(_on('passwords.test'));
    await _pump(tester, c);
    await tester.enterText(find.widgetWithText(TextField, 'username'), 'chris');
    await tester.enterText(
      find.widgetWithText(TextField, 'password'),
      mockWrongPassword,
    );
    await tester.tap(find.text('sign in'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('signing in…'), findsOneWidget);
    await tester.pump(SignInController.passwordDelay);
    expect(
      find.text("that username and password didn't match"),
      findsOneWidget,
    );
    c.dispose();
  });

  testWidgets('a rate limit counts down on a disabled button', (tester) async {
    final c = SignInController.at(
      _on('passwords.test', retryIn: const Duration(seconds: 30)),
    );
    await _pump(tester, c);
    final button = tester.widget<LoafButton>(
      find.widgetWithText(LoafButton, 'try again in 30s'),
    );
    expect(button.onTap, isNull);
    expect(find.text('too many tries'), findsOneWidget);
    c.dispose();
  });

  testWidgets('a server with no usable way in says so', (tester) async {
    final c = SignInController.at(
      const SignInState(server: 'odd.test', check: ServerFound(ServerFlows())),
    );
    await _pump(tester, c);
    expect(
      find.text('odd.test offers no sign-in loaf can use'),
      findsOneWidget,
    );
    c.dispose();
  });

  testWidgets(
    'a computer waits on the browser, and can open it again',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      var signedIn = false;
      final c = SignInController.at(
        _on('loaf.moe'),
        onSignedIn: () => signedIn = true,
      );
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
      softLogout: const SoftLogout(
        member: currentUser,
        userId: '@faore:loaf.moe',
      ),
    );

    testWidgets('is locked to the account, with no server to change', (
      tester,
    ) async {
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
      expect(
        find.textContaining("this device's encryption keys"),
        findsOneWidget,
      );

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

    testWidgets('fit in the row, the probe, the failure and the wait', (
      tester,
    ) async {
      for (final state in [
        const SignInState(server: long, check: ServerProbing()),
        const SignInState(
          server: long,
          check: ServerFailed(
            ServerProblem.delegationBroken,
            delegatedTo: 'matrix.$long',
          ),
        ),
        SignInState(
          server: 'passwords.test',
          check: mockServers['passwords.test']!,
          repointing: long,
        ),
        const SignInState(
          server: long,
          check: ServerFound(
            ServerFlows(providers: [IdentityProvider('x', long)]),
          ),
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

  group('password managers', () {
    /// What iOS last heard about the typed password: true to offer saving
    /// it, false to forget it. The last word is the one that counts.
    bool? lastWord(WidgetTester tester) => tester.testTextInput.log
        .where((call) => call.method == 'TextInput.finishAutofillContext')
        .map((call) => call.arguments as bool)
        .lastOrNull;

    Future<void> typeCredentials(WidgetTester tester, String password) async {
      await tester.enterText(
        find.widgetWithText(TextField, 'username'),
        'chris',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'password'),
        password,
      );
    }

    testWidgets('leaving the form for SSO forgets what was typed', (
      tester,
    ) async {
      final c = SignInController.at(_on('loaf.moe'));
      await _pump(tester, c);
      await tester.tap(find.text('use a username and password'));
      await tester.pump(const Duration(milliseconds: 100));
      await typeCredentials(tester, mockWrongPassword);
      tester.testTextInput.log.clear();

      await tester.tap(find.text('back to loaf.moe'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(lastWord(tester), isFalse);
      c.dispose();
    });

    testWidgets('a password that signed in is offered for saving', (
      tester,
    ) async {
      final c = SignInController.at(_on('passwords.test'));
      await _pump(tester, c);
      await typeCredentials(tester, 'hunter2');
      tester.testTextInput.log.clear();
      await tester.tap(find.text('sign in'));
      await tester.pump(SignInController.passwordDelay);

      // The app takes over: the sign-in screen goes, as SessionRoot does it.
      await tester.pumpWidget(
        MaterialApp(theme: loafDarkTheme(), home: const SizedBox()),
      );
      expect(lastWord(tester), isTrue);
      c.dispose();
    });
  });

  testWidgets('names are typed exactly: no autocorrect on server or username', (
    tester,
  ) async {
    final c = SignInController.at(_on('passwords.test'));
    await _pump(tester, c);
    final username = tester.widget<TextField>(
      find.widgetWithText(TextField, 'username'),
    );
    expect(username.autocorrect, isFalse);
    expect(username.enableSuggestions, isFalse);

    await tester.tap(find.text('passwords.test'));
    await tester.pump(const Duration(milliseconds: 100));
    final server = tester.widget<TextField>(find.byType(TextField));
    expect(server.autocorrect, isFalse);
    expect(server.enableSuggestions, isFalse);
    expect(server.keyboardType, TextInputType.url);
    c.dispose();
  });

  testWidgets('once signed in, there is no cancel and no continue with', (
    tester,
  ) async {
    final c = SignInController.at(faces['committing']!);
    await _pump(tester, c, size: _mac);
    expect(find.text('signing in…'), findsOneWidget);
    expect(find.text('cancel'), findsNothing);
    expect(find.textContaining('continue with'), findsNothing);
    c.dispose();
  });

  testWidgets('the server row cannot be edited once signed in', (tester) async {
    final committing = SignInController.at(faces['committing']!);
    await _pump(tester, committing, size: _mac);
    await tester.tap(find.text('sso-only.test'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('where does your account live?'), findsNothing);
    committing.dispose();

    final idle = SignInController.at(_on('sso-only.test'));
    await _pump(tester, idle, size: _mac);
    await tester.tap(find.text('sso-only.test'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('where does your account live?'), findsOneWidget);
    idle.dispose();
  });

  testWidgets(
    'a server with no usable flow and one with no sign-in info can both '
    'be retried',
    (tester) async {
      for (final state in [
        const SignInState(
          server: 'odd.test',
          check: ServerFound(ServerFlows()),
        ),
        _on('quiet.test'),
      ]) {
        final c = SignInController.at(state);
        await _pump(tester, c);
        expect(find.text('try again'), findsOneWidget, reason: '$state');

        await tester.tap(find.text('try again'));
        await tester.pump(const Duration(milliseconds: 50));
        expect(c.state.check, isA<ServerProbing>(), reason: '$state');

        await tester.pump(SignInController.probeDelay);
        c.dispose();
      }
    },
  );

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

  group('nothing answers during the point of no return', () {
    testWidgets(
      'the picker closes once the commit passes, and does not pop back up',
      (tester) async {
        final hs = _Scripted();
        final c = SignInController.at(
          const SignInState(
            server: 'passwords.test',
            check: ServerFound(ServerFlows(password: true)),
          ),
          homeserver: hs,
        );
        await _pump(tester, c);
        await tester.enterText(
          find.widgetWithText(TextField, 'username'),
          'chris',
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'password'),
          'hunter2',
        );
        await tester.tap(find.text('sign in'));
        await tester.pump(const Duration(milliseconds: 50));

        // Opened before the server answered: the row is still tappable at
        // this point (checkingPassword, not yet signedIn).
        await tester.tap(find.text('passwords.test'));
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('connect'), findsOneWidget);
        expect(find.text('signing in…'), findsNothing);

        hs.passwordCommitting!();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('connect'), findsNothing);
        expect(find.text('signing in…'), findsOneWidget);

        // A commit that then fails must not pop the picker back up.
        hs.passwordAnswer!.complete(const SignInFailed('nope'));
        await tester.pump();
        expect(find.text('connect'), findsNothing);
        c.dispose();
      },
    );

    testWidgets('sign out instead hides once the commit passes', (
      tester,
    ) async {
      final hs = _Scripted();
      final c = SignInController.at(
        SignInState(
          server: 'passwords.test',
          check: mockServers['passwords.test']!,
          softLogout: const SoftLogout(
            member: currentUser,
            userId: '@faore:passwords.test',
          ),
        ),
        homeserver: hs,
      );
      await _pump(tester, c);
      await tester.enterText(
        find.widgetWithText(TextField, 'password'),
        'hunter2',
      );
      await tester.tap(find.text('sign in'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('sign out instead'), findsOneWidget);

      hs.passwordCommitting!();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('sign out instead'), findsNothing);
      c.dispose();
    });

    testWidgets('back to … is disabled once the commit passes', (tester) async {
      final hs = _Scripted();
      final c = SignInController.at(
        const SignInState(
          server: 'loaf.moe',
          check: ServerFound(
            ServerFlows(
              providers: [IdentityProvider('x', 'X')],
              password: true,
            ),
          ),
        ),
        homeserver: hs,
      );
      await _pump(tester, c);
      await tester.tap(find.text('use a username and password'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(
        find.widgetWithText(TextField, 'username'),
        'chris',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'password'),
        'hunter2',
      );
      await tester.tap(find.text('sign in'));
      await tester.pump(const Duration(milliseconds: 50));

      hs.passwordCommitting!();
      await tester.pump(const Duration(milliseconds: 100));
      final button = tester.widget<LoafButton>(
        find.widgetWithText(LoafButton, 'back to X'),
      );
      expect(button.onTap, isNull);
      c.dispose();
    });
  });
}

/// A homeserver whose password answer the test hands over by hand, so a
/// test can fire the stored `onCommitting` from before the answer arrives
/// — the gap the pinned `signedIn` faces above cannot reach.
class _Scripted implements Homeserver {
  Completer<SignInOutcome>? passwordAnswer;
  void Function()? passwordCommitting;

  @override
  Future<ServerCheck> probe(String server) => Completer<ServerCheck>().future;

  @override
  Future<SignInOutcome> password(
    String server,
    String user,
    String pw, {
    void Function()? onCommitting,
  }) {
    passwordCommitting = onCommitting;
    return (passwordAnswer = Completer()).future;
  }

  @override
  Future<SignInOutcome> sso(
    String server,
    IdentityProvider provider, {
    required bool desktop,
    void Function()? onCommitting,
  }) => Completer<SignInOutcome>().future;

  @override
  void reopenSso() {}

  @override
  void cancelSso() {}

  @override
  void close() {}
}
