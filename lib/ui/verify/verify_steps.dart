/// The verify panel's steps, as pure widgets: values in, callbacks out. The
/// panel host picks one from the controller's state. Also the small pieces
/// every step file shares.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/loaf_theme.dart';
import '../widgets/error_note.dart';
import '../widgets/loaf_button.dart';
import 'emoji_compare.dart';
import 'recovery_key.dart';
import 'verify_state.dart';

// ── Shared pieces ─────────────────────────────────────────────────────────

class StepLead extends StatelessWidget {
  const StepLead(this.text, {super.key, this.center = false});

  final String text;
  final bool center;

  @override
  Widget build(BuildContext context) => Text(
    text,
    textAlign: center ? TextAlign.center : TextAlign.start,
    style: loafBody(15, 500).copyWith(color: LoafTokens.of(context).textBody),
  );
}

class StepNote extends StatelessWidget {
  const StepNote(this.text, {super.key, this.center = false});

  final String text;
  final bool center;

  @override
  Widget build(BuildContext context) => Text(
    text,
    textAlign: center ? TextAlign.center : TextAlign.start,
    style: loafBody(13, 400).copyWith(color: LoafTokens.of(context).textMuted),
  );
}

class StepIcon extends StatelessWidget {
  const StepIcon(this.icon, {super.key, this.loud = false});

  final IconData icon;

  /// Spends the accent: for what leaves you worse off if ignored.
  final bool loud;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Center(
      child: Icon(
        icon,
        size: 32,
        color: loud ? tokens.accent : tokens.textMuted,
      ),
    );
  }
}

class WorkingLine extends StatelessWidget {
  const WorkingLine(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 15,
          height: 15,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: tokens.accent,
          ),
        ),
        const SizedBox(width: LoafSpace.x3),
        Flexible(
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: loafBody(14, 400).copyWith(color: tokens.textMuted),
          ),
        ),
      ],
    );
  }
}

/// One way to verify: a card you pick.
class RouteTile extends StatelessWidget {
  const RouteTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final subtitle = this.subtitle;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(LoafSpace.x3),
          decoration: BoxDecoration(
            color: tokens.sunken,
            borderRadius: BorderRadius.circular(LoafRadius.lg),
            border: Border.all(color: tokens.border),
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: tokens.textMuted),
              const SizedBox(width: LoafSpace.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: loafBody(
                        15,
                        600,
                      ).copyWith(color: tokens.textStrong),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: loafBody(
                          13,
                          400,
                        ).copyWith(color: tokens.textMuted),
                      ),
                  ],
                ),
              ),
              Icon(LucideIcons.chevronRight, size: 16, color: tokens.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

/// 3380 → "3,380".
String thousands(int n) {
  final s = n.toString();
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}

// ── Steps ─────────────────────────────────────────────────────────────────

class ChooseStep extends StatelessWidget {
  const ChooseStep({
    super.key,
    required this.otherSessions,
    required this.onDevice,
    required this.onRecoveryKey,
    required this.onNeither,
  });

  final List<String> otherSessions;
  final VoidCallback onDevice;
  final VoidCallback onRecoveryKey;
  final VoidCallback onNeither;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const StepLead(
        "prove it's you so this device can read your encrypted history.",
      ),
      const SizedBox(height: LoafSpace.x4),
      // Offered only where it leads somewhere, like the password link: with
      // no other session to ask, the request would wait forever.
      if (otherSessions.isNotEmpty) ...[
        RouteTile(
          icon: LucideIcons.monitorSmartphone,
          title: 'use another device',
          subtitle: otherSessions.join(' · '),
          onTap: onDevice,
        ),
        const SizedBox(height: LoafSpace.x2),
      ],
      RouteTile(
        icon: LucideIcons.keyRound,
        title: 'use your recovery key',
        subtitle: 'or its passphrase',
        onTap: onRecoveryKey,
      ),
      const SizedBox(height: LoafSpace.x4),
      LoafButton(
        label: "can't do either?",
        onTap: onNeither,
        emphasis: LoafButtonEmphasis.quiet,
        size: LoafButtonSize.small,
      ),
    ],
  );
}

