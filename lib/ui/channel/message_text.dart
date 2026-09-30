/// Draws a message's [Block]s in the app's type: paragraphs, quotes, lists
/// and code, with links that open in the browser, mention pills, and
/// spoilers that stay hidden until asked.
///
/// Everything is text spans and plain boxes, so a [SelectionArea] around it
/// selects across all of it on a computer, links included.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../platform.dart';
import '../theme/loaf_theme.dart';
import 'message_markup.dart';

/// Opens a link from a message in the system's own browser (or mail app),
/// never inside this one. Replaced in tests.
Future<bool> Function(Uri url) openMessageLink = _openInBrowser;

Future<bool> _openInBrowser(Uri url) =>
    launchUrl(url, mode: LaunchMode.externalApplication);

/// [blocks] as text, one line per paragraph: what a one-line quote of the
/// message shows.
String plainTextOf(List<Block> blocks) => blocks
    .map(
      (b) => switch (b) {
        Paragraph(:final runs) ||
        Heading(:final runs) => runs.map((r) => r.text).join(),
        CodeBlock(:final code) => code,
        Quote(:final children) => plainTextOf(children),
        ListBlock(:final items) => items.map(plainTextOf).join(' '),
        Rule() => '',
      },
    )
    .where((line) => line.isNotEmpty)
    .join(' ')
    .replaceAll('\n', ' ');

class MessageText extends StatefulWidget {
  const MessageText({
    super.key,
    required this.blocks,
    required this.style,
    this.trailing,
    this.you,
  });

  final List<Block> blocks;

  /// The body style; everything else is set relative to it.
  final TextStyle style;

  /// Set after the last line, such as the "(edited)" mark.
  final InlineSpan? trailing;

  /// Your user id: a mention of you stands out from mentions of others.
  final String? you;

  @override
  State<MessageText> createState() => _MessageTextState();
}

class _MessageTextState extends State<MessageText> {
  /// Spoilers revealed so far, by number. A reveal lasts as long as the
  /// message is on screen.
  final _revealed = <int>{};

  /// Every recogniser the last build handed out. Spans are rebuilt with the
  /// message, and a recogniser has to be disposed by whoever made it.
  final _recognizers = <GestureRecognizer>[];

  /// The link under the pointer and where the pointer is, for the preview
  /// of its address. A notifier rather than state: rebuilding the text on
  /// hover would replace the span being hovered, which would leave it.
  final _hover = ValueNotifier<(Uri, Offset)?>(null);
  final _preview = OverlayPortalController();

  @override
  void dispose() {
    _disposeRecognizers();
    _hover.dispose();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  TapGestureRecognizer _onTap(VoidCallback onTap) {
    final recognizer = TapGestureRecognizer()..onTap = onTap;
    _recognizers.add(recognizer);
    return recognizer;
  }

  void _enterLink(Uri link, PointerEnterEvent event) {
    _hover.value = (link, event.position);
    _preview.show();
  }

  void _exitLink(Uri link) {
    // Moving from one link straight to the next can deliver the second
    // enter before the first exit; only the link still shown hides it.
    if (_hover.value?.$1 != link) return;
    _hover.value = null;
    _preview.hide();
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final tokens = LoafTokens.of(context);
    final body = _Blocks(
      blocks: widget.blocks,
      style: widget.style,
      trailing: widget.trailing,
      span: (run, style) => _span(run, style, tokens),
    );
    if (!isDesktop) return body;
    return OverlayPortal(
      controller: _preview,
      overlayChildBuilder: (context) => _LinkPreview(hover: _hover),
      child: body,
    );
  }

  InlineSpan _span(Run run, TextStyle base, LoafTokens tokens) {
    var style = base;
    final s = run.style;
    if (s.code) {
      style = loafMono((base.fontSize ?? 15) * 0.87)
          .copyWith(color: tokens.textStrong, backgroundColor: tokens.border);
    }
    if (s.bold) {
      style = style.copyWith(
        fontWeight: FontWeight.w600,
        fontVariations: const [FontVariation('wght', 600)],
      );
    }
    if (s.italic) style = style.copyWith(fontStyle: FontStyle.italic);
    final link = run.link;
    style = style.copyWith(
      decoration: TextDecoration.combine([
        if (s.strike) TextDecoration.lineThrough,
        if (s.underline || link != null) TextDecoration.underline,
      ]),
      decorationColor: link != null ? tokens.textMuted : null,
    );
    if (link != null) style = style.copyWith(color: tokens.textStrong);

    final mention = run.mention;
    if (mention != null) {
      final mine = mention == widget.you;
      style = style.copyWith(
        color: mine ? tokens.accent : tokens.textStrong,
        backgroundColor: mine ? tokens.accentSoft : tokens.border,
        fontWeight: FontWeight.w600,
        fontVariations: const [FontVariation('wght', 600)],
      );
    }

    final spoiler = run.spoiler;
    if (spoiler != null && !_revealed.contains(spoiler)) {
      // Hidden: a solid bar the text's own shape, which a tap lifts. The
      // text is still there to select, which is also how it is copied.
      return TextSpan(
        text: run.text,
        style: style.copyWith(
          color: tokens.textMuted,
          backgroundColor: tokens.textMuted,
          decoration: TextDecoration.none,
        ),
        recognizer: _onTap(() => setState(() => _revealed.add(spoiler))),
        mouseCursor: SystemMouseCursors.click,
      );
    }
    if (spoiler != null) {
      style = style.copyWith(
        backgroundColor: style.backgroundColor ?? tokens.border,
      );
    }

    if (link == null) return TextSpan(text: run.text, style: style);
    return TextSpan(
      text: run.text,
      style: style,
      recognizer: _onTap(() => openMessageLink(link)),
      mouseCursor: SystemMouseCursors.click,
      onEnter: isDesktop ? (event) => _enterLink(link, event) : null,
      onExit: isDesktop ? (_) => _exitLink(link) : null,
    );
  }
}

typedef _SpanBuilder = InlineSpan Function(Run run, TextStyle style);

class _Blocks extends StatelessWidget {
  const _Blocks({
    required this.blocks,
    required this.style,
    required this.span,
    this.trailing,
  });

