/// What you can do to a channel you are in, and the two ways of asking —
/// long press on a phone, right-click on a computer, as with messages.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../home/direct_messages.dart';
import '../mock/fixtures.dart';
import '../platform.dart';
import '../theme/loaf_theme.dart';
import '../widgets/action_menu.dart';

enum ChannelAction {
  markRead,
  favourite,
  unfavourite,
  lowPriority,
  notLowPriority,
  olderConversations,
  mute,
  unmute,
  invite,
  leave,
}

/// Actions for a channel you have joined. Unjoined channels have none: their
/// one action is joining, and a tap already does that.
///
/// [home] rows can also be tagged favourite or low priority. Space channels
/// never are from loaf: each room has one place in the UI, and a favourited
/// space channel would need a second.
///
/// Only actions in [allowed] are offered, when it is given: the backend may
/// not do them all yet, and one that only pretends would lie.
List<ChannelAction> actionsFor(
  Channel channel, {
  bool home = false,
  Set<ChannelAction>? allowed,
}) => [
  for (final action in [
    if (channel.unread > 0 || channel.mentions > 0) ChannelAction.markRead,
    if (home) ...[
      channel.favourite ? ChannelAction.unfavourite : ChannelAction.favourite,
      channel.lowPriority
          ? ChannelAction.notLowPriority
          : ChannelAction.lowPriority,
      if (channel.earlier.isNotEmpty) ChannelAction.olderConversations,
    ],
    channel.muted ? ChannelAction.unmute : ChannelAction.mute,
    // A 1:1 DM has exactly one person to invite already there: nobody else
    // could be added to it.
    if (!(channel.kind == ChannelKind.direct && channel.members.length == 1))
      ChannelAction.invite,
    ChannelAction.leave,
  ])
    if (allowed == null || allowed.contains(action)) action,
];

/// What the row is, in the words the actions use.
String _noun(Channel channel) => switch (channel.kind) {
  ChannelKind.room => 'room',
  ChannelKind.direct => 'conversation',
  _ => 'channel',
};

ActionItem<ChannelAction> _item(ChannelAction action, String noun) =>
    switch (action) {
      ChannelAction.markRead => const ActionItem(
        value: ChannelAction.markRead,
        icon: LucideIcons.checkCheck,
        label: 'Mark as read',
      ),
      // Room tags, synced to every device and to other clients.
      ChannelAction.favourite => const ActionItem(
        value: ChannelAction.favourite,
        icon: LucideIcons.star,
        label: 'Favourite',
      ),
      ChannelAction.unfavourite => const ActionItem(
        value: ChannelAction.unfavourite,
        icon: LucideIcons.starOff,
        label: 'Unfavourite',
      ),
      ChannelAction.lowPriority => const ActionItem(
        value: ChannelAction.lowPriority,
        icon: LucideIcons.arrowDownToLine,
        label: 'Low priority',
      ),
      ChannelAction.notLowPriority => const ActionItem(
        value: ChannelAction.notLowPriority,
        icon: LucideIcons.arrowUpToLine,
        label: 'Not low priority',
      ),
      ChannelAction.olderConversations => const ActionItem(
        value: ChannelAction.olderConversations,
        icon: LucideIcons.history,
        label: 'Older conversations',
      ),
      // Muting keeps mentions: it maps to a mentions-only push rule, synced to
      // every device, with no expiry — Matrix has none to offer.
      ChannelAction.mute => ActionItem(
        value: ChannelAction.mute,
        icon: LucideIcons.bellOff,
        label: 'Mute $noun',
      ),
      ChannelAction.unmute => ActionItem(
        value: ChannelAction.unmute,
        icon: LucideIcons.bell,
        label: 'Unmute $noun',
      ),
      ChannelAction.invite => const ActionItem(
        value: ChannelAction.invite,
        icon: LucideIcons.userPlus,
        label: 'Invite people',
      ),
      ChannelAction.leave => ActionItem(
        value: ChannelAction.leave,
        icon: LucideIcons.logOut,
        label: 'Leave $noun',
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
  bool home = false,
  Set<ChannelAction>? allowed,
}) async {
  final items = [
    for (final action in actionsFor(channel, home: home, allowed: allowed))
      _item(action, _noun(channel)),
  ];
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

/// The rooms folded into [channel]'s row, newest first, to pick one from.
/// A sheet on a phone; on a computer, a small dialog, since the menu that
/// led here has already closed. Returns the chosen room's id.
Future<String?> showOlderConversations(BuildContext context, Channel channel) {
  final now = DateTime.now();
  final items = [
    for (final room in channel.earlier)
      ActionItem(
        value: room.id,
        icon: LucideIcons.messageCircle,
        label: room.lastActivity == null
            ? 'older conversation'
            : 'conversation · ${activeLabel(room.lastActivity!, now)}',
      ),
  ];
  if (!isDesktop) {
    return showActionSheet(
      context,
      header: (context) => _SheetHeader(channel: channel),
      items: items,
    );
  }
  final tokens = LoafTokens.of(context);
  return showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      backgroundColor: tokens.card,
      title: Text(
        'older conversations with ${channel.name}',
        style: loafBody(16, 600).copyWith(color: tokens.textStrong),
      ),
      children: [
        for (final item in items)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, item.value),
            child: ActionLabel(item: item, compact: true),
          ),
      ],
    ),
  );
}
