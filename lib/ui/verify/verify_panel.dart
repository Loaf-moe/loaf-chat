/// The panel every verification flow runs in: a sheet on a phone, a dialog
/// on a computer. It draws the controller's current step, offers back where
/// the step allows it, and closes itself once done has been read.
library;

import 'dart:async';

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
import 'save_key.dart';
import 'verification_controller.dart';
import 'verify_state.dart';
import 'verify_steps.dart';

/// Completes with true once the flow finished and closed itself, or null if
/// it was put away early.
Future<bool?> showVerifyPanel(
  BuildContext context,
  VerificationController controller,
) => showAdaptivePanel<bool>(
  context,
  child: VerifyPanel(controller: controller),
  // The sheet's drag-to-close pops straight past the panel's own
  // PopScope, and an unsaved new key must not be put away.
  enableDrag: false,
);

class VerifyPanel extends StatefulWidget {
  const VerifyPanel({
    super.key,
    required this.controller,
    this.saveKey = saveRecoveryKey,
  });

  final VerificationController controller;
  final KeySaver saveKey;

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

  void _copy() {
    // Counted as kept at the tap: waiting on the platform clipboard would
    // leave "i've saved it" lagging behind the button that enables it.
    unawaited(Clipboard.setData(ClipboardData(text: _c.newRecoveryKey)));
    showToast(context, 'copied');
    _c.keyKept();
  }

  Future<void> _save() async {
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    bool kept;
    try {
      kept = await widget.saveKey(_c.newRecoveryKey, origin: origin);
    } on Exception {
      if (mounted) showToast(context, "couldn't save it · copy it instead");
      return;
    }
    if (!kept || !mounted) return;
    showToast(context, isDesktop ? 'saved' : 'shared');
    _c.keyKept();
  }

  String _title(VerifyStep step) {
    final incoming = _c.purpose == VerifyPurpose.incoming;
    final settingUp = _c.purpose == VerifyPurpose.setUp;
    return switch (step) {
      VerifyStep.choose => 'verify this session',
      VerifyStep.incomingPrompt || VerifyStep.notMe => 'new sign-in',
      VerifyStep.waitingForDevice ||
      VerifyStep.compareEmoji ||
      VerifyStep.waitingForOther ||
      VerifyStep.cancelled => incoming ? 'new sign-in' : 'use another device',
      VerifyStep.recoveryKey || VerifyStep.restoring =>
        incoming ? 'new sign-in' : 'use your recovery key',
      VerifyStep.resetConfirm => 'reset your identity',
      VerifyStep.resetAuth =>
        settingUp ? 'set up recovery' : 'reset your identity',
      VerifyStep.setUpIntro || VerifyStep.showKey =>
        settingUp ? 'set up recovery' : 'save your new recovery key',
      VerifyStep.done => '',
    };
  }

  /// Nothing reached the server, so nothing changed.
  String? get _unreachable =>
      _c.state.failed ? "couldn't reach ${_c.server} · try again" : null;

  String? get _cutShort {
    final s = _c.state;
    if (!s.failed) return null;
    // Stopped before the backup was even counted: no numbers to give.
    if (s.restored == 0 && s.totalKeys == 0) {
      return 'history will arrive as you open rooms';
    }
    return 'restored ${thousands(s.restored)} of ${thousands(s.totalKeys)} · '
        'the rest arrive as you open rooms';
  }

  Widget _body(VerifyState s) => switch (s.step) {
    VerifyStep.choose => ChooseStep(
      otherSessions: _c.otherSessions,
      onDevice: _c.useAnotherDevice,
      onRecoveryKey: _c.useRecoveryKey,
      onNeither: _c.cantDoEither,
    ),
    VerifyStep.waitingForDevice => WaitingStep(
      label: _c.purpose == VerifyPurpose.incoming
          ? 'waiting for the new sign-in to start'
          : "accept the request on another device where you're signed in",
      onCancel: _c.canGoBack ? _c.back : null,
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
    VerifyStep.waitingForOther => const WaitingStep(
      label: 'waiting for the other device to confirm',
    ),
    VerifyStep.cancelled => CancelledStep(
      onTryAgain: _c.purpose == VerifyPurpose.verify ? _c.tryAgain : null,
      onClose: _close,
    ),
    VerifyStep.notMe => NotMeStep(onClose: _close),
    VerifyStep.recoveryKey => RecoveryStep(
      controller: _key,
      checking: s.checking,
      rejected: s.rejected,
      failure: _unreachable,
      lead: _c.purpose == VerifyPurpose.incoming
          ? 'to vouch for it, this device needs your recovery key or passphrase.'
          : 'enter your recovery key, or the passphrase that protects it.',
      onSubmit: () => _c.submitKey(_key.text),
    ),
    VerifyStep.restoring => RestoringStep(
      restored: s.restored,
      total: s.totalKeys,
    ),
    VerifyStep.resetConfirm => ResetConfirmStep(
      onReset: _c.confirmReset,
      onCancel: _c.back,
      busy: s.checking,
      failure: _unreachable,
      incomplete: s.incomplete,
    ),
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
      onFinished: _c.browserFinished,
      onCancelBrowser: _c.cancelBrowser,
      lead: _c.purpose == VerifyPurpose.setUp
          ? "confirm it's you before your new identity goes up."
          : "confirm it's you before the old identity goes.",
    ),
    VerifyStep.setUpIntro => SetUpIntroStep(
      onCreate: _c.createKey,
      busy: s.checking,
      rejected: s.rejected,
      onReset: _c.cantDoEither,
      failure: _unreachable,
    ),
    VerifyStep.showKey => ShowKeyStep(
      recoveryKey: _c.newRecoveryKey,
      saved: s.keySaved,
      onCopy: _copy,
      onSave: () => unawaited(_save()),
      onDone: _c.finishSetUp,
    ),
    VerifyStep.done => DoneStep(message: _c.doneMessage, note: _cutShort),
  };

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final s = _c.state;
        return PopScope(
          canPop: !_c.mustStay,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  LoafSpace.x3,
                  isDesktop ? LoafSpace.x4 : 0,
                  LoafSpace.x5,
                  LoafSpace.x3,
                ),
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
                              child: Icon(
                                LucideIcons.chevronLeft,
                                size: 20,
                                color: tokens.textMuted,
                              ),
                            ),
                          ),
                        ),
                      )
                    else
                      // Lines the title up with the body's x5 inset.
                      const SizedBox(width: LoafSpace.x1),
                    const SizedBox(width: LoafSpace.x1),
                    Expanded(
                      child: Text(
                        _title(s.step),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: loafBody(
                          17,
                          600,
                        ).copyWith(color: tokens.textStrong),
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(
                    LoafSpace.x5,
                    0,
                    LoafSpace.x5,
                    LoafSpace.x5,
                  ),
                  child: _body(s),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
