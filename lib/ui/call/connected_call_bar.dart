/// The persistent bar shown while you are connected to a voice channel.
///
/// This is what keeps voice feeling always-on rather than call-shaped: it
/// survives navigating to other channels and other spaces, so leaving a
/// conversation does not leave the room.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../mock/fixtures.dart';
import '../theme/loaf_theme.dart';

class ConnectedCallBar extends StatelessWidget {
  const ConnectedCallBar({
    super.key,
    required this.channel,
    required this.spaceName,
    required this.muted,
    required this.onToggleMute,
    required this.onDisconnect,
    this.onExpand,
  });

  final Channel channel;
  final String spaceName;
  final bool muted;
  final VoidCallback onToggleMute;
  final VoidCallback onDisconnect;
  final VoidCallback? onExpand;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);

    return Material(
      color: tokens.card,
      child: InkWell(
        onTap: onExpand,
        child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x3),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: tokens.border)),
          ),
          child: Row(
            children: [
              Icon(LucideIcons.radio, size: 18, color: tokens.online),
              const SizedBox(width: LoafSpace.x3),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Voice connected',
                      style: loafBody(11, 600).copyWith(color: tokens.online),
                    ),
                    Text(
                      '${channel.name} · $spaceName',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: loafBody(
                        13,
                        500,
                      ).copyWith(color: tokens.textStrong),
                    ),
                  ],
                ),
              ),
              if (channel.occupants.isNotEmpty) ...[
                _OccupantStack(occupants: channel.occupants),
                const SizedBox(width: LoafSpace.x2),
              ],
              _CallAction(
                icon: muted ? LucideIcons.micOff : LucideIcons.mic,
                tooltip: muted ? 'Unmute' : 'Mute',
                onTap: onToggleMute,
                foreground: muted ? tokens.textOnAccent : tokens.textBody,
                background: muted ? tokens.accent : null,
              ),
              const SizedBox(width: LoafSpace.x1),
              _CallAction(
                icon: LucideIcons.phoneOff,
                tooltip: 'Disconnect',
                onTap: onDisconnect,
                foreground: tokens.accent,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Overlapping avatars of who else is in the channel, capped so a busy
/// channel does not push the controls off a phone screen.
class _OccupantStack extends StatelessWidget {
  const _OccupantStack({required this.occupants});

  final List<Member> occupants;

  static const _max = 3;
  static const _size = 24.0;
  static const _overlap = 8.0;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final shown = occupants.take(_max).toList();
    final extra = occupants.length - shown.length;
    final count = shown.length + (extra > 0 ? 1 : 0);

    return SizedBox(
      width: _size + (count - 1) * (_size - _overlap),
      height: _size,
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: i * (_size - _overlap),
              child: _Bubble(
                background: shown[i].color,
                ring: tokens.card,
                child: Text(
                  shown[i].initials,
                  style: loafBody(10, 600).copyWith(color: Colors.white),
                ),
              ),
            ),
          if (extra > 0)
            Positioned(
              left: shown.length * (_size - _overlap),
              child: _Bubble(
                background: tokens.sunken,
                ring: tokens.card,
                child: Text(
                  '+$extra',
                  style: loafBody(10, 600).copyWith(color: tokens.textMuted),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.background,
    required this.ring,
    required this.child,
  });

  final Color background;
  final Color ring;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    width: _OccupantStack._size,
    height: _OccupantStack._size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: background,
      shape: BoxShape.circle,
      border: Border.all(color: ring, width: 2),
    ),
    child: child,
  );
}

class _CallAction extends StatefulWidget {
  const _CallAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    required this.foreground,
    this.background,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color foreground;
  final Color? background;

  @override
  State<_CallAction> createState() => _CallActionState();
}

class _CallActionState extends State<_CallAction> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);

    return Tooltip(
      message: widget.tooltip,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? LoafMotion.iconPressScale : 1,
          duration: LoafMotion.fast,
          curve: LoafMotion.ease,
          child: Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: widget.background ?? tokens.sunken,
              borderRadius: BorderRadius.circular(LoafRadius.md),
            ),
            child: Icon(widget.icon, size: 18, color: widget.foreground),
          ),
        ),
      ),
    );
  }
}
