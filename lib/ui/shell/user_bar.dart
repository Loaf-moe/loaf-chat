/// The account panel, spanning the bottom of both navigation columns.
///
/// The rail and the channel list each used to carry their own copy of your
/// avatar, side by side, which is one avatar too many. Discord solves this by
/// letting the account panel run across both columns as a single element, and
/// so does this: the avatar sits in the rail's column, the name and controls
/// continue into the channel list's.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../members/presence_dot.dart';
import '../mock/fixtures.dart';
import '../theme/loaf_theme.dart';

class UserBar extends StatelessWidget {
  const UserBar({
    super.key,
    this.muted = false,
    this.deafened = false,
    this.onToggleMute,
    this.onToggleDeafen,
    this.onSettings,
    this.onAvatarTap,
    this.me = currentUser,
  });

  /// You, with your current presence.
  final Member me;

  /// Opens the presence and status picker. Receives the avatar's bounds in
  /// global coordinates, so a popover can anchor to it.
  final ValueChanged<Rect>? onAvatarTap;

  final bool muted;

  /// Deafened means you hear nobody. It implies muted — talking to people you
  /// cannot hear is not a state worth offering.
  final bool deafened;

  final VoidCallback? onToggleMute;
  final VoidCallback? onToggleDeafen;
  final VoidCallback? onSettings;

  static const height = 52.0;

  /// Gap between the panel and the edges it floats over.
  static const inset = 8.0;

  /// What the columns behind it must keep clear so nothing hides underneath.
  static const clearance = height + inset * 2;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);

    return Container(
      height: height,
      // The raised surface, so the panel reads as floating over the rail and
      // the channel list rather than as a third column of its own.
      decoration: BoxDecoration(
        color: tokens.card,
        borderRadius: BorderRadius.circular(LoafRadius.xl),
        border: Border.all(color: tokens.border),
        boxShadow: tokens.shadowMd,
      ),
      child: Row(
        children: [
          // Inset by [inset], so this padding puts the avatar's centre back
          // on the rail's centreline.
          const SizedBox(width: LoafShell.railWidth / 2 - inset - 18),
          _Avatar(tokens: tokens, me: me, onTap: onAvatarTap),
          const SizedBox(width: LoafSpace.x3),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  me.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: loafBody(13, 600).copyWith(color: tokens.textStrong),
                ),
                Text(
                  currentUser.id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: loafBody(11, 400).copyWith(color: tokens.textMuted),
                ),
              ],
            ),
          ),
          _BarAction(
            icon: muted || deafened ? LucideIcons.micOff : LucideIcons.mic,
            tooltip: muted ? 'Unmute' : 'Mute',
            tinted: muted || deafened,
            onTap: onToggleMute,
          ),
          _BarAction(
            icon: deafened ? LucideIcons.headphoneOff : LucideIcons.headphones,
            tooltip: deafened ? 'Undeafen' : 'Deafen',
            tinted: deafened,
            onTap: onToggleDeafen,
          ),
          _BarAction(
            icon: LucideIcons.settings,
            tooltip: 'Settings',
            onTap: onSettings,
          ),
          const SizedBox(width: LoafSpace.x2),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.tokens, required this.me, this.onTap});

  final LoafTokens tokens;
  final Member me;
  final ValueChanged<Rect>? onTap;

  @override
  Widget build(BuildContext context) {
    final onTap = this.onTap;
    return Tooltip(
      message: 'Set your status',
      child: GestureDetector(
        key: const ValueKey('account-avatar'),
        onTap: onTap == null
            ? null
            : () {
                final box = context.findRenderObject()! as RenderBox;
                onTap(box.localToGlobal(Offset.zero) & box.size);
              },
        child: SizedBox(
          width: 36,
          height: 36,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                decoration: BoxDecoration(
                  color: me.color,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  me.initials,
                  style: loafBody(13, 600).copyWith(color: Colors.white),
                ),
              ),
              Positioned(
                right: -2,
                bottom: -2,
                child: PresenceDot(presence: me.presence, ring: tokens.card),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BarAction extends StatelessWidget {
  const _BarAction({
    required this.icon,
    required this.tooltip,
    this.tinted = false,
    this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool tinted;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onTap,
        iconSize: 18,
        color: tinted ? tokens.accent : tokens.textMuted,
        icon: Icon(icon),
      ),
    );
  }
}
