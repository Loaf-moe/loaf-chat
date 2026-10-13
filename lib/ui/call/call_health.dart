/// How the call's connection is doing, as one small mark: signal bars that
/// lose height and take colour as the link gets worse.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../platform.dart';
import '../theme/loaf_theme.dart';
import '../widgets/toast.dart';
import 'calls.dart';

class CallHealthMark extends StatelessWidget {
  const CallHealthMark({
    super.key,
    required this.calls,
    this.size = 14,
    this.quiet = false,
  });

  final Calls calls;
  final double size;

  /// Whether a good link is drawn muted, for a place where the mark should
  /// only catch the eye when something is wrong.
  final bool quiet;

  /// Whether there is anything to draw: only a call that has gone live has
  /// a link to rate.
  static bool shows(Calls calls) => switch (calls.session?.phase) {
    CallPhase.live || CallPhase.reconnecting => true,
    _ => false,
  };

  @override
  Widget build(BuildContext context) {
    if (!shows(calls)) return const SizedBox.shrink();
    final tokens = LoafTokens.of(context);
    final reconnecting = calls.session?.phase == CallPhase.reconnecting;
    final (icon, color, says) = reconnecting
        ? (LucideIcons.signalZero, tokens.idle, 'reconnecting…')
        : switch (calls.quality) {
            CallQuality.good || CallQuality.unknown => (
              LucideIcons.signal,
              quiet ? tokens.textMuted : tokens.online,
              'connection is good',
            ),
            CallQuality.poor => (
              LucideIcons.signalLow,
              tokens.idle,
              'connection is weak',
            ),
            CallQuality.bad => (
              LucideIcons.signalZero,
              tokens.accent,
              'connection is very weak',
            ),
          };
    final mark = Icon(icon, size: size, color: color, semanticLabel: says);
    if (isDesktop) return Tooltip(message: says, child: mark);
    return GestureDetector(
      onTap: () => showToast(context, says),
      child: Padding(padding: const EdgeInsets.all(4), child: mark),
    );
  }
}
