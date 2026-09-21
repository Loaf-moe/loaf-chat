/// The channel reading surface: header, timeline and composer.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../mock/fixtures.dart';
import '../theme/loaf_theme.dart';
import 'composer.dart';
import 'message_group_tile.dart';

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
/// composer to reply with. Pure UI over fake data — [messages] never mutates.
class ChannelView extends StatelessWidget {
  const ChannelView({
    super.key,
    required this.channel,
    required this.messages,
    this.onOpenNavigation,
    this.onToggleMembers,
    this.callBar,
  });

  final Channel channel;
  final List<Message> messages;

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
    return ColoredBox(
      color: tokens.page,
      child: Column(
        children: [
          _ChannelHeader(
            channel: channel,
            onOpenNavigation: onOpenNavigation,
            onToggleMembers: onToggleMembers,
          ),
          Expanded(child: _Timeline(messages: messages)),
          ?callBar,
          Composer(channelName: channel.name),
        ],
      ),
    );
  }
}

class _ChannelHeader extends StatelessWidget {
  const _ChannelHeader({
    required this.channel,
    required this.onOpenNavigation,
    required this.onToggleMembers,
  });

  final Channel channel;
  final VoidCallback? onOpenNavigation;
  final VoidCallback? onToggleMembers;

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
                _HeaderIconButton(
                  icon: LucideIcons.menu,
                  onTap: onOpenNavigation,
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
              _HeaderIconButton(icon: LucideIcons.search, onTap: () {}),
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
  const _Timeline({required this.messages});

  final List<Message> messages;

  @override
  Widget build(BuildContext context) {
    final entries = groupTimeline(messages).reversed.toList();
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
            child: MessageGroupTile(group: entry),
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
