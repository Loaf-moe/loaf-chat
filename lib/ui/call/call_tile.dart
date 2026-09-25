/// One person in a call: their video, or their avatar when the camera is off.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../mock/fixtures.dart';
import '../platform.dart';
import '../theme/loaf_theme.dart';
import 'call_controller.dart';

/// What a tile draws. Built from a [CallParticipant], or from your own
/// state for your own tile.
@immutable
class TileInfo {
  const TileInfo(
    this.member, {
    this.you = false,
    this.muted = false,
    this.deafened = false,
    this.camera = false,
    this.screen = false,
    this.speaking = false,
    this.ring,
  });

  TileInfo.of(CallParticipant p)
    : this(
        p.member,
        muted: p.muted,
        deafened: p.deafened,
        camera: p.camera,
        screen: p.screen,
        speaking: p.speaking,
        ring: p.ring,
      );

  final Member member;
  final bool you;
  final bool muted;
  final bool deafened;
  final bool camera;
  final bool screen;
  final bool speaking;
  final RingState? ring;

  String get id => member.id;

  /// Rung but not here: still ringing, declined, or never answered.
  bool get waiting => ring != null && ring != RingState.joined;
}

class CallTile extends StatefulWidget {
  CallTile({
    required this.info,
    this.nameColor,
    this.dimmed = false,
    this.pinned = false,
    this.small = false,
    this.onTogglePin,
    this.onMenu,
    this.onFlipCamera,
  }) : super(key: ValueKey('tile-${info.id}'));

  final TileInfo info;

  /// Power level in voice channels. Null in DMs, which have no roles.
  final Color? nameColor;

  /// Not connected yet, or reconnecting: shown, but not live.
  final bool dimmed;
  final bool pinned;

  /// Filmstrip and compact-panel size: smaller avatar and label.
  final bool small;

  final VoidCallback? onTogglePin;

  /// Opens the tile's actions: at the pointer on desktop, as a sheet on a
  /// phone (position null).
  final void Function(Offset? position)? onMenu;

  /// Only on your own tile, on a phone, while your camera is on.
  final VoidCallback? onFlipCamera;

  @override
  State<CallTile> createState() => _CallTileState();
}

class _CallTileState extends State<CallTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final info = widget.info;
    final ring = info.ring;
    final faded =
        widget.dimmed ||
        info.ring == RingState.declined ||
        info.ring == RingState.noAnswer;

    Widget body = ClipRRect(
      borderRadius: BorderRadius.circular(LoafRadius.xl),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (info.screen)
            _ScreenPlaceholder(member: info.member)
          else if (info.camera)
            _VideoPlaceholder(member: info.member, mirrored: info.you)
          else
            ColoredBox(
              color: tokens.sunken,
              child: Center(
                child: ring == RingState.ringing
                    ? Pulse(child: _avatar(info.member))
                    : _avatar(info.member),
              ),
            ),
          Positioned(
            left: LoafSpace.x2,
            bottom: LoafSpace.x2,
            right: LoafSpace.x2,
            child: Align(
              alignment: Alignment.bottomLeft,
              child: _NameChip(
                info: info,
                color: widget.nameColor ?? tokens.textStrong,
                small: widget.small,
              ),
            ),
          ),
          if (widget.pinned || (_hovered && widget.onTogglePin != null))
            Positioned(
              top: LoafSpace.x2,
              right: LoafSpace.x2,
              child: _CornerButton(
                icon: widget.pinned ? LucideIcons.pinOff : LucideIcons.pin,
                tooltip: widget.pinned ? 'Unpin' : 'Pin',
                onTap: widget.onTogglePin,
              ),
            ),
          if (widget.onFlipCamera != null)
            Positioned(
              top: LoafSpace.x2,
              left: LoafSpace.x2,
              child: _CornerButton(
                icon: LucideIcons.switchCamera,
                tooltip: 'Flip camera',
                onTap: widget.onFlipCamera,
              ),
            ),
        ],
      ),
    );

    body = AnimatedContainer(
      duration: LoafMotion.fast,
      curve: LoafMotion.ease,
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(LoafRadius.xl),
        border: Border.all(
          color: info.speaking && !faded ? tokens.online : Colors.transparent,
          width: 3,
        ),
      ),
      child: AnimatedOpacity(
        duration: LoafMotion.normal,
        opacity: faded ? 0.45 : 1,
        child: body,
      ),
    );

    // Touch: tap pins, long press opens actions. Pointer: hover shows the
    // pin, right-click opens actions.
    final onMenu = widget.onMenu;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: isDesktop ? null : widget.onTogglePin,
        onLongPress: !isDesktop && onMenu != null
            ? () {
                HapticFeedback.mediumImpact();
                onMenu(null);
              }
            : null,
        onSecondaryTapUp: isDesktop && onMenu != null
            ? (d) => onMenu(d.globalPosition)
            : null,
        child: body,
      ),
    );
  }

  Widget _avatar(Member member) => LayoutBuilder(
    builder: (context, constraints) {
      final size = (constraints.biggest.shortestSide * 0.42).clamp(28.0, 96.0);
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: member.color, shape: BoxShape.circle),
        child: Text(
          member.initials,
          style: loafBody(size * 0.36, 600).copyWith(color: Colors.white),
        ),
      );
    },
  );
}

