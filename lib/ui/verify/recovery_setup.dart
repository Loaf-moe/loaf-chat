/// A fresh identity's recovery key: made, shown once, and kept before the
/// flow will finish, since losing it is the one mistake nothing recovers.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/loaf_theme.dart';
import '../widgets/error_note.dart';
import '../widgets/loaf_button.dart';
import 'recovery_key.dart';
import 'verify_steps.dart';

class SetUpIntroStep extends StatelessWidget {
  const SetUpIntroStep({
    super.key,
    required this.onCreate,
    this.busy = false,
    this.rejected = false,
    this.onReset,
    this.failure,
  });

  final VoidCallback onCreate;

  /// The identity is being made; it can't be stopped part way.
  final bool busy;

  /// This account already keeps a recovery key: setting up refused, rather
  /// than replace it by accident.
  final bool rejected;

  /// Starts over instead, once [rejected].
  final VoidCallback? onReset;
  final String? failure;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const StepIcon(LucideIcons.keyRound),
      const SizedBox(height: LoafSpace.x3),
      const StepLead(
        'if you ever lose every device, your recovery key is how you get your encrypted history back.',
      ),
      const SizedBox(height: LoafSpace.x2),
      const StepNote(
        "keep it somewhere safe that isn't this device — a password manager is ideal.",
      ),
      if (rejected) ...[
        const SizedBox(height: LoafSpace.x3),
        const ErrorNote(
          message:
              'this account already has a recovery key · use it on a '
              'device that has it, or reset to start over',
        ),
      ],
      if (failure case final failure?) ...[
        const SizedBox(height: LoafSpace.x3),
        ErrorNote(message: failure),
      ],
      const SizedBox(height: LoafSpace.x5),
      // Refused, creating would only be refused again: reset is the one
      // way forward, so it takes the filled button.
      if (!rejected)
        LoafButton(
          label: busy ? 'creating…' : 'create my recovery key',
          onTap: busy ? null : onCreate,
        )
      else if (onReset case final reset?)
        LoafButton(label: 'reset', onTap: reset),
    ],
  );
}

class ShowKeyStep extends StatelessWidget {
  const ShowKeyStep({
    super.key,
    required this.recoveryKey,
    required this.saved,
    required this.onCopy,
    required this.onSave,
    required this.onDone,
  });

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
      const StepLead(
        "this is your recovery key. save it now — loaf can't show it again.",
      ),
      const SizedBox(height: LoafSpace.x4),
      RecoveryKeyDisplay(recoveryKey: recoveryKey),
      const SizedBox(height: LoafSpace.x3),
      Row(
        children: [
          Expanded(
            child: LoafButton(
              label: 'copy',
              icon: LucideIcons.copy,
              emphasis: LoafButtonEmphasis.outlined,
              size: LoafButtonSize.small,
              onTap: onCopy,
            ),
          ),
          const SizedBox(width: LoafSpace.x2),
          Expanded(
            child: LoafButton(
              label: 'save as file',
              icon: LucideIcons.download,
              emphasis: LoafButtonEmphasis.outlined,
              size: LoafButtonSize.small,
              onTap: onSave,
            ),
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
