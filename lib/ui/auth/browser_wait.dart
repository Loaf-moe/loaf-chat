/// Desktop SSO: the real browser has the conversation, and this only waits
/// for it to hand back. The verify panel's reset reuses it for
/// re-authentication.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/loaf_theme.dart';
import '../widgets/loaf_button.dart';

class BrowserWait extends StatelessWidget {
  const BrowserWait({
    super.key,
    required this.name,
    required this.onReopen,
    required this.onCancel,
  });

  /// Who the browser is signing in with: the identity provider's name.
  final String name;
  final VoidCallback onReopen;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(LucideIcons.externalLink, size: 28, color: tokens.textMuted),
        const SizedBox(height: LoafSpace.x3),
        Text(
          'finish in your browser',
          textAlign: TextAlign.center,
          style: loafDisplay(22, 600).copyWith(color: tokens.textStrong),
        ),
        const SizedBox(height: LoafSpace.x2),
        Text(
          "we opened $name in your browser. come back once you're signed in.",
          textAlign: TextAlign.center,
          style: loafBody(15, 400).copyWith(color: tokens.textMuted),
        ),
        const SizedBox(height: LoafSpace.x6),
        LoafButton(
          label: 'open it again',
          icon: LucideIcons.externalLink,
          emphasis: LoafButtonEmphasis.outlined,
          onTap: onReopen,
        ),
        const SizedBox(height: LoafSpace.x3),
        LoafButton(
          label: 'cancel',
          onTap: onCancel,
          emphasis: LoafButtonEmphasis.quiet,
          size: LoafButtonSize.small,
        ),
      ],
    );
  }
}
