import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/mock/accounts.dart';
import 'package:loaf_native/ui/mock/mock_verifier.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/verify/verification_controller.dart';
import 'package:loaf_native/ui/verify/verifier.dart';
import 'package:loaf_native/ui/verify/verify_panel.dart';
import 'package:loaf_native/ui/verify/verify_state.dart';

/// The controller's steps over a [Verifier] that does what the mock never
/// does: stops part way, asks twice, needs a key to vouch.
void main() {
  late int trusted;
  setUp(() => trusted = 0);

  VerificationController over(
    Verifier verifier, {
    VerifyPurpose purpose = VerifyPurpose.verify,
    DeviceVerification? incoming,
  }) => VerificationController(
    purpose: purpose,
    verifier: verifier,
    onTrusted: () => trusted++,
    incoming: incoming,
    incomingDevice: 'loaf on iPhone',
  );

  group('recovery key', () {
    testWidgets('a server that does not answer is not a wrong key', (
      tester,
    ) async {
      final c = over(MockVerifier(consumeFailure: () => true))
        ..useRecoveryKey();
      c.submitKey(mockRecoveryKey);
      await tester.pump(MockVerifier.keyCheckDelay);
      expect(c.state.step, VerifyStep.recoveryKey);
      expect(c.state.failed, isTrue);
      expect(c.state.rejected, isFalse);
      expect(trusted, 0);
      c.dispose();
    });

    testWidgets('no going back while a key is checked', (tester) async {
      final c = over(MockVerifier())..useRecoveryKey();
      c.submitKey(mockRecoveryKey);
      expect(c.canGoBack, isFalse);
      c.back();
      expect(c.state.step, VerifyStep.recoveryKey);
      expect(c.state.checking, isTrue);
      await tester.pump(MockVerifier.keyCheckDelay);
      expect(c.state.step, VerifyStep.restoring);
      expect(trusted, 1);
      c.dispose();
    });
  });

  group('restoring', () {
    test('no backup key on this device: straight to done', () async {
      final v = _Verifier()..unlockAs = UnlockResult.unlocked;
      final c = over(v)..useRecoveryKey();
      c.submitKey('a key');
      await pumpEventQueue();
      expect(c.state.step, VerifyStep.restoring);
      await v.restore.close();
      await pumpEventQueue();
      expect(c.state.step, VerifyStep.done);
      expect(c.state.failed, isFalse);
      expect(trusted, 1);
      c.dispose();
    });

    test('history that stops part way still ends verified', () async {
      final v = _Verifier()..unlockAs = UnlockResult.unlocked;
      final c = over(v)..useRecoveryKey();
      c.submitKey('a key');
      await pumpEventQueue();
      v.restore.add(const RestoreProgress(1204, 3380));
      await pumpEventQueue();
      expect(c.state.restored, 1204);
      v.restore.addError(Exception('gone'));
      await pumpEventQueue();
      expect(c.state.step, VerifyStep.done);
      expect(c.state.failed, isTrue, reason: 'the rest arrive room by room');
      expect(c.state.restored, 1204);
      expect(c.state.totalKeys, 3380);
      expect(trusted, 1);
      c.dispose();
    });
  });

  group('another device', () {
    test('putting the panel away mid-wait withdraws the request', () {
      final v = _Verifier();
      final c = over(v)..useAnotherDevice();
      c.dispose();
      expect(v.device.cancelled, isTrue);
      expect(v.device.disposed, isTrue);
    });

    test('a cancel from the other side trusts nothing', () {
      final v = _Verifier();
      final c = over(v)..useAnotherDevice();
      v.device.go(DevicePhase.emoji);
      expect(c.state.step, VerifyStep.compareEmoji);
      v.device.go(DevicePhase.cancelled);
      expect(c.state.step, VerifyStep.cancelled);
      expect(trusted, 0);
      c.dispose();
    });

    test('saying yes waits for the new device, and is said once', () {
      final device = _Device();
      final c = over(
        _Verifier(),
        purpose: VerifyPurpose.incoming,
        incoming: device,
      )..acceptIncoming();
      // The real SDK waits here for the new device to start comparing.
      expect(c.state.step, VerifyStep.waitingForDevice);
      expect(c.canGoBack, isFalse);
      c.acceptIncoming();
      expect(device.accepted, 1);
      device.go(DevicePhase.emoji);
      expect(c.state.step, VerifyStep.compareEmoji);
      c.dispose();
    });

    testWidgets('the wait after yes speaks of the new sign-in', (tester) async {
      final c = VerificationController.at(
        const VerifyState(step: VerifyStep.waitingForDevice),
        purpose: VerifyPurpose.incoming,
        verifier: _Verifier(),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: loafDarkTheme(),
          home: Scaffold(body: VerifyPanel(controller: c)),
        ),
      );
      expect(find.text('waiting for the new sign-in to start'), findsOneWidget);
      expect(find.textContaining('accept the request'), findsNothing);
      c.dispose();
    });

    test('vouching asks for the recovery key when it needs one', () async {
      final device = _Device();
      final c = over(
        _Verifier(),
        purpose: VerifyPurpose.incoming,
        incoming: device,
      )..acceptIncoming();
      expect(device.accepted, 1);
      device.go(DevicePhase.needsKey);
      expect(c.state.step, VerifyStep.recoveryKey);
      expect(c.canGoBack, isFalse);

      device.unlockAs = UnlockResult.wrongKey;
      c.submitKey('nope');
      await pumpEventQueue();
      expect(c.state.rejected, isTrue);

      device.unlockAs = UnlockResult.unlocked;
      c.submitKey(mockRecoveryKey);
      await pumpEventQueue();
      expect(device.keys, ['nope', mockRecoveryKey]);
      device.go(DevicePhase.done);
      expect(c.state.step, VerifyStep.done);
      expect(trusted, 0, reason: 'vouching trusts the other device');
      c.dispose();
      expect(device.disposed, isFalse, reason: 'the session owns it');
    });
  });

  group('a new identity', () {
    test('no going back while a reset starts', () {
      final v = _Verifier();
      final c = over(v)..cantDoEither();
      c.confirmReset();
      expect(c.state.checking, isTrue);
      expect(c.canGoBack, isFalse);
      c.back();
      expect(c.state.step, VerifyStep.resetConfirm);
      expect(c.state.checking, isTrue);
      c.dispose();
    });

    test('setting up never wipes; resetting always does', () {
      final v = _Verifier();
      final c = over(v, purpose: VerifyPurpose.setUp)..createKey();
      expect(v.lastWipe, isFalse);
      c.dispose();

      final v2 = _Verifier();
      final c2 = over(v2)..cantDoEither();
      c2.confirmReset();
      expect(v2.lastWipe, isTrue);
      c2.dispose();
    });

    test(
      'an account that already has a recovery key rejects setting up',
      () async {
        final v = _RecoveryExistsVerifier();
        final c = over(v, purpose: VerifyPurpose.setUp)..createKey();
        await pumpEventQueue();
        expect(c.state.step, VerifyStep.setUpIntro);
        expect(c.state.rejected, isTrue);
        expect(c.state.failed, isFalse);
        c.dispose();
      },
    );

    testWidgets('setting up asks who you are when the server does', (
      tester,
    ) async {
      final c = over(
        MockVerifier(reauthByPassword: true),
        purpose: VerifyPurpose.setUp,
      )..createKey();
      expect(c.state.step, VerifyStep.resetAuth);
      expect(c.reauthByPassword, isTrue);
      expect(c.canGoBack, isTrue);
      c.back();
      expect(c.state.step, VerifyStep.setUpIntro);
      c.dispose();
    });

    testWidgets('closing on the new key keeps it', (tester) async {
      final c = over(
        MockVerifier(identityExists: () => false),
        purpose: VerifyPurpose.setUp,
      )..createKey();
      await tester.pump(MockVerifier.keyCheckDelay);
      expect(c.state.step, VerifyStep.showKey);
      expect(c.worksUnseen, isTrue);
      expect(c.newRecoveryKey, mockNewRecoveryKey);
      c.dispose();
    });

    testWidgets('a reset that fails changed nothing, and can be tried again', (
      tester,
    ) async {
      var fail = false;
      final c = over(
        MockVerifier(reauthByPassword: true, consumeFailure: () => fail),
      )..cantDoEither();
      c.confirmReset();
      fail = true;
      c.reauthWithPassword('hunter2');
      await tester.pump(MockVerifier.keyCheckDelay);
      expect(c.state.step, VerifyStep.resetConfirm);
      expect(c.state.failed, isTrue);
      expect(trusted, 0);

      fail = false;
      c.confirmReset();
      expect(c.state.step, VerifyStep.resetAuth);
      c.dispose();
    });

    test('a browser visit that did not finish asks again', () async {
      final v = _Verifier();
      final c = over(v)..cantDoEither();
      c.confirmReset();
      expect(c.state.checking, isTrue, reason: 'busy until the server asks');
      v.ask(AuthKind.sso, retry: false);
      expect(c.state.step, VerifyStep.resetAuth);
      expect(c.reauthByPassword, isFalse);

      c.reauthWithSso();
      expect(v.challenge.opened, 1);
      c.reopenBrowser();
      expect(v.challenge.opened, 2);
      c.browserFinished();
      expect(c.state.checking, isTrue);
      expect(c.canGoBack, isFalse);

      v.ask(AuthKind.sso, retry: true);
      expect(c.state.step, VerifyStep.resetAuth);
      expect(c.state.inBrowser, isFalse);
      expect(c.state.rejected, isTrue);

      v.made.complete('EsAB new key');
      await pumpEventQueue();
      expect(c.state.step, VerifyStep.showKey);
      expect(c.newRecoveryKey, 'EsAB new key');
      c.dispose();
    });

    testWidgets("the browser wait offers i've finished", (tester) async {
      final v = _Verifier();
      final c = over(v)..cantDoEither();
      c.confirmReset();
      v.ask(AuthKind.sso, retry: false);
      c.reauthWithSso();
      await tester.pumpWidget(
        MaterialApp(
          theme: loafDarkTheme(),
          home: Scaffold(body: VerifyPanel(controller: c)),
        ),
      );
      await tester.tap(find.text("i've finished"));
      await tester.pump();
      expect(v.challenge.finished, isTrue);
      expect(find.text('checking…'), findsOneWidget);
      c.dispose();
    });

    test('going back from the auth step cancels the challenge', () {
      final v = _Verifier();
      final c = over(v)..cantDoEither();
      c.confirmReset();
      v.ask(AuthKind.password, retry: false);
      c.back();
      expect(v.challenge.cancelled, isTrue);
      expect(c.state.step, VerifyStep.resetConfirm);
      c.dispose();
    });
  });

  group('mustStay', () {
    test('while a new identity is being made', () {
      final v = _Verifier();
      final c = over(v, purpose: VerifyPurpose.setUp)..createKey();
      expect(c.state.step, VerifyStep.setUpIntro);
      expect(c.state.checking, isTrue);
      expect(c.mustStay, isTrue);
      c.dispose();

      final v2 = _Verifier();
      final c2 = over(v2)..cantDoEither();
      c2.confirmReset();
      expect(c2.state.step, VerifyStep.resetConfirm);
      expect(c2.mustStay, isTrue);
      c2.dispose();

      final v3 = _Verifier();
      final c3 = over(v3)..cantDoEither();
      c3.confirmReset();
      v3.ask(AuthKind.password, retry: false);
      expect(c3.state.step, VerifyStep.resetAuth);
      expect(c3.mustStay, isFalse, reason: 'waiting for a password is not');
      c3.reauthWithPassword('hunter2');
      expect(c3.state.step, VerifyStep.resetAuth);
      expect(c3.state.checking, isTrue);
      expect(c3.mustStay, isTrue);
      c3.dispose();
    });

    test('while the new key is on screen unsaved', () {
      final c = VerificationController.at(
        const VerifyState(step: VerifyStep.showKey),
        verifier: _Verifier(),
      );
      expect(c.mustStay, isTrue);
      c.keyKept();
      expect(c.mustStay, isFalse);
      c.dispose();
    });

    test('false at every other step', () {
      for (final state in [
        const VerifyState(step: VerifyStep.choose),
        const VerifyState(step: VerifyStep.restoring),
        const VerifyState(step: VerifyStep.recoveryKey, checking: true),
        const VerifyState(step: VerifyStep.done),
      ]) {
        final c = VerificationController.at(state, verifier: _Verifier());
        expect(c.mustStay, isFalse, reason: state.step.toString());
        c.dispose();
      }
    });
  });
}

