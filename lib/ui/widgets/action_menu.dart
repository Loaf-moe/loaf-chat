/// The two shapes an action list takes: a bottom sheet for touch, a menu at
/// the pointer for desktop. Message and channel actions both use these, so a
/// long press or a right-click looks the same wherever it lands.
library;

import 'package:flutter/material.dart';

import '../theme/loaf_theme.dart';

/// One row of an action list. [value] is what the sheet or menu returns.
class ActionItem<T> {
  const ActionItem({
    required this.value,
    required this.icon,
    required this.label,
    this.destructive = false,
  });

  final T value;
  final IconData icon;
  final String label;

  /// Drawn in the accent red. For actions that take something away.
  final bool destructive;
}

/// Touch: rises from the bottom with the actions within thumb reach.
/// [header], when given, sits above a divider — built with the sheet's own
/// context so it can pop a value of its own.
Future<T?> showActionSheet<T>(
  BuildContext context, {
  WidgetBuilder? header,
  required List<ActionItem<T>> items,
}) {
  final tokens = LoafTokens.of(context);
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: tokens.card,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(LoafRadius.xxxl),
      ),
    ),
    builder: (context) => SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (header != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                LoafSpace.x4,
                0,
                LoafSpace.x4,
                LoafSpace.x3,
              ),
              child: header(context),
            ),
            Divider(height: 1, color: tokens.border),
          ],
          const SizedBox(height: LoafSpace.x2),
          for (final item in items)
            InkWell(
              onTap: () => Navigator.pop(context, item.value),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: LoafSpace.x5,
                  vertical: 14,
                ),
                child: ActionLabel(item: item, compact: false),
              ),
            ),
          const SizedBox(height: LoafSpace.x2),
        ],
      ),
    ),
  );
}

/// Pointer: a menu at [position], in global coordinates. Escape or a click
/// elsewhere closes it. [leading] entries go above the actions — a divider
/// is added between them.
Future<T?> showActionMenu<T>(
  BuildContext context, {
  required Offset position,
  List<PopupMenuEntry<T>> leading = const [],
  required List<ActionItem<T>> items,
}) {
  final tokens = LoafTokens.of(context);
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  return showMenu<T>(
    context: context,
    color: tokens.card,
    elevation: 0,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(LoafRadius.lg),
      side: BorderSide(color: tokens.border),
    ),
    position: RelativeRect.fromRect(
      position & Size.zero,
      Offset.zero & overlay.size,
    ),
    items: [
      ...leading,
      if (leading.isNotEmpty) const PopupMenuDivider(height: 9),
      for (final item in items)
        PopupMenuItem<T>(
          value: item.value,
          height: 36,
          child: ActionLabel(item: item, compact: true),
        ),
    ],
  );
}

/// Icon and label for one action row, sized for a sheet or a menu.
class ActionLabel extends StatelessWidget {
  const ActionLabel({super.key, required this.item, required this.compact});

  final ActionItem<Object?> item;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final destructive = item.destructive;
    return Row(
      children: [
        Icon(
          item.icon,
          size: compact ? 16 : 20,
          color: destructive ? tokens.accent : tokens.textMuted,
        ),
        SizedBox(width: compact ? LoafSpace.x3 : LoafSpace.x4),
        Text(
          item.label,
          style: loafBody(
            compact ? 14 : 16,
            500,
          ).copyWith(color: destructive ? tokens.accent : tokens.textStrong),
        ),
      ],
    );
  }
}
