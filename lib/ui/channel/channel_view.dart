/// The channel reading surface: header, timeline and composer.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../mock/fixtures.dart';
import '../theme/loaf_theme.dart';
import 'composer.dart';
import 'message_group_tile.dart';
import 'timeline_controller.dart';

const _narrowTopicWidth = 480.0;

const _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

String _formatDay(DateTime day) {
  final today = DateUtils.dateOnly(DateTime.now());
  final yesterday = today.subtract(const Duration(days: 1));
  if (day == today) return 'Today';
  if (day == yesterday) return 'Yesterday';
  return '${day.day} ${_monthNames[day.month - 1]}';
}

/// The channel a user is currently reading: header, message timeline and the
/// composer to reply with. Fake data, but [timeline] is live: reactions,
/// deletions and the composer's reply or edit target all go through it.
class ChannelView extends StatelessWidget {
  const ChannelView({
    super.key,
    required this.channel,
    required this.timeline,
    this.onOpenNavigation,
    this.onToggleMembers,
    this.callBar,
    this.navigationAttention = false,
  });

  final Channel channel;
  final TimelineController timeline;

  /// Marks the menu button when a notice that must not be missed is waiting
  /// in the rail. Only matters on a phone, where the rail hides in the drawer.
  final bool navigationAttention;

  /// The connected-voice bar, when the user is in a voice channel. It sits
  /// between the timeline and the composer rather than below the composer,
  /// so the composer stays the last thing above the keyboard.
  final Widget? callBar;

  /// Opens the navigation drawer. Only passed on the phone layout — when
  /// null, the caller is showing the space/channel rail permanently, so no
  /// menu button is drawn at all.
  final VoidCallback? onOpenNavigation;

  final VoidCallback? onToggleMembers;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    // The page colour runs edge to edge while the content sits inside the
    // insets, so the status bar and home indicator float over a continuous
    // surface instead of covering the header and composer.
    return ColoredBox(
      color: tokens.page,
      child: SafeArea(
        child: Column(
          children: [
            _ChannelHeader(
              channel: channel,
              onOpenNavigation: onOpenNavigation,
              onToggleMembers: onToggleMembers,
              navigationAttention: navigationAttention,
            ),
            Expanded(child: _Timeline(controller: timeline)),
            ?callBar,
            Composer(channelName: channel.name, timeline: timeline),
          ],
        ),
      ),
    );
  }
}

class _ChannelHeader extends StatelessWidget {
  const _ChannelHeader({
    required this.channel,
    required this.onOpenNavigation,
    required this.onToggleMembers,
    required this.navigationAttention,
  });

  final Channel channel;
  final VoidCallback? onOpenNavigation;
  final VoidCallback? onToggleMembers;
  final bool navigationAttention;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final topic = channel.topic;
    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: tokens.page,
        border: Border(bottom: BorderSide(color: tokens.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final showTopic =
              topic != null && constraints.maxWidth >= _narrowTopicWidth;
          return Row(
            children: [
              if (onOpenNavigation != null) ...[
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    _HeaderIconButton(
                      icon: LucideIcons.menu,
                      onTap: onOpenNavigation,
                    ),
                    if (navigationAttention)
                      Positioned(
                        right: 8,
                        top: 8,
                        child: IgnorePointer(
                          child: Container(
                            key: const ValueKey('navigation-attention'),
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: tokens.accent,
                              shape: BoxShape.circle,
                              border: Border.all(color: tokens.page, width: 2),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: LoafSpace.x2),
              ],
              Icon(LucideIcons.hash, size: 18, color: tokens.textMuted),
              const SizedBox(width: LoafSpace.x1),
              Text(
                channel.name,
                style: loafBody(15, 600).copyWith(color: tokens.textStrong),
              ),
              if (showTopic) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x3),
                  child: SizedBox(
                    height: 16,
                    child: VerticalDivider(color: tokens.border, width: 1),
                  ),
                ),
                Expanded(
                  child: Text(
                    topic,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: loafBody(13, 400).copyWith(color: tokens.textMuted),
                  ),
                ),
              ] else
                const Spacer(),
              _HeaderIconButton(
                icon: LucideIcons.users,
                onTap: onToggleMembers,
              ),
              // No search button: message search is a v1 non-goal, and in
              // encrypted rooms it needs a client-side index (see the spec).
            ],
          );
        },
      ),
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return IconButton(
      onPressed: onTap,
      icon: Icon(icon, size: 20, color: tokens.textMuted),
    );
  }
}

class _Timeline extends StatelessWidget {
  const _Timeline({required this.controller});

  final TimelineController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final entries = groupTimeline(controller.messages).reversed.toList();
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.symmetric(
        horizontal: LoafSpace.x4,
        vertical: LoafSpace.x2,
      ),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        return switch (entry) {
          DaySeparator() => _DaySeparatorTile(entry: entry),
          MessageGroup() => Padding(
            padding: const EdgeInsets.only(bottom: LoafSpace.x4),
            child: MessageGroupTile(group: entry, controller: controller),
          ),
        };
      },
    );
  }
}

class _DaySeparatorTile extends StatelessWidget {
  const _DaySeparatorTile({required this.entry});

  final DaySeparator entry;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: LoafSpace.x4),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Divider(color: tokens.border, height: 1, thickness: 1),
          Container(
            color: tokens.page,
            padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x2),
            child: Text(
              _formatDay(entry.day),
              style: loafBody(11, 600).copyWith(color: tokens.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}
