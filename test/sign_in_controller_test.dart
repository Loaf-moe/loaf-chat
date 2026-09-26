import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/auth/sign_in_controller.dart';
import 'package:loaf_native/ui/auth/sign_in_state.dart';
import 'package:loaf_native/ui/mock/accounts.dart';

/// Widget tests only for the fake clock. Each disposes its controller as its
/// last line: the pending-timer check runs before tear-downs.
void main() {
  late int signedIn;
  setUp(() => signedIn = 0);

  SignInController make({
    String server = 'loaf.moe',
    bool desktop = false,
    bool Function()? fail,
  }) => SignInController(
    server: server,
    onSignedIn: () => signedIn++,
    consumeFailure: fail ?? () => false,
    desktop: desktop,
  );

  SignInController at(
    String server, {
    bool desktop = false,
    bool Function()? fail,
  }) => SignInController.at(
    SignInState(server: server, check: mockServers[server]!),
    onSignedIn: () => signedIn++,
    consumeFailure: fail ?? () => false,
    desktop: desktop,
  );

  group('discovery', () {
    testWidgets('opens probing, then shows what the server offers', (
      tester,
    ) async {
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
      expect(
        (c.state.check as ServerFailed).problem,
        ServerProblem.unreachable,
      );

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

    testWidgets('connect keeps the name typed, from a url or an id', (
      tester,
    ) async {
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

    testWidgets('connecting elsewhere mid-wait drops the old sign-in', (
      tester,
    ) async {
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

    testWidgets('the failure lever turns a right password away once', (
      tester,
    ) async {
      var armed = true;
      final c = at(
        'passwords.test',
        fail: () {
          final f = armed;
          armed = false;
          return f;
        },
      );
      c.signInWithPassword('chris', 'hunter2');
      await tester.pump(SignInController.passwordDelay);
      expect(c.state.wrongPassword, isTrue);
      c.signInWithPassword('chris', 'hunter2');
      await tester.pump(SignInController.passwordDelay);
      expect(signedIn, 1);
      c.dispose();
    });

    testWidgets('too many tries counts down before it checks again', (
      tester,
    ) async {
      final c = at('passwords.test');
      for (var i = 0; i < SignInController.triesBeforeLimit; i++) {
        c.signInWithPassword('chris', mockWrongPassword);
        await tester.pump(SignInController.passwordDelay);
      }
      expect(c.state.retryIn, SignInController.rateLimit);
      expect(c.state.wrongPassword, isFalse);

      c.signInWithPassword('chris', 'hunter2');
      expect(
        c.state.activity,
        SignInActivity.idle,
        reason: 'refused while limited',
      );

      await tester.pump(const Duration(seconds: 1));
      expect(c.state.retryIn, const Duration(seconds: 29));
      await tester.pump(const Duration(seconds: 29));
      expect(c.state.retryIn, isNull);
      c.dispose();
    });
  });

  testWidgets('a right password says so before handing over', (tester) async {
    // The button stays busy through the hand-over instead of flashing back.
    late SignInController c;
    SignInActivity? seen;
    c = SignInController.at(
      SignInState(
        server: 'passwords.test',
        check: mockServers['passwords.test']!,
      ),
      onSignedIn: () => seen = c.state.activity,
    );
    c.signInWithPassword('chris', 'hunter2');
    await tester.pump(SignInController.passwordDelay);
    expect(seen, SignInActivity.signedIn);
    c.dispose();
  });

  group('review fixes', () {
    testWidgets('a rate limit stays with the server that set it', (
      tester,
    ) async {
      final c = at('passwords.test');
      for (var i = 0; i < SignInController.triesBeforeLimit; i++) {
        c.signInWithPassword('chris', mockWrongPassword);
        await tester.pump(SignInController.passwordDelay);
      }
      expect(c.state.retryIn, isNotNull);

      c.connect('many-doors.test');
      await tester.pump(SignInController.probeDelay);
      await tester.pump(const Duration(seconds: 2));
      expect(c.state.retryIn, isNull, reason: 'no stale countdown');

      // The count of wrong tries starts over too.
      c.signInWithPassword('chris', mockWrongPassword);
      await tester.pump(SignInController.passwordDelay);
      expect(c.state.wrongPassword, isTrue);
      expect(c.state.retryIn, isNull);
      c.dispose();
    });

    testWidgets(
      "submitting while the id's server is looked up signs in there",
      (tester) async {
        final c = at('passwords.test');
        c.usernameChanged('@chris:loaf.moe');
        await tester.pump(SignInController.repointDebounce);
        expect(c.state.repointing, 'loaf.moe');

        c.signInWithPassword('@chris:loaf.moe', 'hunter2');
        await tester.pump(SignInController.probeDelay);
        expect(c.state.server, 'loaf.moe');
        expect(c.state.repointing, isNull, reason: 'no stuck spinner');
        await tester.pump(SignInController.passwordDelay);
        expect(signedIn, 1);
        c.dispose();
      },
    );

    testWidgets('a fill-and-submit inside the debounce is not lost', (
      tester,
    ) async {
      // What a password manager does: username, password, submit, at once.
      final c = at('passwords.test');
      c.usernameChanged('@chris:loaf.moe');
      c.signInWithPassword('@chris:loaf.moe', 'hunter2');
      // The id's server is looked up now rather than after the pause.
      expect(c.state.repointing, 'loaf.moe');
      await tester.pump(SignInController.probeDelay);
      await tester.pump(SignInController.passwordDelay);
      expect(signedIn, 1);
      expect(c.state.server, 'loaf.moe');
      c.dispose();
    });

    testWidgets(
      "a queued sign-in is dropped if the id's server takes no password",
      (tester) async {
        final c = at('passwords.test');
        c.usernameChanged('@chris:sso-only.test');
        c.signInWithPassword('@chris:sso-only.test', 'hunter2');
        await tester.pump(SignInController.probeDelay);
        await tester.pump(SignInController.passwordDelay);
        expect(signedIn, 0);
        expect(c.state.server, 'sso-only.test');
        expect(c.state.activity, SignInActivity.idle);
        c.dispose();
      },
    );
  });
}
