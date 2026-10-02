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
import '../emoji/emoji_picker.dart';
import '../widgets/toast.dart';
import '../widgets/action_menu.dart';
import 'timeline.dart';

enum MessageAction { reply, copy, edit, delete }

/// The reactions offered without opening a picker. Bread earns its place.
const quickReactions = ['👍', '❤️', '😂', '😮', '🔥', '🥖'];

/// Actions available on [message] to [you]. Edit and delete are yours alone;
/// removing someone else's message is moderation, which v1 defers. A
/// message the server does not have yet can only be copied: replying,
/// editing and deleting all point at an event it has not got. Nor can a
/// message in a timeline that is not [writable]: a reply or an edit would
/// have nowhere to be written.
List<MessageAction> actionsFor(
  Message message,
  Member you, {
  bool writable = true,
}) => [
  if (!writable || message.status != MessageStatus.sent) ...[
    if (message.body.isNotEmpty) MessageAction.copy,
  ] else ...[
    MessageAction.reply,
    if (message.body.isNotEmpty) MessageAction.copy,
    if (message.author.id == you.id) ...[
      if (message.media == null && message.callLine == null) MessageAction.edit,
      MessageAction.delete,
    ],
  ],
];

/// Whether [message] can take a reaction yet: only once the server has it,
/// and only where the timeline is [writable] — a reaction is sent into the
/// room like any message.
bool canReactTo(Message message, {bool writable = true}) =>
    writable && message.status == MessageStatus.sent;

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

List<ActionItem<_Pick>> _items(Message message, Timeline controller) => [
  for (final action in actionsFor(
    message,
    controller.you,
    writable: controller.writable,
  ))
    ActionItem(
      value: _Act(action),
      icon: action.icon,
      label: action.label,
      destructive: action.destructive,
    ),
];

/// Touch: long press. Rises from the bottom, reactions within thumb reach.
Future<void> showMessageActionsSheet(
  BuildContext context,
  Timeline controller,
  Message message,
) async {
  // A caption-less picture that is still sending offers nothing: no empty
  // sheet.
  final items = _items(message, controller);
  final canReact = canReactTo(message, writable: controller.writable);
  if (items.isEmpty && !canReact) return;
  final pick = await showActionSheet<_Pick>(
    context,
    header: canReact
        ? (context) => _ReactionRow(
            size: 44,
            onPick: (pick) => Navigator.pop(context, pick),
          )
        : null,
    items: items,
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
  Timeline controller,
  Message message,
  Offset position, {
  String selection = '',
}) async {
  final canReact = canReactTo(message, writable: controller.writable);
  final items = [
    if (selection.isNotEmpty)
      ActionItem<_Pick>(
        value: _CopySelection(selection),
        icon: LucideIcons.textCursorInput,
        label: 'Copy selection',
      ),
    ..._items(message, controller),
  ];
  // Nothing to offer: no empty menu.
  if (items.isEmpty && !canReact) return;
  final pick = await showActionMenu<_Pick>(
    context,
    position: position,
    leading: [if (canReact) _ReactionMenuEntry()],
    items: items,
  );
  if (pick != null && context.mounted) {
    await _perform(context, controller, message, pick, position: position);
  }
}

/// Runs a pick after its sheet or menu has closed, so any dialog it opens
/// is not stacked underneath a surface that is animating away.
Future<void> _perform(
  BuildContext context,
  Timeline controller,
  Message message,
  _Pick pick, {
  Offset? position,
}) async {
  switch (pick) {
    case _React(:final emoji):
      controller.toggleReaction(message.id, emoji);
    case _OpenPicker():
      final emoji = await showEmojiPicker(
        context,
        anchor: position == null ? null : position & Size.zero,
      );
      // Picking is reacting: an emoji you already reacted with stays.
      final mine = message.reactions.any((r) => r.emoji == emoji && r.mine);
      if (emoji != null && !mine) controller.toggleReaction(message.id, emoji);
    case _Act(action: MessageAction.reply):
      controller.startReply(message);
    case _Act(action: MessageAction.edit):
      controller.startEdit(message);
    case _Act(action: MessageAction.copy):
      await Clipboard.setData(ClipboardData(text: message.body));
      if (context.mounted) showToast(context, 'copied');
    case _CopySelection(:final text):
      await Clipboard.setData(ClipboardData(text: text));
      if (context.mounted) showToast(context, 'copied');
    case _Act(action: MessageAction.delete):
      if (await confirmDeleteMessage(context)) controller.delete(message.id);
  }
}

/// Redactions cannot be taken back, so this is the one action that asks.
Future<bool> confirmDeleteMessage(BuildContext context) async {
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
