/// The pinned list, as Discord draws it: a popover beside the header's pin
/// button on a computer, a sheet on a phone. Each pinned message, newest
/// pin first; a tap jumps to it; unpin on the row for those allowed.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../members/role_colors.dart';
import '../model/media_source.dart';
import '../model/models.dart';
import '../platform.dart';
import '../theme/loaf_theme.dart';
import '../widgets/anchored_popover.dart';
import '../widgets/loaf_avatar.dart';
import 'media_row.dart' show quoteOf;
import 'message_group_tile.dart' show formatMessageTime;
import 'message_markup.dart' show parseMessage;
import 'message_text.dart' show plainTextOf;
import 'timeline.dart';

/// Opens the pinned list for [timeline]. On a computer with an [anchor]
/// (global coordinates), a popover beside it; otherwise a sheet.
Future<void> showPinnedPanel(
  BuildContext context,
  Timeline timeline, {
  Rect? anchor,
}) {
  if (isDesktop && anchor != null) {
    return showAnchoredPopover<void>(
      context,
      anchor: anchor,
      builder: (context) => SizedBox(
        width: 400,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 480),
          child: PinnedPanel(timeline: timeline),
        ),
      ),
    );
  }
  final tokens = LoafTokens.of(context);
  final from = context;
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: tokens.card,
    showDragHandle: true,
    isScrollControlled: true,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.85,
    ),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(LoafRadius.xxxl),
      ),
    ),
    // Rows may draw media, and the sheet sits above the shell.
    builder: (context) => MediaSourceScope.carry(
      from,
      child: SafeArea(top: false, child: PinnedPanel(timeline: timeline)),
    ),
  );
}

class PinnedPanel extends StatefulWidget {
  const PinnedPanel({super.key, required this.timeline});

  final Timeline timeline;

  @override
  State<PinnedPanel> createState() => _PinnedPanelState();
}

class _PinnedPanelState extends State<PinnedPanel> {
  /// One fetch per message not loaded, kept so a rebuild does not ask
  /// again. A failed one is dropped when its row is tapped to try again.
  final _fetches = <String, Future<Message?>>{};

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final timeline = widget.timeline;
    return ListenableBuilder(
      listenable: timeline,
      builder: (context, _) {
        final ids = timeline.pinnedIds.reversed.toList();
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                LoafSpace.x4,
                LoafSpace.x3,
                LoafSpace.x4,
                LoafSpace.x3,
              ),
              child: Text(
                'pinned messages',
                style: loafBody(15, 600).copyWith(color: tokens.textStrong),
              ),
            ),
            Divider(height: 1, color: tokens.border),
            if (ids.isEmpty)
              _Empty(canPin: timeline.canPin)
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: LoafSpace.x2),
                  itemCount: ids.length,
                  itemBuilder: (context, i) => _row(context, ids[i]),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _row(BuildContext context, String id) {
    final timeline = widget.timeline;
    final loaded = timeline.messages.where((m) => m.id == id).firstOrNull;
    final unpin = timeline.canPin ? () => timeline.unpin(id) : null;
    if (loaded != null) {
      return _PinRow(message: loaded, onUnpin: unpin, onOpen: () => _open(id));
    }
    final fetch = _fetches[id] ??= timeline.fetch(id);
    return FutureBuilder(
      future: fetch,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _StateRow(
            text: "couldn't load · try again",
            onTap: () => setState(() {
              _fetches.remove(id);
            }),
            onUnpin: unpin,
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return _StateRow(text: 'loading…', onUnpin: unpin);
        }
        final message = snapshot.data;
        if (message == null) {
          return _StateRow(text: messageUnavailable, onUnpin: unpin);
        }
        return _PinRow(
          message: message,
          onUnpin: unpin,
          onOpen: () => _open(id),
        );
      },
    );
  }

  /// Closes the list, then jumps: the conversation underneath does the
  /// bringing into view.
  void _open(String id) {
    Navigator.pop(context);
    widget.timeline.jumpTo(id);
  }
}

class _PinRow extends StatelessWidget {
  const _PinRow({
    required this.message,
    required this.onOpen,
    required this.onUnpin,
  });

  final Message message;
  final VoidCallback onOpen;
  final VoidCallback? onUnpin;

  /// What the row says of the message: its words, else what it is, as a
  /// reply's quote says it.
  (String, bool) get _words => message.locked
      ? ('an encrypted message', true)
      : message.media != null
      ? (quoteOf(message), false)
      : (
          plainTextOf(
            parseMessage(formatted: message.formatted, body: message.body),
          ),
          false,
        );

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final (words, italic) = _words;
    final author = message.author;
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          LoafSpace.x4,
          LoafSpace.x3,
          LoafSpace.x2,
          LoafSpace.x3,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LoafAvatar(
              label: author.initials,
              color: author.color,
              size: 32,
              image: author.avatar,
              textStyle: loafBody(12, 600),
            ),
            const SizedBox(width: LoafSpace.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          author.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: loafBody(
                            13,
                            600,
                          ).copyWith(color: tokens.nameColor(author.role)),
                        ),
                      ),
                      const SizedBox(width: LoafSpace.x2),
                      Text(
                        formatMessageTime(message.sentAt),
                        style: loafBody(
                          11,
                          400,
                        ).copyWith(color: tokens.textMuted),
                      ),
                    ],
                  ),
                  const SizedBox(height: LoafSpace.x1),
                  Text(
                    words,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: loafBody(13, 400, height: 1.4).copyWith(
                      color: italic ? tokens.textMuted : tokens.textBody,
                      fontStyle: italic ? FontStyle.italic : null,
                    ),
                  ),
                ],
              ),
            ),
            if (onUnpin != null) _UnpinButton(onUnpin: onUnpin!),
          ],
        ),
      ),
    );
  }
}

/// A row with no message to draw yet, or at all. [onTap] is the try-again
/// of a failed fetch.
class _StateRow extends StatelessWidget {
  const _StateRow({required this.text, this.onTap, required this.onUnpin});

  final String text;
  final VoidCallback? onTap;
  final VoidCallback? onUnpin;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          LoafSpace.x4,
          LoafSpace.x3,
          LoafSpace.x2,
          LoafSpace.x3,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                text,
                style: loafBody(13, 400).copyWith(
                  color: tokens.textMuted,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
            if (onUnpin != null) _UnpinButton(onUnpin: onUnpin!),
          ],
        ),
      ),
    );
  }
}

class _UnpinButton extends StatelessWidget {
  const _UnpinButton({required this.onUnpin});

  final VoidCallback onUnpin;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return IconButton(
      tooltip: 'Unpin',
      onPressed: onUnpin,
      icon: Icon(LucideIcons.pinOff, size: 18, color: tokens.textMuted),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.canPin});

  final bool canPin;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: LoafSpace.x4,
        vertical: LoafSpace.x6,
      ),
      child: Column(
        children: [
          Icon(LucideIcons.pin, size: 28, color: tokens.textMuted),
          const SizedBox(height: LoafSpace.x2),
          Text(
            'nothing pinned yet',
            style: loafBody(14, 500).copyWith(color: tokens.textBody),
          ),
          if (canPin) ...[
            const SizedBox(height: LoafSpace.x1),
            Text(
              'pin a message from its menu',
              style: loafBody(12, 400).copyWith(color: tokens.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}
