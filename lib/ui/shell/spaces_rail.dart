/// The leftmost rail: space avatars, then any app notices pinned at the
/// foot. Mockup only (fake data, no navigation wired beyond [onSelect]).
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../mock/fixtures.dart';
import '../platform.dart';
import '../theme/loaf_theme.dart';
import '../widgets/loaf_avatar.dart';
import 'app_notice.dart';
import 'user_bar.dart';

class SpacesRail extends StatelessWidget {
  const SpacesRail({
    super.key,
    required this.spaces,
    required this.selectedSpaceId,
    required this.onSelect,
    this.notices = const [],
    this.homeSelected = false,
    this.onHome,
    this.homeBadge = 0,
    this.homeRinging = false,
    this.onAddSpace,
    this.addSpace = true,
    this.onSpaceActions,
  });

  /// A space's menu was asked for — right-click on a computer, long press
  /// on a phone — with the space's id and where the gesture landed, for a
  /// desktop menu to open at. Left null, a space icon has no gesture for
  /// it: the backend can do neither invite nor leave.
  final void Function(String spaceId, Offset globalPosition)? onSpaceActions;

  /// The dashed "+": join, explore or create a space.
  final VoidCallback? onAddSpace;

  /// Whether to draw the add-space button at all: false while the backend
  /// cannot add a space yet.
  final bool addSpace;

  static const homeKey = ValueKey('home');

  final List<Space> spaces;
  final String selectedSpaceId;
  final ValueChanged<String> onSelect;

  /// Pinned below the scrolling spaces, just above the account panel, so
  /// they stay put however many spaces you are in.
  final List<AppNotice> notices;

  /// The loaf mark doubles as Home, where DMs live — Discord's logo does
  /// the same.
  final bool homeSelected;
  final VoidCallback? onHome;

  /// Unread DMs, including missed calls.
  final int homeBadge;

  /// A DM call is ringing at you.
  final bool homeRinging;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Container(
      width: LoafShell.railWidth,
      color: tokens.rail,
      // The rail's colour runs the full height of the screen; only its
      // contents keep clear of the status bar and home indicator.
      child: SafeArea(
        right: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            children: [
              _LoafMark(
                tokens: tokens,
                selected: homeSelected,
                onTap: onHome,
                badge: homeBadge,
                ringing: homeRinging,
              ),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (final space in spaces) ...[
                        _SpaceItem(
                          key: ValueKey('space-${space.id}'),
                          space: space,
                          selected: space.id == selectedSpaceId,
                          tokens: tokens,
                          onTap: () => onSelect(space.id),
                          onActions: onSpaceActions == null
                              ? null
                              : (position) =>
                                    onSpaceActions!(space.id, position),
                        ),
                        const SizedBox(height: 8),
                      ],
                      if (addSpace)
                        _AddSpaceButton(tokens: tokens, onTap: onAddSpace),
                      const SizedBox(height: LoafSpace.x2),
                    ],
                  ),
                ),
              ),
              for (final notice in notices)
                Padding(
                  padding: const EdgeInsets.only(top: LoafSpace.x2),
                  child: NoticeTile(notice: notice),
                ),
              // Clears the account panel floating over the bottom.
              const SizedBox(height: UserBar.clearance),
            ],
          ),
        ),
      ),
    );
  }
}

class _LoafMark extends StatelessWidget {
  const _LoafMark({
    required this.tokens,
    required this.selected,
    required this.onTap,
    required this.badge,
    required this.ringing,
  });

  final LoafTokens tokens;
  final bool selected;
  final VoidCallback? onTap;
  final int badge;
  final bool ringing;

