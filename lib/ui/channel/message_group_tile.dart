/// Renders one [MessageGroup]: one avatar and header, then each message in
/// the run.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../mock/fixtures.dart';
import '../theme/loaf_theme.dart';

String _formatTime(DateTime time) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}';
}

class MessageGroupTile extends StatelessWidget {
  const MessageGroupTile({super.key, required this.group});

  final MessageGroup group;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final author = group.author;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Avatar(member: author),
        const SizedBox(width: LoafSpace.x3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    author.name,
                    style: loafBody(15, 600).copyWith(color: author.color),
                  ),
                  const SizedBox(width: LoafSpace.x2),
                  Text(
                    _formatTime(group.sentAt),
                    style: loafBody(11, 400).copyWith(color: tokens.textMuted),
                  ),
                ],
              ),
              const SizedBox(height: LoafSpace.x1),
              for (var i = 0; i < group.messages.length; i++) ...[
                if (i > 0) const SizedBox(height: 2),
                _MessageBody(message: group.messages[i]),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.member});

  final Member member;

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: 18,
      backgroundColor: member.color,
      child: Text(
        member.initials,
        style: loafBody(13, 600).copyWith(color: Colors.white),
      ),
    );
  }
}

class _MessageBody extends StatelessWidget {
  const _MessageBody({required this.message});

  final Message message;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final replyTo = message.replyTo;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (replyTo != null) _ReplyContext(replyTo: replyTo),
        SelectableText.rich(
          TextSpan(
            style: loafBody(
              15,
              400,
              height: 1.5,
            ).copyWith(color: tokens.textBody),
            children: [
              TextSpan(text: message.body),
              if (message.edited)
                TextSpan(
                  text: ' (edited)',
                  style: loafBody(11, 400).copyWith(color: tokens.textMuted),
                ),
            ],
          ),
        ),
        if (message.imageAspect != null) ...[
          const SizedBox(height: LoafSpace.x2),
          _ImagePlaceholder(aspect: message.imageAspect!),
        ],
        if (message.reactions.isNotEmpty) ...[
          const SizedBox(height: LoafSpace.x2),
          _ReactionsWrap(reactions: message.reactions),
        ],
      ],
    );
  }
}

class _ReplyContext extends StatelessWidget {
  const _ReplyContext({required this.replyTo});

  final Message replyTo;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: LoafSpace.x1),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 2,
              margin: const EdgeInsets.only(right: LoafSpace.x2),
              decoration: BoxDecoration(
                color: tokens.border,
                borderRadius: BorderRadius.circular(LoafRadius.sm),
              ),
            ),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: replyTo.author.name,
                      style: loafBody(
                        11,
                        600,
                      ).copyWith(color: replyTo.author.color),
                    ),
                    TextSpan(
                      text: '  ${replyTo.body}',
                      style: loafBody(
                        11,
                        400,
                      ).copyWith(color: tokens.textMuted),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImagePlaceholder extends StatelessWidget {
  const _ImagePlaceholder({required this.aspect});

  final double aspect;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: AspectRatio(
          aspectRatio: aspect,
          child: Container(
            decoration: BoxDecoration(
              color: tokens.sunken,
              border: Border.all(color: tokens.border),
              borderRadius: BorderRadius.circular(LoafRadius.lg),
            ),
            child: Icon(LucideIcons.image, color: tokens.textMuted),
          ),
        ),
      ),
    );
  }
}

class _ReactionsWrap extends StatelessWidget {
  const _ReactionsWrap({required this.reactions});

  final List<Reaction> reactions;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Wrap(
      spacing: LoafSpace.x2,
      runSpacing: LoafSpace.x2,
      children: [
        for (final reaction in reactions)
          Container(
            height: 26,
            padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x2),
            decoration: BoxDecoration(
              color: reaction.mine ? tokens.accentSoft : tokens.card,
              borderRadius: BorderRadius.circular(LoafRadius.full),
              border: Border.all(
                color: reaction.mine ? tokens.accent : tokens.border,
              ),
            ),
            // A Container with `alignment` and no width expands to the
            // parent's max width, which makes every pill full-bleed and
            // forces one per line. A min-size Row hugs the text instead.
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${reaction.emoji} ${reaction.count}',
                  style: loafBody(11, 600).copyWith(color: tokens.textBody),
                ),
              ],
            ),
          ),
        Container(
          height: 26,
          width: 26,
          decoration: BoxDecoration(
            color: tokens.card,
            borderRadius: BorderRadius.circular(LoafRadius.full),
            border: Border.all(color: tokens.border),
          ),
          alignment: Alignment.center,
          child: Icon(LucideIcons.smilePlus, size: 14, color: tokens.textMuted),
        ),
      ],
    );
  }
}
