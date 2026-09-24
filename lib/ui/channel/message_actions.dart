/// What you can do to a message, and the two ways of asking.
///
/// One action list, whichever way you got here: a long press opens it as a
/// bottom sheet, a right-click (or the hover toolbar's "more") as a menu at
/// the pointer. Input decides the presentation, not platform — a touchscreen
/// laptop long-presses too, and a phone never hovers.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../mock/fixtures.dart';
import '../theme/loaf_theme.dart';
import 'timeline_controller.dart';

enum MessageAction { reply, copy, edit, delete }

/// The reactions offered without opening a picker. Bread earns its place.
const quickReactions = ['👍', '❤️', '😂', '😮', '🔥', '🥖'];

/// Actions available on [message] to [you]. Edit and delete are yours alone;
/// removing someone else's message is moderation, which v1 defers.
List<MessageAction> actionsFor(Message message, Member you) => [
  MessageAction.reply,
  MessageAction.copy,
  if (message.author.id == you.id) ...[
    MessageAction.edit,
    MessageAction.delete,
  ],
];

extension on MessageAction {
  String get label => switch (this) {
    MessageAction.reply => 'Reply',
    MessageAction.copy => 'Copy text',
    MessageAction.edit => 'Edit',
    MessageAction.delete => 'Delete',
  };

  IconData get icon => switch (this) {
    MessageAction.reply => LucideIcons.reply,
    MessageAction.copy => LucideIcons.copy,
    MessageAction.edit => LucideIcons.pencil,
    MessageAction.delete => LucideIcons.trash2,
  };

  bool get destructive => this == MessageAction.delete;
}

/// What the person picked: a quick reaction, the full picker, or an action.
sealed class _Pick {
  const _Pick();
}

class _React extends _Pick {
  const _React(this.emoji);
  final String emoji;
}

class _OpenPicker extends _Pick {
  const _OpenPicker();
}

class _Act extends _Pick {
  const _Act(this.action);
  final MessageAction action;
}

class _CopySelection extends _Pick {
  const _CopySelection(this.text);
  final String text;
}

/// Touch: long press. Rises from the bottom, reactions within thumb reach.
Future<void> showMessageActionsSheet(
  BuildContext context,
  TimelineController controller,
  Message message,
) async {
  final tokens = LoafTokens.of(context);
  final pick = await showModalBottomSheet<_Pick>(
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
          Padding(
            padding: const EdgeInsets.fromLTRB(
              LoafSpace.x4,
              0,
              LoafSpace.x4,
              LoafSpace.x3,
            ),
            child: _ReactionRow(
              size: 44,
              onPick: (pick) => Navigator.pop(context, pick),
            ),
          ),
          Divider(height: 1, color: tokens.border),
          const SizedBox(height: LoafSpace.x2),
          for (final action in actionsFor(message, controller.you))
            _ActionTile(
              action: action,
              onTap: () => Navigator.pop(context, _Act(action)),
            ),
          const SizedBox(height: LoafSpace.x2),
        ],
      ),
    ),
  );
  if (pick != null && context.mounted) {
    await _perform(context, controller, message, pick);
  }
}

/// Pointer: right-click or the toolbar's "more". Opens at [position], in
/// global coordinates. A non-empty [selection] adds Copy selection on top,
/// since that is almost certainly why you right-clicked selected text.
Future<void> showMessageContextMenu(
  BuildContext context,
  TimelineController controller,
  Message message,
  Offset position, {
  String selection = '',
}) async {
  final tokens = LoafTokens.of(context);
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final pick = await showMenu<_Pick>(
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
      _ReactionMenuEntry(),
      const PopupMenuDivider(height: 9),
      if (selection.isNotEmpty)
        PopupMenuItem<_Pick>(
          value: _CopySelection(selection),
          height: 36,
          child: const _MenuLabel(
            icon: LucideIcons.textCursorInput,
            label: 'Copy selection',
          ),
        ),
      for (final action in actionsFor(message, controller.you))
        PopupMenuItem<_Pick>(
          value: _Act(action),
          height: 36,
          child: _ActionLabel(action: action, compact: true),
        ),
    ],
  );
  if (pick != null && context.mounted) {
    await _perform(context, controller, message, pick);
  }
}

