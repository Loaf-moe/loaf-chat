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
    this.busy = false,
    this.failure,
    this.incomplete = false,
  });

  final VoidCallback onReset;
  final VoidCallback onCancel;

  /// Waiting for the server to ask who you are.
  final bool busy;
  final String? failure;

  /// The last try put a new identity up but didn't finish it: said in place
  /// of [failure], since here something did change.
  final bool incomplete;

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
      if (incomplete) ...[
        const SizedBox(height: LoafSpace.x3),
        const ErrorNote(
          message:
              "your new identity went up but didn't finish, so it has no "
              'recovery key yet · reset again to get one',
        ),
      ] else if (failure case final failure?) ...[
        const SizedBox(height: LoafSpace.x3),
        ErrorNote(message: failure),
      ],
      const SizedBox(height: LoafSpace.x5),
      // The filled button is the accent: this is its honest use.
      LoafButton(
        label: busy ? 'starting…' : 'reset my identity',
        onTap: busy ? null : onReset,
      ),
      const SizedBox(height: LoafSpace.x2),
      LoafButton(
        label: 'cancel',
        onTap: busy ? null : onCancel,
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
    this.lead = "confirm it's you before the old identity goes.",
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
  final String lead;

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
        StepLead(lead),
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
          // Lit only once there's a password to check: blank input is
          // ignored by the controller, so a drawn-enabled button here would
          // do nothing.
          ListenableBuilder(
            listenable: password,
            builder: (context, _) => LoafButton(
              label: checking ? 'checking…' : 'continue',
              onTap: checking || password.text.trim().isEmpty
                  ? null
                  : onPassword,
            ),
          ),
        ] else ...[
          if (rejected) ...[
            const ErrorNote(message: "that didn't finish · try again"),
            const SizedBox(height: LoafSpace.x3),
          ],
          LoafButton(
            label: 'continue with $providerName',
            icon: LucideIcons.logIn,
            onTap: onSso,
          ),
        ],
      ],
    );
  }
}
