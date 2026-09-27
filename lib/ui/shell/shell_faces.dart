/// What the conversation pane shows when there is no conversation to show:
/// the account's first sync still arriving, or nothing in it at all.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../call/call_view.dart';
import '../theme/loaf_theme.dart';

/// The first sync, still coming. A spinner while the server has not
/// answered, which says nothing about how long; a bar once its answer is
/// being worked through, room by room. Nothing to press: it cannot be
/// stopped, and it retries on its own.
class SyncingFace extends StatelessWidget {
  const SyncingFace({super.key, this.progress, this.onOpenNavigation});

  /// 0 to 1, or null while waiting on the server.
  final double? progress;

  /// The phone layout's way to the drawer, and the account panel in it.
  final VoidCallback? onOpenNavigation;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final progress = this.progress;
    return _Face(
      onOpenNavigation: onOpenNavigation,
      child: progress == null
          ? const CircularProgressIndicator.adaptive()
          : SizedBox(
              width: 200,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(LoafRadius.full),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 6,
                  color: tokens.accent,
                  backgroundColor: tokens.sunken,
                ),
              ),
            ),
    );
  }
}

/// Signed in, synced, and in no rooms at all.
class NothingHereFace extends StatelessWidget {
  const NothingHereFace({super.key, this.onOpenNavigation});

  final VoidCallback? onOpenNavigation;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return _Face(
      onOpenNavigation: onOpenNavigation,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.messagesSquare, size: 28, color: tokens.textMuted),
          const SizedBox(height: LoafSpace.x3),
          Text(
            'nothing here yet',
            style: loafBody(13, 400).copyWith(color: tokens.textMuted),
          ),
        ],
      ),
    );
  }
}

/// The page, a header bar only where there is a drawer to open, and
/// [child] in the middle.
class _Face extends StatelessWidget {
  const _Face({required this.child, this.onOpenNavigation});

  final Widget child;
  final VoidCallback? onOpenNavigation;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final onOpenNavigation = this.onOpenNavigation;
    return ColoredBox(
      color: tokens.page,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (onOpenNavigation != null)
              Container(
                height: 56,
                padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x3),
                alignment: Alignment.centerLeft,
                child: TopBarButton(
                  icon: LucideIcons.menu,
                  tooltip: 'Channels',
                  onTap: onOpenNavigation,
                ),
              ),
            Expanded(child: Center(child: child)),
          ],
        ),
      ),
    );
  }
}