/// Name, mute and deafen marks, and any ring state, on a scrim so they read
/// over video.
class _NameChip extends StatelessWidget {
  const _NameChip({
    required this.info,
    required this.color,
    required this.small,
  });

  final TileInfo info;
  final Color color;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final state = switch (info.ring) {
      RingState.ringing => 'ringing…',
      RingState.declined => 'declined',
      RingState.noAnswer => 'no answer',
      _ => null,
    };
    final size = small ? 11.0 : 13.0;
    final iconSize = small ? 12.0 : 14.0;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: small ? 6 : LoafSpace.x2,
        vertical: small ? 2 : LoafSpace.x1,
      ),
      decoration: BoxDecoration(
        color: tokens.rail.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(LoafRadius.md),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              info.you ? '${info.member.name} (you)' : info.member.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: loafBody(size, 600).copyWith(color: color),
            ),
          ),
          if (state != null) ...[
            const SizedBox(width: 6),
            Text(
              state,
              style: loafBody(size, 400).copyWith(color: tokens.onRail),
            ),
          ],
          if (info.deafened) ...[
            const SizedBox(width: 4),
            Icon(
              LucideIcons.headphoneOff,
              size: iconSize,
              color: tokens.accent,
            ),
          ] else if (info.muted) ...[
            const SizedBox(width: 4),
            Icon(LucideIcons.micOff, size: iconSize, color: tokens.accent),
          ],
        ],
      ),
    );
  }
}

class _CornerButton extends StatelessWidget {
  const _CornerButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: tokens.rail.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(LoafRadius.md),
          ),
          child: Icon(icon, size: 16, color: tokens.onRail),
        ),
      ),
    );
  }
}

/// Stands in for a video track: the person's colour, darkened, with a
/// camera glyph. [mirrored] flips it the way a self-view is flipped.
class _VideoPlaceholder extends StatelessWidget {
  const _VideoPlaceholder({required this.member, required this.mirrored});

  final Member member;
  final bool mirrored;

  @override
  Widget build(BuildContext context) {
    return Transform.flip(
      flipX: mirrored,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.lerp(member.color, Colors.black, 0.35)!,
              Color.lerp(member.color, Colors.black, 0.7)!,
            ],
          ),
        ),
        child: Center(
          child: Icon(
            LucideIcons.video,
            size: 28,
            color: Colors.white.withValues(alpha: 0.35),
          ),
        ),
      ),
    );
  }
}

/// Stands in for a screen share.
class _ScreenPlaceholder extends StatelessWidget {
  const _ScreenPlaceholder({required this.member});

  final Member member;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return ColoredBox(
      color: tokens.rail,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.monitor, size: 32, color: tokens.onRail),
            const SizedBox(height: LoafSpace.x2),
            Text(
              "${member.name.split(' ').first}'s screen",
              style: loafBody(13, 500).copyWith(color: tokens.onRail),
            ),
          ],
        ),
      ),
    );
  }
}

/// A gentle breathing scale, for anything that is ringing.
class Pulse extends StatefulWidget {
  const Pulse({super.key, required this.child});

  final Widget child;

  @override
  State<Pulse> createState() => _PulseState();
}

class _PulseState extends State<Pulse> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ScaleTransition(
    scale: Tween(
      begin: 0.92,
      end: 1.06,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut)),
    child: widget.child,
  );
}
