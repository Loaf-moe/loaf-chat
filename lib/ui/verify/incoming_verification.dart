/// The other end: a verified device asked to vouch for a new sign-in.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/loaf_theme.dart';
import '../widgets/loaf_button.dart';
import 'verify_steps.dart';

class IncomingPromptStep extends StatelessWidget {
  const IncomingPromptStep({
    super.key,
    required this.device,
    required this.onYes,
    required this.onNotMe,
  });

  final String device;
  final VoidCallback onYes;
  final VoidCallback onNotMe;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const StepIcon(LucideIcons.monitorSmartphone),
      const SizedBox(height: LoafSpace.x3),
      const StepLead('is this you?', center: true),
      const SizedBox(height: LoafSpace.x1),
      // The request carries no location, so none is pretended.
      StepNote('$device · signed in just now', center: true),
      const SizedBox(height: LoafSpace.x5),
      LoafButton(label: 'yes, verify it', onTap: onYes),
      const SizedBox(height: LoafSpace.x2),
      LoafButton(
        label: "that's not me",
        onTap: onNotMe,
        emphasis: LoafButtonEmphasis.quiet,
        size: LoafButtonSize.small,
      ),
    ],
  );
}

class NotMeStep extends StatelessWidget {
  const NotMeStep({super.key, required this.onClose, this.onOpenDevices});

  final VoidCallback onClose;

  /// Where settings' devices section is, when this backend has one: the
  /// way to sign the stranger out. Without it the note stays as it was.
  final VoidCallback? onOpenDevices;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const StepIcon(LucideIcons.shieldAlert, loud: true),
      const SizedBox(height: LoafSpace.x3),
      const StepLead(
        'nothing was trusted — the request was cancelled.',
        center: true,
      ),
      const SizedBox(height: LoafSpace.x2),
      StepNote(
        onOpenDevices == null
            ? 'someone may be signed in as you. change your password, and '
                  'sign that device out from another app.'
            : 'someone may be signed in as you. change your password, and '
                  'sign that device out in settings.',
        center: true,
      ),
      const SizedBox(height: LoafSpace.x5),
      if (onOpenDevices != null) ...[
        LoafButton(label: 'open devices', onTap: onOpenDevices),
        const SizedBox(height: LoafSpace.x2),
      ],
      LoafButton(
        label: 'close',
        emphasis: LoafButtonEmphasis.outlined,
        onTap: onClose,
      ),
    ],
  );
}
