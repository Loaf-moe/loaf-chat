/// Banners for things the app needs to tell you about the app itself —
/// an available update, a session waiting to be verified.
///
/// Two tones, because these are not equally urgent. [BannerTone.quiet] is a
/// plain raised card: news you can act on whenever. [BannerTone.attention]
/// spends the brand's one red moment, and is reserved for things that leave
/// you worse off if ignored — which, for a Matrix client, means encryption.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/loaf_theme.dart';

enum BannerTone { quiet, attention }

/// Below this the action moves under the text instead of beside it.
const _stackBelow = 420.0;

class LoafBanner extends StatelessWidget {
  const LoafBanner({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.actionLabel,
    this.onAction,
    this.onDismiss,
    this.tone = BannerTone.quiet,
  });

  /// An update is ready to install.
  factory LoafBanner.update({
    required String version,
    VoidCallback? onAction,
    VoidCallback? onDismiss,
  }) => LoafBanner(
    icon: LucideIcons.arrowDownToLine,
    title: 'loaf $version is ready',
    body: 'restart to pick up the new version',
    actionLabel: 'restart',
    onAction: onAction,
    onDismiss: onDismiss,
  );

  /// This session is not verified, so it cannot read encrypted history.
  /// Deliberately has no dismiss: ignoring it silently loses messages.
  factory LoafBanner.verify({VoidCallback? onAction}) => LoafBanner(
    icon: LucideIcons.shieldAlert,
    title: 'verify this session',
    body: "until you do, encrypted messages sent before now stay unreadable",
    actionLabel: 'verify',
    tone: BannerTone.attention,
    onAction: onAction,
  );

  final IconData icon;
  final String title;
  final String body;
  final String actionLabel;
  final VoidCallback? onAction;

  /// Omitted when the banner should not be dismissible.
  final VoidCallback? onDismiss;
  final BannerTone tone;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final loud = tone == BannerTone.attention;

    final fill = loud ? tokens.accentSoft : tokens.card;
    final edge = loud ? tokens.accent : tokens.border;
    final mark = loud ? tokens.accent : tokens.textMuted;

    return Container(
      margin: const EdgeInsets.fromLTRB(
        LoafSpace.x4,
        LoafSpace.x3,
        LoafSpace.x4,
        0,
      ),
      padding: const EdgeInsets.all(LoafSpace.x3),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(LoafRadius.lg),
        border: Border.all(color: edge),
        boxShadow: loud ? null : tokens.shadowSm,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stacked = constraints.maxWidth < _stackBelow;
          final text = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: loafBody(13, 600).copyWith(color: tokens.textStrong),
              ),
              const SizedBox(height: 2),
              Text(
                body,
                style: loafBody(13, 400).copyWith(color: tokens.textMuted),
              ),
            ],
          );

          final actions = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Action(label: actionLabel, loud: loud, onTap: onAction),
              if (onDismiss != null)
                IconButton(
                  onPressed: onDismiss,
                  iconSize: 16,
                  visualDensity: VisualDensity.compact,
                  color: tokens.textMuted,
                  icon: const Icon(LucideIcons.x),
                ),
            ],
          );

          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(icon, size: 18, color: mark),
              ),
              const SizedBox(width: LoafSpace.x3),
              Expanded(
                child: stacked
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          text,
                          const SizedBox(height: LoafSpace.x2),
                          actions,
                        ],
                      )
                    : Row(
                        children: [
                          Expanded(child: text),
                          const SizedBox(width: LoafSpace.x3),
                          actions,
                        ],
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Both tones get a real button; they differ in emphasis, not in kind. A
/// filled pill for the loud one, an outlined pill for the quiet one — mixing
/// a button with a text link reads as an inconsistency rather than as a
/// hierarchy.
class _Action extends StatelessWidget {
  const _Action({required this.label, required this.loud, this.onTap});

  final String label;
  final bool loud;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x4),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: loud ? tokens.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(LoafRadius.full),
          border: Border.all(color: loud ? tokens.accent : tokens.borderStrong),
        ),
        child: Text(
          label,
          style: loafBody(
            13,
            600,
          ).copyWith(color: loud ? tokens.textOnAccent : tokens.textStrong),
        ),
      ),
    );
  }
}
