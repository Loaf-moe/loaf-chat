/// The middle column: a space's categories and channels, mockup only.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../mock/fixtures.dart';
import '../theme/loaf_theme.dart';

class ChannelList extends StatefulWidget {
  const ChannelList({
    super.key,
    required this.space,
    required this.selectedChannelId,
    required this.onSelect,
  });

  final Space space;
  final String selectedChannelId;
  final ValueChanged<String> onSelect;

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
      child: Column(
        children: [
          _Header(space: widget.space, tokens: tokens),
          _SearchField(tokens: tokens),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 8),
              children: [
                for (final category in widget.space.categories)
                  _CategorySection(
                    category: category,
                    collapsed: _collapsed.contains(category.name),
                    selectedChannelId: widget.selectedChannelId,
                    tokens: tokens,
                    onToggle: () => _toggle(category.name),
                    onSelect: widget.onSelect,
                  ),
              ],
            ),
          ),
          _UserChip(tokens: tokens),
        ],
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
  });

  final ChannelCategory category;
  final bool collapsed;
  final String selectedChannelId;
  final LoafTokens tokens;
  final VoidCallback onToggle;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    // Collapsed categories still surface channels with pending mentions, so
    // pings never get hidden behind a collapse.
    final visibleChannels = collapsed
        ? category.channels.where((c) => c.mentions > 0)
        : category.channels;

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
  });

  final Channel channel;
  final bool selected;
  final LoafTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final unread = channel.unread > 0;
    final iconData = channel.kind == ChannelKind.voice
        ? LucideIcons.volume2
        : channel.private
        ? LucideIcons.lock
        : LucideIcons.hash;
    final fg = selected
        ? tokens.accent
        : unread
        ? tokens.textStrong
        : tokens.textBody;

    return Padding(
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
                      if (channel.mentions > 0) ...[
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

class _UserChip extends StatelessWidget {
  const _UserChip({required this.tokens});

  final LoafTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: tokens.sidebar,
        border: Border(top: BorderSide(color: tokens.border, width: 1)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            height: 32,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: currentUser.color,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    currentUser.initials,
                    style: loafBody(12, 600).copyWith(color: Colors.white),
                  ),
                ),
                if (currentUser.online)
                  Positioned(
                    right: -1,
                    bottom: -1,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: tokens.online,
                        shape: BoxShape.circle,
                        border: Border.all(color: tokens.sidebar, width: 2),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  currentUser.name,
                  overflow: TextOverflow.ellipsis,
                  style: loafBody(13, 600).copyWith(color: tokens.textStrong),
                ),
                Text(
                  currentUser.id,
                  overflow: TextOverflow.ellipsis,
                  style: loafBody(11, 400).copyWith(color: tokens.textMuted),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(LucideIcons.mic, size: 18, color: tokens.textMuted),
            onPressed: () {},
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            icon: Icon(LucideIcons.settings, size: 18, color: tokens.textMuted),
            onPressed: () {},
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}
