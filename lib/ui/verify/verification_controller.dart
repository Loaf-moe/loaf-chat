/// A verification panel's steps: which one shows, and what each of its
/// buttons does. The work itself is the [Verifier]'s, so the same steps run
/// on the mock's timers and on the SDK. See "Verifying a session" in the
/// design spec.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'verifier.dart';
import 'verify_state.dart';

class VerificationController extends ChangeNotifier {
  VerificationController({
    required this.purpose,
    required this.verifier,
    required this.onTrusted,
    this.incoming,
    this.incomingDevice,
    this.server = 'your server',
  }) : _state = VerifyState(
         step: switch (purpose) {
           VerifyPurpose.verify => VerifyStep.choose,
           VerifyPurpose.setUp => VerifyStep.setUpIntro,
           VerifyPurpose.incoming => VerifyStep.incomingPrompt,
         },
       ) {
    _follow(incoming);
  }

  /// Starts in [state] with nothing in flight, so a test can pin any step.
  @visibleForTesting
  VerificationController.at(
    VerifyState state, {
    this.purpose = VerifyPurpose.verify,
    required this.verifier,
    VoidCallback? onTrusted,
    this.incoming,
    this.incomingDevice,
    this.server = 'your server',
  }) : onTrusted = onTrusted ?? _nothing,
       _state = state {
    _follow(incoming);
  }

  static void _nothing() {}

  static const doneLinger = Duration(milliseconds: 1200);

  final VerifyPurpose purpose;
  final Verifier verifier;

  /// Called once this device is trusted: signed by a verified identity, or
  /// owner of a new one. Never for [VerifyPurpose.incoming], which vouches
  /// for another device instead.
  final VoidCallback onTrusted;

  /// Incoming only: the request, and the device asking to be verified.
  final DeviceVerification? incoming;
  final String? incomingDevice;

  /// The homeserver's name, for saying it did not answer.
  final String server;

  List<String> get otherSessions => verifier.otherSessions;

  List<SasEmoji> get emoji => _device?.emoji ?? const [];

  /// The key a new identity made, kept for as long as this controller is,
  /// so closing the panel before saving it never loses it.
  String? _newKey;
  String get newRecoveryKey => _newKey ?? '';

  /// How the server asked who you are, while it is asking.
  AuthChallenge? _challenge;
  bool get reauthByPassword => _challenge?.kind == AuthKind.password;

  String get doneMessage => switch (purpose) {
    VerifyPurpose.verify => 'this session is verified',
    VerifyPurpose.setUp => 'recovery is set up',
    VerifyPurpose.incoming => '${incomingDevice ?? 'that device'} is verified',
  };

  VerifyState _state;
  VerifyState get state => _state;

  /// The emoji verification in hand: the incoming one, or one this end
  /// started.
  DeviceVerification? _device;

  /// Bumped whenever the flow moves on its own, so an answer to something
  /// since abandoned is dropped rather than jumping a step.
  var _turn = 0;
  Timer? _linger;
  StreamSubscription<RestoreProgress>? _restore;
  var _disposed = false;

  void _set(VerifyState s) {
    if (_disposed) return;
    _state = s;
    notifyListeners();
  }

  void _go(VerifyStep step) => _set(VerifyState(step: step));

  bool get canGoBack => switch (_state.step) {
    VerifyStep.waitingForDevice ||
    VerifyStep.cancelled => purpose == VerifyPurpose.verify,
    VerifyStep.recoveryKey || VerifyStep.resetConfirm =>
      purpose == VerifyPurpose.verify && !_state.checking,
    VerifyStep.resetAuth => !_state.inBrowser && !_state.checking,
    _ => false,
  };

  /// Whether closing the panel should leave this running: history keeps
  /// restoring with nobody watching, and a new key waits to be saved.
  bool get worksUnseen =>
      _state.step == VerifyStep.restoring || _state.step == VerifyStep.showKey;

  void back() {
    if (!canGoBack) return;
    _turn++;
    switch (_state.step) {
      case VerifyStep.resetAuth:
        _challenge?.cancel();
        _challenge = null;
        _go(
          purpose == VerifyPurpose.setUp
              ? VerifyStep.setUpIntro
              : VerifyStep.resetConfirm,
        );
      case VerifyStep.waitingForDevice:
        _dropDevice(cancel: true);
        _go(VerifyStep.choose);
      default:
        _go(VerifyStep.choose);
    }
  }

  // ── Another device ─────────────────────────────────────────────────────

  void useAnotherDevice() {
    _dropDevice(cancel: true);
    _go(VerifyStep.waitingForDevice);
    _follow(verifier.verifyWithDevice());
  }

  void tryAgain() => useAnotherDevice();

  void _follow(DeviceVerification? device) {
    if (device == null) return;
    _device = device;
    device.addListener(_onDevice);
  }

  void _dropDevice({required bool cancel}) {
    final d = _device;
    if (d == null || identical(d, incoming)) return;
    d.removeListener(_onDevice);
    if (cancel && d.phase != DevicePhase.done) d.cancel();
    d.dispose();
    _device = null;
  }

  void _onDevice() {
    final d = _device;
    if (d == null) return;
    switch (d.phase) {
      case DevicePhase.waiting:
        break;
      case DevicePhase.emoji:
        _go(VerifyStep.compareEmoji);
      case DevicePhase.waitingForOther:
        _go(VerifyStep.waitingForOther);
      case DevicePhase.needsKey:
        _go(VerifyStep.recoveryKey);
      case DevicePhase.cancelled:
        if (_state.step != VerifyStep.notMe) _go(VerifyStep.cancelled);
      case DevicePhase.done:
        if (purpose == VerifyPurpose.incoming) {
          _done();
        } else {
          // Signed by the other device; its secrets follow, and with them,
          // if the account keeps a key backup, the history.
          onTrusted();
          _startRestore();
        }
    }
  }

