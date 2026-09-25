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
    this.onStartCall,
    this.callPanel,
    this.callPanelExpanded = false,
  });

  final Channel channel;

  /// DMs only: rings everyone in the chat. Null while a call here is already
  /// running: the panel is right there, so the header's buttons step aside.
  final void Function({required bool video})? onStartCall;

  /// A DM's call, docked above the timeline.
  final Widget? callPanel;

  /// The call fills the conversation: no timeline, no composer.
  final bool callPanelExpanded;
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
              onStartCall: onStartCall,
            ),
            if (callPanel != null && callPanelExpanded)
              Expanded(child: callPanel!)
            else ...[
              ?callPanel,
              Expanded(child: _Timeline(controller: timeline)),
              ?callBar,
              Composer(
                channelName: channel.name,
                timeline: timeline,
                prefix: switch (channel) {
                  Channel(kind: ChannelKind.direct, members: [_]) => '@',
                  Channel(kind: ChannelKind.direct) => '',
                  _ => '#',
                },
              ),
            ],
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
    this.onStartCall,
  });

  final Channel channel;
  final VoidCallback? onOpenNavigation;
  final VoidCallback? onToggleMembers;
  final bool navigationAttention;
  final void Function({required bool video})? onStartCall;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final topic = channel.topic;
    final direct = channel.kind == ChannelKind.direct;
    final onStartCall = this.onStartCall;
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
              Icon(
                direct
                    ? (channel.members.length > 1
                          ? LucideIcons.users
                          : LucideIcons.atSign)
                    : LucideIcons.hash,
                size: 18,
                color: tokens.textMuted,
              ),
              const SizedBox(width: LoafSpace.x1),
              Flexible(
                flex: 0,
                child: Text(
                  channel.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: loafBody(15, 600).copyWith(color: tokens.textStrong),
                ),
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
              if (direct && onStartCall != null) ...[
                _HeaderIconButton(
                  icon: LucideIcons.phone,
                  tooltip: 'Start a voice call',
                  onTap: () => onStartCall(video: false),
                ),
                _HeaderIconButton(
                  icon: LucideIcons.video,
                  tooltip: 'Start a video call',
                  onTap: () => onStartCall(video: true),
                ),
              ] else if (!direct)
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
  const _HeaderIconButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      icon: Icon(icon, size: 20, color: tokens.textMuted),
    );
  }
}

class _Timeline extends StatefulWidget {
  const _Timeline({required this.controller});

  final TimelineController controller;

  @override
  State<_Timeline> createState() => _TimelineState();
}

class _TimelineState extends State<_Timeline> {
  final _scroll = ScrollController();
  late int _count = widget.controller.messages.length;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onMessages);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onMessages);
    _scroll.dispose();
    super.dispose();
  }

  /// Sending brings you back to the newest message, even if you had
  /// scrolled up to reread something. Other people's messages do not yank
  /// you around.
  void _onMessages() {
    final messages = widget.controller.messages;
    final grew = messages.length > _count;
    _count = messages.length;
    setState(() {});
    if (grew &&
        messages.last.author.id == widget.controller.you.id &&
        _scroll.hasClients) {
      _scroll.animateTo(0, duration: LoafMotion.normal, curve: LoafMotion.ease);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final entries = groupTimeline(controller.messages).reversed.toList();
    return ListView.builder(
      controller: _scroll,
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
          CallEntry() => _CallLineTile(message: entry.message),
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

/// A call's system line: small, centred and quiet, so a DM's history of
/// calls reads as punctuation between messages rather than as messages.
class _CallLineTile extends StatelessWidget {
  const _CallLineTile({required this.message});

  final Message message;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final missed = message.callLine == CallLine.missed;
    final at = message.sentAt;
    final time =
        '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.only(bottom: LoafSpace.x4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            missed ? LucideIcons.phoneMissed : LucideIcons.phone,
            size: 14,
            color: missed ? tokens.accent : tokens.textMuted,
          ),
          const SizedBox(width: LoafSpace.x2),
          Text(
            message.body,
            style: loafBody(13, 500).copyWith(color: tokens.textBody),
          ),
          const SizedBox(width: LoafSpace.x2),
          Text(
            time,
            style: loafBody(11, 400).copyWith(color: tokens.textMuted),
          ),
        ],
      ),
    );
  }
}
