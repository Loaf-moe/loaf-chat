/// What you can do to a space you are in, and its leave confirmation. The
/// same two idioms as channel actions: a sheet on a phone, a menu on a
/// computer.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../mock/fixtures.dart';
import '../platform.dart';
import '../theme/loaf_theme.dart';
import '../widgets/action_menu.dart';

enum SpaceAction { invite, leave }

ActionItem<SpaceAction> _item(SpaceAction action) => switch (action) {
  SpaceAction.invite => const ActionItem(
    value: SpaceAction.invite,
    icon: LucideIcons.userPlus,
    label: 'Invite people',
  ),
  SpaceAction.leave => const ActionItem(
    value: SpaceAction.leave,
    icon: LucideIcons.logOut,
    label: 'Leave space',
    destructive: true,
  ),
};

/// Opens the space's actions — a sheet on mobile, a menu at [position] on
/// desktop — and returns the one chosen, or null if dismissed. Only actions
/// in [allowed] are offered; call this only when [allowed] is not empty.
Future<SpaceAction?> showSpaceActions(
  BuildContext context,
  Space space, {
  required Offset position,
  required Set<SpaceAction> allowed,
}) {
  final items = [
    for (final action in SpaceAction.values)
      if (allowed.contains(action)) _item(action),
  ];
  return isDesktop
      ? showActionMenu(context, position: position, items: items)
      : showActionSheet(
          context,
          header: (context) => _SheetHeader(space: space),
          items: items,
        );
}

/// Confirms leaving [space] before anything is sent: it names what goes
/// with it, since leaving a space also leaves its channels.
Future<bool> confirmLeaveSpace(
  BuildContext context,
  Space space, {
  required int rooms,
}) async {
  final tokens = LoafTokens.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: tokens.card,
      title: Text(
        'leave ${space.name}?',
        style: loafBody(17, 600).copyWith(color: tokens.textStrong),
      ),
      content: Text(
        rooms == 0
            ? "you can join again from explore if it's public."
            : "you'll leave its $rooms channels too.",
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
  const _SheetHeader({required this.space});

  final Space space;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Row(
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: space.color,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(
            space.initials,
            style: loafBody(11, 600).copyWith(color: Colors.white),
          ),
        ),
        const SizedBox(width: LoafSpace.x2),
        Expanded(
          child: Text(
            space.name,
            overflow: TextOverflow.ellipsis,
            style: loafBody(17, 600).copyWith(color: tokens.textStrong),
          ),
        ),
      ],
    );
  }
}