/// Runs a pick after its sheet or menu has closed, so any dialog it opens
/// is not stacked underneath a surface that is animating away.
Future<void> _perform(
  BuildContext context,
  TimelineController controller,
  Message message,
  _Pick pick,
) async {
  switch (pick) {
    case _React(:final emoji):
      controller.toggleReaction(message.id, emoji);
    case _OpenPicker():
      _toast(context, 'the full emoji picker is on its way');
    case _Act(action: MessageAction.reply):
      controller.startReply(message);
    case _Act(action: MessageAction.edit):
      controller.startEdit(message);
    case _Act(action: MessageAction.copy):
      await Clipboard.setData(ClipboardData(text: message.body));
      if (context.mounted) _toast(context, 'copied');
    case _CopySelection(:final text):
      await Clipboard.setData(ClipboardData(text: text));
      if (context.mounted) _toast(context, 'copied');
    case _Act(action: MessageAction.delete):
      if (await _confirmDelete(context)) controller.delete(message.id);
  }
}

void _toast(BuildContext context, String text) {
  final tokens = LoafTokens.of(context);
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          text,
          style: loafBody(14, 500).copyWith(color: tokens.textStrong),
        ),
        backgroundColor: tokens.card,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 1500),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LoafRadius.full),
          side: BorderSide(color: tokens.border),
        ),
      ),
    );
}

/// Redactions cannot be taken back, so this is the one action that asks.
Future<bool> _confirmDelete(BuildContext context) async {
  final tokens = LoafTokens.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: tokens.card,
      title: Text(
        'delete this message?',
        style: loafBody(17, 600).copyWith(color: tokens.textStrong),
      ),
      content: Text(
        'it disappears for everyone, and there is no undo.',
        style: loafBody(14, 400).copyWith(color: tokens.textBody),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text('cancel', style: TextStyle(color: tokens.textMuted)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text('delete', style: TextStyle(color: tokens.accent)),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

class _ReactionRow extends StatelessWidget {
  const _ReactionRow({required this.size, required this.onPick});

  final double size;
  final ValueChanged<_Pick> onPick;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    Widget bubble({required Widget child, required _Pick pick, String? tip}) {
      final button = InkResponse(
        radius: size / 2,
        onTap: () => onPick(pick),
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: tokens.sunken,
            shape: BoxShape.circle,
          ),
          child: child,
        ),
      );
      return tip == null ? button : Tooltip(message: tip, child: button);
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (final emoji in quickReactions)
          bubble(
            pick: _React(emoji),
            child: Text(emoji, style: TextStyle(fontSize: size * 0.5)),
          ),
        bubble(
          pick: const _OpenPicker(),
          tip: 'More reactions',
          child: Icon(
            LucideIcons.smilePlus,
            size: size * 0.45,
            color: tokens.textMuted,
          ),
        ),
      ],
    );
  }
}

/// The reaction row as the first entry of the pointer menu.
class _ReactionMenuEntry extends PopupMenuEntry<_Pick> {
  @override
  double get height => 44;

  @override
  bool represents(_Pick? value) => false;

  @override
  State<_ReactionMenuEntry> createState() => _ReactionMenuEntryState();
}

class _ReactionMenuEntryState extends State<_ReactionMenuEntry> {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: LoafSpace.x2,
        vertical: LoafSpace.x1,
      ),
      child: SizedBox(
        width: 7 * 34 + 6 * 4,
        child: _ReactionRow(
          size: 34,
          onPick: (pick) => Navigator.pop(context, pick),
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({required this.action, required this.onTap});

  final MessageAction action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LoafSpace.x5,
          vertical: 14,
        ),
        child: _ActionLabel(action: action, compact: false),
      ),
    );
  }
}

class _ActionLabel extends StatelessWidget {
  const _ActionLabel({required this.action, required this.compact});

  final MessageAction action;
  final bool compact;

  @override
  Widget build(BuildContext context) => _MenuLabel(
    icon: action.icon,
    label: action.label,
    compact: compact,
    destructive: action.destructive,
  );
}

/// Icon and label for one row of the sheet or the menu.
class _MenuLabel extends StatelessWidget {
  const _MenuLabel({
    required this.icon,
    required this.label,
    this.compact = true,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final bool compact;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Row(
      children: [
        Icon(
          icon,
          size: compact ? 16 : 20,
          color: destructive ? tokens.accent : tokens.textMuted,
        ),
        SizedBox(width: compact ? LoafSpace.x3 : LoafSpace.x4),
        Text(
          label,
          style: loafBody(
            compact ? 14 : 16,
            500,
          ).copyWith(color: destructive ? tokens.accent : tokens.textStrong),
        ),
      ],
    );
  }
}
