/// Starting over: new cross-signing keys when every device and the recovery
/// key are gone. Explains its cost first, then re-authenticates.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/browser_wait.dart';
import '../theme/loaf_theme.dart';
import '../widgets/error_note.dart';
import '../widgets/loaf_button.dart';
import '../widgets/loaf_field.dart';
import 'verify_steps.dart';

class ResetConfirmStep extends StatelessWidget {
  const ResetConfirmStep({
    super.key,
    required this.onReset,
    required this.onCancel,
  });

  final VoidCallback onReset;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const StepLead(
        "if you've lost every device and your recovery key, you can start over with a new identity.",
      ),
      const SizedBox(height: LoafSpace.x3),
      const _Cost('people you talk to will see that your identity changed'),
      const SizedBox(height: LoafSpace.x2),
      const _Cost("encrypted history you can't reach now stays unreadable"),
      const SizedBox(height: LoafSpace.x5),
      // The filled button is the accent: this is its honest use.
      LoafButton(label: 'reset my identity', onTap: onReset),
      const SizedBox(height: LoafSpace.x2),
      LoafButton(
        label: 'cancel',
        onTap: onCancel,
        emphasis: LoafButtonEmphasis.quiet,
        size: LoafButtonSize.small,
      ),
    ],
  );
}

class _Cost extends StatelessWidget {
  const _Cost(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(
            LucideIcons.triangleAlert,
            size: 14,
            color: tokens.textMuted,
          ),
        ),
        const SizedBox(width: LoafSpace.x2),
        Expanded(
          child: Text(
            text,
            style: loafBody(14, 400).copyWith(color: tokens.textBody),
          ),
        ),
      ],
    );
  }
}

class ResetAuthStep extends StatelessWidget {
  const ResetAuthStep({
    super.key,
    required this.byPassword,
    required this.password,
    required this.checking,
    required this.rejected,
    required this.inBrowser,
    required this.providerName,
    required this.onPassword,
    required this.onSso,
    required this.onReopen,
    this.onFinished,
    required this.onCancelBrowser,
  });

  final bool byPassword;
  final TextEditingController password;
  final bool checking;
  final bool rejected;
  final bool inBrowser;
  final String providerName;
  final VoidCallback onPassword;
  final VoidCallback onSso;
  final VoidCallback onReopen;

  /// The browser page is done with, where it cannot hand back itself.
  final VoidCallback? onFinished;
  final VoidCallback onCancelBrowser;

  @override
  Widget build(BuildContext context) {
    if (inBrowser) {
      return BrowserWait(
        name: providerName,
        onReopen: onReopen,
        onFinished: onFinished,
        finishing: checking,
        onCancel: onCancelBrowser,
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const StepLead("confirm it's you before the old identity goes."),
        const SizedBox(height: LoafSpace.x4),
        if (byPassword) ...[
          LoafField(
            controller: password,
            hint: 'password',
            icon: LucideIcons.keyRound,
            obscure: true,
            autofocus: true,
            autofillHints: const [AutofillHints.password],
            textInputAction: TextInputAction.done,
            onSubmit: onPassword,
          ),
          if (rejected) ...[
            const SizedBox(height: LoafSpace.x3),
            const ErrorNote(message: "that password didn't match"),
          ],
          const SizedBox(height: LoafSpace.x3),
          LoafButton(
            label: checking ? 'checking…' : 'continue',
            onTap: checking ? null : onPassword,
          ),
        ] else if (checking)
          const WorkingLine('signing in…')
        else
          LoafButton(
            label: 'continue with $providerName',
            icon: LucideIcons.logIn,
            onTap: onSso,
          ),
      ],
    );
  }
}