  void emojiMatch() {
    if (_state.step == VerifyStep.compareEmoji) _device?.match();
  }

  void emojiMismatch() {
    if (_state.step == VerifyStep.compareEmoji) _device?.mismatch();
  }

  void acceptIncoming() {
    if (_state.step != VerifyStep.incomingPrompt) return;
    // Waits for the new device to start comparing, and can't be said twice.
    _go(VerifyStep.waitingForDevice);
    incoming?.accept();
  }

  void rejectIncoming() {
    if (_state.step != VerifyStep.incomingPrompt) return;
    _go(VerifyStep.notMe);
    incoming?.cancel();
  }

  // ── Recovery key ───────────────────────────────────────────────────────

  void useRecoveryKey() => _go(VerifyStep.recoveryKey);

  void submitKey(String text) {
    if (_state.step != VerifyStep.recoveryKey || _state.checking) return;
    if (text.trim().isEmpty) return;
    _set(const VerifyState(step: VerifyStep.recoveryKey, checking: true));
    final turn = ++_turn;
    // Vouching for another device asks for the key mid-way; the device
    // carries on by itself once it opens.
    final vouching = _device?.phase == DevicePhase.needsKey;
    final answer = vouching ? _device!.unlock(text) : verifier.unlock(text);
    unawaited(
      answer.then((result) {
        if (turn != _turn || _disposed) return;
        switch (result) {
          case UnlockResult.wrongKey:
            _set(
              const VerifyState(step: VerifyStep.recoveryKey, rejected: true),
            );
          case UnlockResult.unreachable:
            _set(const VerifyState(step: VerifyStep.recoveryKey, failed: true));
          case UnlockResult.unlocked:
            if (vouching) return;
            // Secret storage opened: the device signs itself now, and
            // history follows from key backup.
            onTrusted();
            _startRestore();
        }
      }),
    );
  }

  void _startRestore() {
    _set(const VerifyState(step: VerifyStep.restoring));
    var last = const RestoreProgress(0, 0);
    _restore = verifier.restoreHistory().listen(
      (p) {
        last = p;
        _set(
          VerifyState(
            step: VerifyStep.restoring,
            restored: p.restored,
            totalKeys: p.total,
          ),
        );
      },
      // Already trusted: whatever did not come back arrives room by room.
      onError: (Object _) =>
          _done(cutShort: true, restored: last.restored, total: last.total),
      onDone: _done,
    );
  }

  // ── A new identity ─────────────────────────────────────────────────────

  void cantDoEither() => _go(VerifyStep.resetConfirm);

  void confirmReset() {
    if (_state.step != VerifyStep.resetConfirm || _state.checking) return;
    _set(const VerifyState(step: VerifyStep.resetConfirm, checking: true));
    _create(from: VerifyStep.resetConfirm);
  }

  void createKey() {
    if (_state.step != VerifyStep.setUpIntro || _state.checking) return;
    _set(const VerifyState(step: VerifyStep.setUpIntro, checking: true));
    _create(from: VerifyStep.setUpIntro);
  }

  void _create({required VerifyStep from}) {
    final turn = ++_turn;
    bool current() => turn == _turn && !_disposed;
    unawaited(
      verifier
          .createIdentity(
            onAuth: (challenge) {
              if (!current()) return challenge.cancel();
              _challenge = challenge;
              _set(
                VerifyState(
                  step: VerifyStep.resetAuth,
                  rejected: challenge.retry,
                ),
              );
            },
          )
          .then(
            (key) {
              if (!current() || key == null) return;
              _challenge = null;
              _newKey = key;
              _go(VerifyStep.showKey);
            },
            onError: (Object _) {
              if (!current()) return;
              _challenge = null;
              _set(VerifyState(step: from, failed: true));
            },
          ),
    );
  }

  void reauthWithPassword(String password) {
    final c = _challenge;
    if (_state.step != VerifyStep.resetAuth || _state.checking) return;
    if (c == null || password.isEmpty) return;
    _set(const VerifyState(step: VerifyStep.resetAuth, checking: true));
    c.password(password);
  }

  void reauthWithSso() {
    final c = _challenge;
    final busy = _state.inBrowser || _state.checking;
    if (_state.step != VerifyStep.resetAuth || busy || c == null) return;
    c.openBrowser();
    _set(const VerifyState(step: VerifyStep.resetAuth, inBrowser: true));
  }

  void reopenBrowser() {
    if (_state.inBrowser && !_state.checking) _challenge?.openBrowser();
  }

  /// The browser page is done with; the server is asked to carry on.
  void browserFinished() {
    if (!_state.inBrowser || _state.checking) return;
    _set(
      const VerifyState(
        step: VerifyStep.resetAuth,
        inBrowser: true,
        checking: true,
      ),
    );
    _challenge?.browserFinished();
  }

  void cancelBrowser() {
    if (!_state.inBrowser || _state.checking) return;
    _go(VerifyStep.resetAuth);
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

  void _done({bool cutShort = false, int restored = 0, int total = 0}) {
    final done = VerifyState(
      step: VerifyStep.done,
      failed: cutShort,
      restored: restored,
      totalKeys: total,
    );
    _set(done);
    _linger?.cancel();
    _linger = Timer(
      doneLinger,
      () => _set(
        VerifyState(
          step: VerifyStep.done,
          failed: cutShort,
          restored: restored,
          totalKeys: total,
          closing: true,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _turn++;
    _linger?.cancel();
    unawaited(_restore?.cancel());
    _challenge?.cancel();
    incoming?.removeListener(_onDevice);
    _dropDevice(cancel: true);
    super.dispose();
  }
}
