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
      () => _go(
        consumeFailure() ? VerifyStep.cancelled : VerifyStep.compareEmoji,
      ),
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
    _set(
      const VerifyState(step: VerifyStep.restoring, totalKeys: mockBackupKeys),
    );
    _restore = Timer.periodic(restoreTick, (t) {
      restored = math.min(restored + restorePerTick, mockBackupKeys);
      if (restored >= mockBackupKeys) {
        t.cancel();
        _done();
        return;
      }
      _set(
        VerifyState(
          step: VerifyStep.restoring,
          restored: restored,
          totalKeys: mockBackupKeys,
        ),
      );
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
    final busy = _state.inBrowser || _state.checking;
    if (_state.step != VerifyStep.resetAuth || busy) return;
    _set(
      VerifyState(
        step: VerifyStep.resetAuth,
        inBrowser: desktop,
        checking: !desktop,
      ),
    );
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
    _after(
      doneLinger,
      () => _set(const VerifyState(step: VerifyStep.done, closing: true)),
    );
  }

  @override
  void dispose() {
    _work?.cancel();
    _restore?.cancel();
    super.dispose();
  }
}
