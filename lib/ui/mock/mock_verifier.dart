/// The account's encryption, played on timers against mock/accounts.dart —
/// mockup only. Stands in for the SDK's key verification, secret storage
/// and key backup.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../verify/verifier.dart';
import '../verify/verify_state.dart';
import 'accounts.dart';

class MockVerifier implements Verifier {
  MockVerifier({
    this.otherSessions = const [],
    this.identityExists = _yes,
    this.reauthByPassword = false,
    this.consumeFailure = _never,
    Set<String>? verifiedPeople,
    this.peopleWithoutIdentity = const {},
  }) : verifiedPeople = verifiedPeople ?? {};

  static bool _yes() => true;
  static bool _never() => false;

  static const acceptDelay = Duration(seconds: 2);
  static const confirmDelay = Duration(milliseconds: 1200);
  static const keyCheckDelay = Duration(milliseconds: 600);
  static const restoreTick = Duration(milliseconds: 120);
  static const restorePerTick = 169;

  @override
  final List<String> otherSessions;

  /// Whether a new identity replaces one, which is when the mock server asks
  /// who you are first.
  final bool Function() identityExists;

  /// How the mock server asks: a password, or the browser.
  final bool reauthByPassword;

  /// The debug "fail the next connection" lever.
  final bool Function() consumeFailure;

  /// The people your identity has signed: grows as verifications finish.
  final Set<String> verifiedPeople;

  /// The people who never set up encryption.
  final Set<String> peopleWithoutIdentity;

  @override
  DeviceVerification verifyWithDevice() =>
      MockDeviceVerification(consumeFailure: consumeFailure).._request();

  @override
  PersonTrust personTrust(String userId) {
    if (peopleWithoutIdentity.contains(userId)) return PersonTrust.noIdentity;
    return verifiedPeople.contains(userId)
        ? PersonTrust.verified
        : PersonTrust.unverified;
  }

  @override
  DeviceVerification verifyPerson(String userId) => MockDeviceVerification(
    consumeFailure: consumeFailure,
    onDone: () => verifiedPeople.add(userId),
  ).._request();

  @override
  Future<UnlockResult> unlock(String keyOrPassphrase) async {
    await Future<void>.delayed(keyCheckDelay);
    if (consumeFailure()) return UnlockResult.unreachable;
    return unlocksRecovery(keyOrPassphrase)
        ? UnlockResult.unlocked
        : UnlockResult.wrongKey;
  }

  @override
  Stream<RestoreProgress> restoreHistory() {
    Timer? ticks;
    late final StreamController<RestoreProgress> out;
    out = StreamController(
      onListen: () {
        var restored = 0;
        ticks = Timer.periodic(restoreTick, (t) {
          restored = math.min(restored + restorePerTick, mockBackupKeys);
          if (restored < mockBackupKeys) {
            out.add(RestoreProgress(restored, mockBackupKeys));
            return;
          }
          t.cancel();
          unawaited(out.close());
        });
      },
      onCancel: () => ticks?.cancel(),
    );
    return out.stream;
  }

  @override
  Future<String?> createIdentity({
    required bool wipe,
    required void Function(AuthChallenge challenge) onAuth,
  }) async {
    if (!identityExists()) {
      await Future<void>.delayed(keyCheckDelay);
      return _made();
    }
    final made = Completer<String?>();
    onAuth(_MockChallenge(this, made, onAuth, retry: false));
    return made.future;
  }

  String _made() {
    if (consumeFailure()) throw Exception('the mock server went away');
    return mockNewRecoveryKey;
  }
}

class _MockChallenge implements AuthChallenge {
  _MockChallenge(
    this._verifier,
    this._made,
    this._onAuth, {
    required this.retry,
  });

  final MockVerifier _verifier;
  final Completer<String?> _made;
  final void Function(AuthChallenge) _onAuth;

  @override
  final bool retry;

  @override
  AuthKind get kind =>
      _verifier.reauthByPassword ? AuthKind.password : AuthKind.sso;

  void _answer({required bool ok}) {
    unawaited(
      Future<void>.delayed(MockVerifier.keyCheckDelay, () {
        if (_made.isCompleted) return;
        if (!ok) {
          _onAuth(_MockChallenge(_verifier, _made, _onAuth, retry: true));
          return;
        }
        try {
          _made.complete(_verifier._made());
        } on Exception catch (e) {
          _made.completeError(e);
        }
      }),
    );
  }

  @override
  void password(String password) => _answer(ok: password != mockWrongPassword);

  /// There is no browser in the mockup.
  @override
  void openBrowser() {}

  @override
  void browserFinished() => _answer(ok: true);

  @override
  void cancel() {
    if (!_made.isCompleted) _made.complete(null);
  }
}

/// One emoji verification, played out on timers. Outgoing ones answer after
/// [MockVerifier.acceptDelay]; incoming ones wait for [accept].
class MockDeviceVerification extends ChangeNotifier
    implements DeviceVerification {
  MockDeviceVerification({
    this.consumeFailure = MockVerifier._never,
    this.onDone,
  });

  final bool Function() consumeFailure;

  /// Called as it finishes, before listeners hear it.
  final VoidCallback? onDone;

  DevicePhase _phase = DevicePhase.waiting;
  Timer? _work;

  @override
  DevicePhase get phase => _phase;

  @override
  List<SasEmoji> get emoji => mockSasEmoji;

  void _go(DevicePhase phase) {
    _work?.cancel();
    _phase = phase;
    notifyListeners();
  }

  void _request() {
    // No answer and a refusal look the same from here: nothing was trusted.
    _work = Timer(
      MockVerifier.acceptDelay,
      () => _go(consumeFailure() ? DevicePhase.cancelled : DevicePhase.emoji),
    );
  }

  @override
  void accept() {
    if (_phase == DevicePhase.waiting) _go(DevicePhase.emoji);
  }

  @override
  void match() {
    if (_phase != DevicePhase.emoji) return;
    _go(DevicePhase.waitingForOther);
    _work = Timer(MockVerifier.confirmDelay, () {
      onDone?.call();
      _go(DevicePhase.done);
    });
  }

  @override
  void mismatch() {
    if (_phase == DevicePhase.emoji) _go(DevicePhase.cancelled);
  }

  /// The mockup's devices always hold their own keys.
  @override
  Future<UnlockResult> unlock(String keyOrPassphrase) async =>
      UnlockResult.unlocked;

  @override
  void cancel() {
    if (_phase != DevicePhase.done) _go(DevicePhase.cancelled);
  }

  @override
  void dispose() {
    _work?.cancel();
    super.dispose();
  }
}