  final List<Block> blocks;
  final TextStyle style;
  final _SpanBuilder span;
  final InlineSpan? trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    // The trailing mark rides on the last paragraph where there is one, so
    // it sits after the words rather than on a line of its own.
    final lastText = blocks.lastIndexWhere((b) => b is Paragraph);
    final trailsText = trailing != null && lastText == blocks.length - 1;
    final children = <Widget>[
      for (var i = 0; i < blocks.length; i++)
        _block(
          blocks[i],
          tokens,
          trailing: trailsText && i == lastText ? trailing : null,
        ),
      if (trailing != null && !trailsText) Text.rich(trailing!),
    ];
    if (children.length == 1) return children.single;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: LoafSpace.x2),
          children[i],
        ],
      ],
    );
  }

  Widget _block(Block block, LoafTokens tokens, {InlineSpan? trailing}) =>
      switch (block) {
        Paragraph(:final runs) => Text.rich(
          TextSpan(
            style: style,
            children: [for (final r in runs) span(r, style), ?trailing],
          ),
        ),
        Heading(:final level, :final runs) => _heading(level, runs, tokens),
        CodeBlock(:final code) => _code(code, tokens),
        Quote(:final children) => _quote(children, tokens),
        ListBlock() => _list(block),
        Rule() => Divider(height: LoafSpace.x3, color: tokens.border),
      };

  Widget _heading(int level, List<Run> runs, LoafTokens tokens) {
    final size = switch (level) {
      1 => 22.0,
      2 => 19.0,
      3 => 17.0,
      _ => style.fontSize ?? 15,
    };
    final heading = level <= 3
        ? loafDisplay(size, 600, height: 1.3)
        : loafBody(size, 600, height: 1.4);
    final s = heading.copyWith(color: tokens.textStrong);
    return Text.rich(
      TextSpan(style: s, children: [for (final r in runs) span(r, s)]),
    );
  }

  Widget _code(String code, LoafTokens tokens) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(
      horizontal: LoafSpace.x3,
      vertical: LoafSpace.x2,
    ),
    decoration: BoxDecoration(
      color: tokens.sunken,
      border: Border.all(color: tokens.border),
      borderRadius: BorderRadius.circular(LoafRadius.md),
    ),
    // Code keeps its lines: a long one scrolls rather than wraps.
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Text(
        code,
        style: loafMono(13).copyWith(color: tokens.textStrong, height: 1.5),
      ),
    ),
  );

  Widget _quote(List<Block> children, LoafTokens tokens) => Container(
    padding: const EdgeInsets.only(left: LoafSpace.x3),
    decoration: BoxDecoration(
      border: Border(left: BorderSide(color: tokens.borderStrong, width: 3)),
    ),
    child: _Blocks(
      blocks: children,
      style: style.copyWith(color: tokens.textMuted),
      span: span,
    ),
  );

  Widget _list(ListBlock list) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (var i = 0; i < list.items.length; i++)
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The marker is layout, not words: selecting the list copies
            // its items.
            SelectionContainer.disabled(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: LoafSpace.x5),
                child: Padding(
                  padding: const EdgeInsets.only(right: LoafSpace.x1),
                  child: Text(
                    list.ordered ? '${list.start + i}.' : '•',
                    style: style,
                  ),
                ),
              ),
            ),
            Expanded(
              child: _Blocks(blocks: list.items[i], style: style, span: span),
            ),
          ],
        ),
    ],
  );
}

/// A link's address by the pointer, as a browser shows it in its status
/// bar: what the link says is not always where it goes.
class _LinkPreview extends StatelessWidget {
  const _LinkPreview({required this.hover});

  final ValueNotifier<(Uri, Offset)?> hover;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    return IgnorePointer(
      child: ValueListenableBuilder(
        valueListenable: hover,
        builder: (context, value, _) {
          if (value == null || overlay == null) return const SizedBox.shrink();
          final (link, global) = value;
          return CustomSingleChildLayout(
            delegate: _BelowPointer(overlay.globalToLocal(global)),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: tokens.card,
                  border: Border.all(color: tokens.border),
                  borderRadius: BorderRadius.circular(LoafRadius.sm),
                  boxShadow: tokens.shadowMd,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: LoafSpace.x2,
                    vertical: LoafSpace.x1,
                  ),
                  child: Text(
                    link.toString(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: loafMono(11).copyWith(color: tokens.textMuted),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Just below and right of the pointer, kept inside the window.
class _BelowPointer extends SingleChildLayoutDelegate {
  const _BelowPointer(this.pointer);

  final Offset pointer;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size child) {
    const gap = 16.0;
    final x = (pointer.dx + gap / 2).clamp(0.0, size.width - child.width);
    var y = pointer.dy + gap;
    if (y + child.height > size.height) y = pointer.dy - gap - child.height;
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_BelowPointer old) => old.pointer != pointer;
}
