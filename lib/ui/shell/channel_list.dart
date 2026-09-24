/// The middle column: a space's categories and channels, mockup only.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../mock/fixtures.dart';
import '../platform.dart';
import '../theme/loaf_theme.dart';
import 'channel_actions.dart';
import 'user_bar.dart';

class ChannelList extends StatefulWidget {
  const ChannelList({
    super.key,
    required this.space,
    required this.selectedChannelId,
    required this.onSelect,
    this.onAction,
  });

  final Space space;
  final String selectedChannelId;
  final ValueChanged<String> onSelect;

  /// Receives what was picked from a channel's actions (long press on a
  /// phone, right-click on a computer). Left null, channels have no menu.
  final void Function(String channelId, ChannelAction action)? onAction;

  @override
  State<ChannelList> createState() => _ChannelListState();
}

class _ChannelListState extends State<ChannelList> {
  final Set<String> _collapsed = {};

  void _toggle(String category) {
    setState(() {
      if (!_collapsed.add(category)) _collapsed.remove(category);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: tokens.sidebar,
        border: Border(right: BorderSide(color: tokens.border, width: 1)),
      ),
      // Background and divider run edge to edge; the rail beside us already
      // owns the left inset, so only the top and bottom apply here.
      child: SafeArea(
        left: false,
        child: Column(
          children: [
            _Header(space: widget.space, tokens: tokens),
            _SearchField(tokens: tokens),
            Expanded(
              child: ListView(
                // Clears the account panel floating over the bottom.
                padding: const EdgeInsets.only(bottom: UserBar.clearance),
                children: [
                  for (final category in widget.space.categories)
                    _CategorySection(
                      category: category,
                      collapsed: _collapsed.contains(category.name),
                      selectedChannelId: widget.selectedChannelId,
                      tokens: tokens,
                      onToggle: () => _toggle(category.name),
                      onSelect: widget.onSelect,
                      onAction: widget.onAction,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.space, required this.tokens});

  final Space space;
  final LoafTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.border, width: 1)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              space.name,
              style: loafDisplay(17, 600).copyWith(color: tokens.textStrong),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Icon(LucideIcons.chevronDown, color: tokens.textMuted, size: 18),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.tokens});

  final LoafTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: tokens.card,
          border: Border.all(color: tokens.border),
          borderRadius: BorderRadius.circular(LoafRadius.md),
        ),
        child: Row(
          children: [
            Icon(LucideIcons.search, color: tokens.textMuted, size: 16),
            const SizedBox(width: 8),
            Text(
              'Search',
              style: loafBody(13, 400).copyWith(color: tokens.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategorySection extends StatelessWidget {
  const _CategorySection({
    required this.category,
    required this.collapsed,
    required this.selectedChannelId,
    required this.tokens,
    required this.onToggle,
    required this.onSelect,
    required this.onAction,
  });

  final ChannelCategory category;
  final bool collapsed;
  final String selectedChannelId;
  final LoafTokens tokens;
  final VoidCallback onToggle;
  final ValueChanged<String> onSelect;
  final void Function(String channelId, ChannelAction action)? onAction;

  @override
  Widget build(BuildContext context) {
    // Collapsed categories still surface channels with pending mentions, so
    // pings never get hidden behind a collapse. Channels you have not joined
    // cannot have any, so a collapse always hides them.
    //
    // Unjoined channels sink to the bottom of their own category rather than
    // a separate section: the category is structure the space's admins
    // built, and the channel belongs in it.
    final visibleChannels = collapsed
        ? category.channels.where((c) => c.joined && c.mentions > 0)
        : [
            ...category.channels.where((c) => c.joined),
            ...category.channels.where((c) => !c.joined),
          ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 16, 12, 4),
            child: Row(
              children: [
                AnimatedRotation(
                  duration: LoafMotion.fast,
                  curve: LoafMotion.ease,
                  turns: collapsed ? -0.25 : 0,
                  child: Icon(
                    LucideIcons.chevronDown,
                    size: 14,
                    color: tokens.textMuted,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  category.name.toUpperCase(),
                  style: loafBody(
                    11,
                    600,
                    height: 1.3,
                  ).copyWith(color: tokens.textMuted, letterSpacing: 0.04 * 11),
                ),
              ],
            ),
          ),
        ),
        for (final channel in visibleChannels)
          _ChannelEntry(
            channel: channel,
            selected: channel.id == selectedChannelId,
            tokens: tokens,
            onTap: () => onSelect(channel.id),
            onAction: onAction == null || !channel.joined
                ? null
                : (action) => onAction!(channel.id, action),
          ),
      ],
    );
  }
}

class _ChannelEntry extends StatelessWidget {
  const _ChannelEntry({
    required this.channel,
    required this.selected,
    required this.tokens,
    required this.onTap,
    required this.onAction,
  });

  final Channel channel;
  final bool selected;
  final LoafTokens tokens;
  final VoidCallback onTap;
  final ValueChanged<ChannelAction>? onAction;

  Future<void> _openActions(BuildContext context, {Offset? position}) async {
    final onAction = this.onAction;
    if (onAction == null) return;
    final action = await showChannelActions(
      context,
      channel,
      position: position,
    );
    if (action != null) onAction(action);
  }

  @override
  Widget build(BuildContext context) {
    final joined = channel.joined;
    // Muted channels keep their mentions but lose the bold "something new"
    // styling: that is the point of muting them.
    final unread = joined && !channel.muted && channel.unread > 0;
    final iconData = channel.icon;
    final fg = selected
        ? tokens.accent
        : unread
        ? tokens.textStrong
        : joined
        ? tokens.textBody
        : tokens.textMuted;

    return Padding(
      key: ValueKey('channel-${channel.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 34,
            decoration: BoxDecoration(
              color: selected ? tokens.card : null,
              borderRadius: BorderRadius.circular(LoafRadius.md),
              boxShadow: selected ? tokens.shadowSm : null,
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: onTap,
                // Long press on a phone, right-click on a computer — the
                // same split as message actions.
                onLongPress: !isDesktop && onAction != null
                    ? () {
                        HapticFeedback.mediumImpact();
                        _openActions(context);
                      }
                    : null,
                onSecondaryTapUp: isDesktop && onAction != null
                    ? (details) => _openActions(
                        context,
                        position: details.globalPosition,
                      )
                    : null,
                hoverColor: tokens.card.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(LoafRadius.md),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      Icon(iconData, size: 16, color: fg),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          channel.name,
                          overflow: TextOverflow.ellipsis,
                          style:
                              (unread ? loafBody(15, 600) : loafBody(15, 400))
                                  .copyWith(color: fg),
                        ),
                      ),
                      if (channel.muted) ...[
                        const SizedBox(width: 6),
                        Icon(
                          LucideIcons.bellOff,
                          size: 14,
                          color: tokens.textMuted,
                        ),
                      ],
                      if (!joined) ...[
                        const SizedBox(width: 6),
                        _JoinPill(tokens: tokens),
                      ] else if (channel.mentions > 0) ...[
                        const SizedBox(width: 6),
                        _CountBadge(count: channel.mentions, tokens: tokens),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (channel.kind == ChannelKind.voice && channel.occupants.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 30, top: 2, bottom: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final member in channel.occupants)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          _MemberAvatar(member: member, size: 20),
                          const SizedBox(width: 8),
                          Text(
                            member.name,
                            overflow: TextOverflow.ellipsis,
                            style: loafBody(
                              13,
                              400,
                            ).copyWith(color: tokens.textMuted),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Marks a channel you can join with one tap. Not a separate button: the
/// whole row joins, and this says so.
class _JoinPill extends StatelessWidget {
  const _JoinPill({required this.tokens});

  final LoafTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x2),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(LoafRadius.full),
        border: Border.all(color: tokens.borderStrong),
      ),
      child: Text(
        'join',
        style: loafBody(11, 600).copyWith(color: tokens.textBody),
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count, required this.tokens});

  final int count;
  final LoafTokens tokens;

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
      ),
      child: Text(
        '$count',
        style: loafBody(11, 700).copyWith(color: Colors.white),
      ),
    );
  }
}

class _MemberAvatar extends StatelessWidget {
  const _MemberAvatar({required this.member, required this.size});

  final Member member;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: member.color, shape: BoxShape.circle),
      child: Text(
        member.initials,
        style: loafBody(9, 600).copyWith(color: Colors.white),
      ),
    );
  }
}