  @override
  Widget build(BuildContext context) {
    final mark = Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tokens.onRail,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: 'l',
              style: loafDisplay(26, 600).copyWith(color: tokens.rail),
            ),
            TextSpan(
              text: '.',
              style: loafDisplay(26, 600).copyWith(color: tokens.accent),
            ),
          ],
        ),
      ),
    );
    return Tooltip(
      message: 'Home',
      child: GestureDetector(
        key: SpacesRail.homeKey,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: SizedBox(
            width: double.infinity,
            height: 48,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                Positioned(
                  left: 0,
                  child: _SelectionPill(tokens: tokens, selected: selected),
                ),
                mark,
                if (ringing)
                  Positioned(
                    right: LoafShell.railWidth / 2 - 30,
                    top: -2,
                    child: Container(
                      key: const ValueKey('home-ringing'),
                      width: 20,
                      height: 20,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: tokens.online,
                        shape: BoxShape.circle,
                        border: Border.all(color: tokens.rail, width: 2),
                      ),
                      child: const Icon(
                        LucideIcons.phone,
                        size: 10,
                        color: Colors.white,
                      ),
                    ),
                  )
                else if (badge > 0)
                  Positioned(
                    right: LoafShell.railWidth / 2 - 30,
                    top: -2,
                    child: _CountBadge(
                      count: badge,
                      tokens: tokens,
                      ringColor: tokens.rail,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The accent bar at the rail's left edge that marks where you are.
class _SelectionPill extends StatelessWidget {
  const _SelectionPill({required this.tokens, required this.selected});

  final LoafTokens tokens;
  final bool selected;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: LoafMotion.fast,
    curve: LoafMotion.ease,
    width: 4,
    height: selected ? 26 : 0,
    decoration: BoxDecoration(
      color: tokens.accent,
      borderRadius: BorderRadius.circular(2),
    ),
  );
}

class _SpaceItem extends StatelessWidget {
  const _SpaceItem({
    super.key,
    required this.space,
    required this.selected,
    required this.tokens,
    required this.onTap,
    this.onActions,
  });

  final Space space;
  final bool selected;
  final LoafTokens tokens;
  final VoidCallback onTap;

  /// Opens this space's menu at the gesture's global position. Right-click
  /// on a computer, long press on a phone — the same split as channel
  /// actions.
  final ValueChanged<Offset>? onActions;

  @override
  Widget build(BuildContext context) {
    final badgeCount = space.mentions > 0 ? space.mentions : space.unread;
    final showBadge = space.mentions > 0 || space.unread > 0;

    return GestureDetector(
      onTap: onTap,
      // Position matters only on desktop, where the menu opens at the
      // pointer; a phone's action sheet has no need of it.
      onSecondaryTapUp: isDesktop && onActions != null
          ? (details) => onActions!(details.globalPosition)
          : null,
      onLongPressStart: !isDesktop && onActions != null
          ? (details) => onActions!(details.globalPosition)
          : null,
      child: SizedBox(
        width: double.infinity,
        height: 48,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Center(
                child: _SelectionPill(tokens: tokens, selected: selected),
              ),
            ),
            Center(
              child: SizedBox(
                width: 48,
                height: 48,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    if (selected)
                      Positioned(
                        left: -4,
                        top: -4,
                        right: -4,
                        bottom: -4,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(color: tokens.sidebar, width: 2),
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                      ),
                    LoafAvatar(
                      label: space.initials,
                      color: space.color,
                      size: 48,
                      radius: 16,
                      image: space.avatar,
                      textStyle: loafBody(17, 600),
                    ),
                    if (showBadge)
                      Positioned(
                        right: -4,
                        top: -4,
                        child: _CountBadge(
                          count: badgeCount,
                          tokens: tokens,
                          ringColor: tokens.rail,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({
    required this.count,
    required this.tokens,
    this.ringColor,
  });

  final int count;
  final LoafTokens tokens;

  /// When set, draws a ring in this colour so the badge reads as cut out of
  /// the surface behind it (used on the rail; channel rows skip it).
  final Color? ringColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 18),
      height: 18,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tokens.accent,
        borderRadius: BorderRadius.circular(LoafRadius.full),
        border: ringColor == null
            ? null
            : Border.all(color: ringColor!, width: 2),
      ),
      child: Text(
        '$count',
        style: loafBody(11, 700).copyWith(color: Colors.white),
      ),
    );
  }
}

class _AddSpaceButton extends StatelessWidget {
  const _AddSpaceButton({required this.tokens, this.onTap});

  final LoafTokens tokens;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Add a space',
      child: GestureDetector(
        onTap: onTap,
        child: CustomPaint(
          painter: _DashedBorderPainter(color: tokens.borderStrong),
          child: SizedBox(
            width: 52,
            height: 52,
            child: Icon(LucideIcons.plus, color: tokens.textMuted, size: 20),
          ),
        ),
      ),
    );
  }
}

/// Dashed rounded-rect border. `lucide_icons_flutter` and Material have no
/// dashed-border primitive, so this paints one directly.
class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({required this.color});

  final Color color;

  static const _radius = LoafRadius.xl;
  static const _strokeWidth = 1.5;
  static const _dashWidth = 4.0;
  static const _gapWidth = 3.0;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(_radius),
    ).deflate(_strokeWidth / 2);
    final path = Path()..addRRect(rrect);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth;

    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = distance + _dashWidth;
        canvas.drawPath(
          metric.extractPath(distance, next.clamp(0, metric.length)),
          paint,
        );
        distance = next + _gapWidth;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color;
}