class WaitingStep extends StatelessWidget {
  const WaitingStep({super.key, required this.label, this.onCancel});

  final String label;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: LoafSpace.x4),
      WorkingLine(label),
      if (onCancel != null) ...[
        const SizedBox(height: LoafSpace.x5),
        LoafButton(
          label: 'cancel',
          onTap: onCancel,
          emphasis: LoafButtonEmphasis.quiet,
          size: LoafButtonSize.small,
        ),
      ],
    ],
  );
}

class CompareStep extends StatelessWidget {
  const CompareStep({
    super.key,
    required this.emoji,
    required this.prompt,
    required this.onMatch,
    required this.onMismatch,
  });

  final List<SasEmoji> emoji;
  final String prompt;
  final VoidCallback onMatch;
  final VoidCallback onMismatch;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      StepLead(prompt, center: true),
      const SizedBox(height: LoafSpace.x5),
      EmojiCompare(emoji: emoji),
      const SizedBox(height: LoafSpace.x6),
      LoafButton(label: 'they match', onTap: onMatch),
      const SizedBox(height: LoafSpace.x2),
      LoafButton(
        label: "they don't match",
        onTap: onMismatch,
        emphasis: LoafButtonEmphasis.quiet,
        size: LoafButtonSize.small,
      ),
    ],
  );
}

class CancelledStep extends StatelessWidget {
  const CancelledStep({super.key, this.onTryAgain, required this.onClose});

  final VoidCallback? onTryAgain;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const StepIcon(LucideIcons.triangleAlert),
      const SizedBox(height: LoafSpace.x3),
      const StepLead(
        'nothing was trusted — the request was cancelled.',
        center: true,
      ),
      const SizedBox(height: LoafSpace.x5),
      if (onTryAgain != null) ...[
        LoafButton(
          label: 'try again',
          icon: LucideIcons.rotateCcw,
          emphasis: LoafButtonEmphasis.outlined,
          onTap: onTryAgain,
        ),
        const SizedBox(height: LoafSpace.x2),
      ],
      LoafButton(
        label: 'close',
        onTap: onClose,
        emphasis: LoafButtonEmphasis.quiet,
        size: LoafButtonSize.small,
      ),
    ],
  );
}

class RecoveryStep extends StatelessWidget {
  const RecoveryStep({
    super.key,
    required this.controller,
    required this.checking,
    required this.rejected,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final bool checking;
  final bool rejected;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const StepLead(
        'enter your recovery key, or the passphrase that protects it.',
      ),
      const SizedBox(height: LoafSpace.x4),
      RecoveryKeyField(controller: controller, onSubmit: onSubmit),
      if (rejected) ...[
        const SizedBox(height: LoafSpace.x3),
        const ErrorNote(message: "that didn't unlock anything"),
      ],
      const SizedBox(height: LoafSpace.x4),
      LoafButton(
        label: checking ? 'checking…' : 'unlock',
        onTap: checking ? null : onSubmit,
      ),
    ],
  );
}

class RestoringStep extends StatelessWidget {
  const RestoringStep({super.key, required this.restored, required this.total});

  final int restored;
  final int total;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const StepLead('restoring history'),
        const SizedBox(height: LoafSpace.x2),
        StepNote('restored ${thousands(restored)} of ${thousands(total)} keys'),
        const SizedBox(height: LoafSpace.x3),
        ClipRRect(
          borderRadius: BorderRadius.circular(LoafRadius.full),
          child: LinearProgressIndicator(
            value: total == 0 ? null : restored / total,
            minHeight: 6,
            color: tokens.accent,
            backgroundColor: tokens.sunken,
          ),
        ),
        const SizedBox(height: LoafSpace.x3),
        const StepNote('you can close this — it carries on.'),
      ],
    );
  }
}

class DoneStep extends StatelessWidget {
  const DoneStep({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: LoafSpace.x4),
        Icon(LucideIcons.circleCheckBig, size: 40, color: tokens.online),
        const SizedBox(height: LoafSpace.x3),
        Text(
          message,
          textAlign: TextAlign.center,
          style: loafBody(17, 600).copyWith(color: tokens.textStrong),
        ),
        const SizedBox(height: LoafSpace.x4),
      ],
    );
  }
}
