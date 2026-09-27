import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/mock/accounts.dart';
import 'package:loaf_native/ui/mock/mock_verifier.dart';
import 'package:loaf_native/ui/verify/verification_controller.dart';
import 'package:loaf_native/ui/verify/verify_state.dart';

/// Widget tests for the fake clock; each disposes its controller last.
void main() {
  late int trusted;
  setUp(() => trusted = 0);

  VerificationController make(
    VerifyPurpose purpose, {
    bool Function()? fail,
    bool byPassword = false,
  }) => VerificationController(
    purpose: purpose,
    verifier: MockVerifier(
      otherSessions: const ["faore's MacBook"],
      identityExists: () => purpose != VerifyPurpose.setUp,
      reauthByPassword: byPassword,
      consumeFailure: fail ?? () => false,
    ),
    onTrusted: () => trusted++,
    incoming: purpose == VerifyPurpose.incoming
        ? MockDeviceVerification()
        : null,
    incomingDevice: 'loaf on iPhone',
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
    testWidgets('waits, compares, confirms, restores, then closes itself', (
      tester,
    ) async {
      final c = make(VerifyPurpose.verify);
      c.useAnotherDevice();
      expect(c.state.step, VerifyStep.waitingForDevice);
      await tester.pump(MockVerifier.acceptDelay);
      expect(c.state.step, VerifyStep.compareEmoji);
      expect(c.emoji, hasLength(7));

      c.emojiMatch();
      expect(c.state.step, VerifyStep.waitingForOther);
      expect(trusted, 0);
      await tester.pump(MockVerifier.confirmDelay);
      expect(trusted, 1);
      // The other device sends the secrets, the backup key among them.
      expect(c.state.step, VerifyStep.restoring);
      await tester.pump(MockVerifier.restoreTick * 20);
      expect(c.state.step, VerifyStep.done);
      expect(c.state.closing, isFalse);
      await tester.pump(VerificationController.doneLinger);
      expect(c.state.closing, isTrue);
      c.dispose();
    });

    testWidgets('a mismatch trusts nothing', (tester) async {
      final c = make(VerifyPurpose.verify);
      c.useAnotherDevice();
      await tester.pump(MockVerifier.acceptDelay);
      c.emojiMismatch();
      expect(c.state.step, VerifyStep.cancelled);
      await tester.pump(MockVerifier.confirmDelay);
      expect(trusted, 0);
      c.dispose();
    });

    testWidgets('the failure lever makes the request go unanswered', (
      tester,
    ) async {
      var armed = true;
      final c = make(
        VerifyPurpose.verify,
        fail: () {
          final f = armed;
          armed = false;
          return f;
        },
      );
      c.useAnotherDevice();
      await tester.pump(MockVerifier.acceptDelay);
      expect(c.state.step, VerifyStep.cancelled);
      c.tryAgain();
      await tester.pump(MockVerifier.acceptDelay);
      expect(c.state.step, VerifyStep.compareEmoji);
      c.dispose();
    });

    testWidgets('going back while waiting drops the pending answer', (
      tester,
    ) async {
      final c = make(VerifyPurpose.verify);
      c.useAnotherDevice();
      expect(c.canGoBack, isTrue);
      c.back();
      await tester.pump(MockVerifier.acceptDelay);
      expect(c.state.step, VerifyStep.choose);
      c.dispose();
    });

    test('there is no going back mid-comparison', () {
      final c = VerificationController.at(
        const VerifyState(step: VerifyStep.compareEmoji),
        verifier: MockVerifier(),
      );
      expect(c.canGoBack, isFalse);
      c.dispose();
    });
  });

  group('recovery key', () {
    testWidgets('a wrong key is turned away', (tester) async {
      final c = make(VerifyPurpose.verify)..useRecoveryKey();
      c.submitKey('EsTc nope');
      expect(c.state.checking, isTrue);
      await tester.pump(MockVerifier.keyCheckDelay);
      expect(c.state.rejected, isTrue);
      expect(trusted, 0);
      c.dispose();
    });

    testWidgets(
      'the key unlocks however it was pasted, then history restores',
      (tester) async {
        final c = make(VerifyPurpose.verify)..useRecoveryKey();
        final messy = '  ${mockRecoveryKey.replaceAll(' ', '\n')}  \n';
        c.submitKey(messy);
        await tester.pump(MockVerifier.keyCheckDelay);
        // Trusted as soon as the key opens secret storage; history follows.
        expect(trusted, 1);
        expect(c.state.step, VerifyStep.restoring);
        expect(c.worksUnseen, isTrue);

        await tester.pump(MockVerifier.restoreTick * 3);
        expect(c.state.restored, greaterThan(0));
        expect(c.state.totalKeys, mockBackupKeys);

        await tester.pump(MockVerifier.restoreTick * 20);
        expect(c.state.step, VerifyStep.done);
        await tester.pump(VerificationController.doneLinger);
        c.dispose();
      },
    );

    testWidgets('the passphrase unlocks too', (tester) async {
      final c = make(VerifyPurpose.verify)..useRecoveryKey();
      c.submitKey(mockRecoveryPassphrase);
      await tester.pump(MockVerifier.keyCheckDelay);
      expect(c.state.step, VerifyStep.restoring);
      c.dispose();
    });

    test('back returns to the choice', () {
      final c = make(VerifyPurpose.verify)
        ..useRecoveryKey()
        ..back();
      expect(c.state.step, VerifyStep.choose);
      c.dispose();
    });
  });

  group('reset', () {
    testWidgets('a password account types its password, then saves a new key', (
      tester,
    ) async {
      final c = make(VerifyPurpose.verify, byPassword: true)..cantDoEither();
      expect(c.state.step, VerifyStep.resetConfirm);
      c.confirmReset();
      expect(c.state.step, VerifyStep.resetAuth);
      c.back();
      expect(c.state.step, VerifyStep.resetConfirm);
      c.confirmReset();

      c.reauthWithPassword(mockWrongPassword);
      await tester.pump(MockVerifier.keyCheckDelay);
      expect(c.state.rejected, isTrue);

      c.reauthWithPassword('hunter2');
      await tester.pump(MockVerifier.keyCheckDelay);
      expect(c.state.step, VerifyStep.showKey);

      c.finishSetUp();
      expect(
        c.state.step,
        VerifyStep.showKey,
        reason: 'not before the key is kept',
      );
      c.keyKept();
      c.finishSetUp();
      expect(trusted, 1);
      expect(c.state.step, VerifyStep.done);
      await tester.pump(VerificationController.doneLinger);
      c.dispose();
    });

    testWidgets('an sso account goes through the browser', (tester) async {
      final c = make(VerifyPurpose.verify)
        ..cantDoEither()
        ..confirmReset();
      c.reauthWithSso();
      expect(c.state.inBrowser, isTrue);
      c.cancelBrowser();
      expect(c.state.inBrowser, isFalse);
      c.reauthWithSso();
      // The server's page hands nothing back: the person says when.
      c.browserFinished();
      expect(c.state.checking, isTrue);
      await tester.pump(MockVerifier.keyCheckDelay);
      expect(c.state.step, VerifyStep.showKey);
      c.dispose();
    });
  });

  testWidgets('setting up: create, keep, finish', (tester) async {
    final c = make(VerifyPurpose.setUp)..createKey();
    expect(c.state.checking, isTrue);
    await tester.pump(MockVerifier.keyCheckDelay);
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
    testWidgets('vouching for the new device trusts nothing here', (
      tester,
    ) async {
      final c = make(VerifyPurpose.incoming)..acceptIncoming();
      expect(c.state.step, VerifyStep.compareEmoji);
      c.emojiMatch();
      await tester.pump(MockVerifier.confirmDelay);
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
    await tester.pump(MockVerifier.keyCheckDelay);
    c.dispose();
  });
}
