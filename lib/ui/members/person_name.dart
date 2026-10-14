/// A name in its role's colour, with a badge after it for a bridge puppet.
/// Not used by the reply quote (11px, no room) or the call tile (no puppet
/// ever joins a call).
library;

import 'package:flutter/material.dart';

import '../model/models.dart';
import '../platform.dart';
import '../theme/loaf_theme.dart';
import 'role_colors.dart';

class PersonName extends StatelessWidget {
  const PersonName(
    this.member, {
    super.key,
    required this.size,
    required this.weight,
    this.maxLines,
    this.overflow,
  });

  final Member member;
  final double size;
  final int weight;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final bridge = member.bridge;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            member.name,
            maxLines: maxLines,
            overflow: overflow,
            style: loafBody(
              size,
              weight,
            ).copyWith(color: tokens.nameColor(member.role)),
          ),
        ),
        if (bridge != null) ...[
          const SizedBox(width: LoafSpace.x1),
          _BridgeBadge(bridge: bridge, color: tokens.textMuted),
        ],
      ],
    );
  }
}

class _BridgeBadge extends StatelessWidget {
  const _BridgeBadge({required this.bridge, required this.color});

  final Bridge bridge;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final (asset, label) = switch (bridge) {
      Bridge.discord => ('assets/icons/discord.png', 'from Discord'),
    };
    final badge = Image.asset(
      asset,
      width: 14,
      height: 14,
      color: color,
      semanticLabel: label,
    );
    // Hover only; a phone has the semantics label.
    if (!isDesktop) return badge;
    return Tooltip(message: label, child: badge);
  }
}
