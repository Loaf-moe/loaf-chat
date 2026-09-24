/// What you can do to a channel you are in, and the two ways of asking —
/// long press on a phone, right-click on a computer, as with messages.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../mock/fixtures.dart';
import '../platform.dart';
import '../theme/loaf_theme.dart';
import '../widgets/action_menu.dart';

enum ChannelAction { markRead, mute, unmute, leave }

/// Actions for a channel you have joined. Unjoined channels have none: their
/// one action is joining, and a tap already does that.
List<ChannelAction> actionsFor(Channel channel) => [
  if (channel.unread > 0 || channel.mentions > 0) ChannelAction.markRead,
  channel.muted ? ChannelAction.unmute : ChannelAction.mute,
  ChannelAction.leave,
];

ActionItem<ChannelAction> _item(ChannelAction action) => switch (action) {
  ChannelAction.markRead => const ActionItem(
    value: ChannelAction.markRead,
    icon: LucideIcons.checkCheck,
    label: 'Mark as read',
  ),
  // Muting keeps mentions: it maps to a mentions-only push rule, synced to
  // every device, with no expiry — Matrix has none to offer.
  ChannelAction.mute => const ActionItem(
    value: ChannelAction.mute,
    icon: LucideIcons.bellOff,
    label: 'Mute channel',
  ),
  ChannelAction.unmute => const ActionItem(
    value: ChannelAction.unmute,
    icon: LucideIcons.bell,
    label: 'Unmute channel',
  ),
  ChannelAction.leave => const ActionItem(
    value: ChannelAction.leave,
    icon: LucideIcons.logOut,
    label: 'Leave channel',
    destructive: true,
  ),
};

/// Opens the channel's actions — a sheet on mobile, a menu at [position] on
/// desktop — and returns the one chosen. Leaving an invite-only channel is
/// confirmed first; a declined confirmation returns null.
Future<ChannelAction?> showChannelActions(
  BuildContext context,
  Channel channel, {
  Offset? position,
}) async {
  final items = [for (final action in actionsFor(channel)) _item(action)];
  final chosen = isDesktop && position != null
      ? await showActionMenu(context, position: position, items: items)
      : await showActionSheet(
          context,
          header: (context) => _SheetHeader(channel: channel),
          items: items,
        );

  if (chosen == ChannelAction.leave && channel.private && context.mounted) {
    return await _confirmLeavePrivate(context, channel) ? chosen : null;
  }
  return chosen;
}

/// Leaving an open channel is one tap to undo, so it does not ask. An
/// invite-only one is gone for good unless someone invites you again.
Future<bool> _confirmLeavePrivate(BuildContext context, Channel channel) async {
  final tokens = LoafTokens.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: tokens.card,
      title: Text(
        'leave ${channel.name}?',
        style: loafBody(17, 600).copyWith(color: tokens.textStrong),
      ),
      content: Text(
        "it's invite-only, so you'll need a new invite to come back.",
        style: loafBody(14, 400).copyWith(color: tokens.textBody),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text('cancel', style: TextStyle(color: tokens.textMuted)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text('leave', style: TextStyle(color: tokens.accent)),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({required this.channel});

  final Channel channel;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Row(
      children: [
        Icon(channel.icon, size: 18, color: tokens.textMuted),
        const SizedBox(width: LoafSpace.x2),
        Expanded(
          child: Text(
            channel.name,
            overflow: TextOverflow.ellipsis,
            style: loafBody(17, 600).copyWith(color: tokens.textStrong),
          ),
        ),
      ],
    );
  }
}