class _Verifier implements Verifier {
  final device = _Device();
  final restore = StreamController<RestoreProgress>();
  var unlockAs = UnlockResult.wrongKey;
  var made = Completer<String?>();
  late _Challenge challenge;
  late void Function(AuthChallenge) _onAuth;
  bool? lastWipe;

  @override
  List<String> get otherSessions => const [];

  @override
  DeviceVerification verifyWithDevice() => device;

  @override
  Future<UnlockResult> unlock(String keyOrPassphrase) async => unlockAs;

  @override
  Stream<RestoreProgress> restoreHistory() => restore.stream;

  @override
  Future<String?> createIdentity({
    required bool wipe,
    required void Function(AuthChallenge challenge) onAuth,
  }) {
    lastWipe = wipe;
    _onAuth = onAuth;
    made = Completer();
    return made.future;
  }

  void ask(AuthKind kind, {required bool retry}) =>
      _onAuth(challenge = _Challenge(kind, retry));
}

/// A fresh account whose setup finds a recovery key already there.
class _RecoveryExistsVerifier implements Verifier {
  @override
  List<String> get otherSessions => const [];

  @override
  DeviceVerification verifyWithDevice() => throw UnimplementedError();

  @override
  Future<UnlockResult> unlock(String keyOrPassphrase) async =>
      UnlockResult.wrongKey;

  @override
  Stream<RestoreProgress> restoreHistory() => const Stream.empty();

  @override
  Future<String?> createIdentity({
    required bool wipe,
    required void Function(AuthChallenge challenge) onAuth,
  }) async {
    if (!wipe) throw RecoveryExists();
    return 'EsAB new key';
  }
}

class _Challenge implements AuthChallenge {
  _Challenge(this.kind, this.retry);

  @override
  final AuthKind kind;
  @override
  final bool retry;
  var opened = 0;
  var finished = false;
  var cancelled = false;

  @override
  void password(String password) {}
  @override
  void openBrowser() => opened++;
  @override
  void browserFinished() => finished = true;
  @override
  void cancel() => cancelled = true;
}

class _Device extends ChangeNotifier implements DeviceVerification {
  DevicePhase _phase = DevicePhase.waiting;
  var accepted = 0;
  var cancelled = false;
  var disposed = false;
  var unlockAs = UnlockResult.unlocked;
  final keys = <String>[];

  void go(DevicePhase phase) {
    _phase = phase;
    notifyListeners();
  }

  @override
  DevicePhase get phase => _phase;
  @override
  List<SasEmoji> get emoji => mockSasEmoji;
  @override
  void accept() => accepted++;
  @override
  void match() {}
  @override
  void mismatch() {}
  @override
  Future<UnlockResult> unlock(String keyOrPassphrase) async {
    keys.add(keyOrPassphrase);
    return unlockAs;
  }

  @override
  void cancel() => cancelled = true;
  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}
