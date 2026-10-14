/// What a message's link leads to, drawn under its words. What it shows is
/// the [LinkPreviews]' business.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/link_previews.dart';
import '../platform.dart';
import '../theme/loaf_theme.dart';
import 'message_text.dart';

const _maxWidth = 400.0;
const _height = 88.0;

/// How long a link goes without saying it is loading: for a quick answer
/// the line would only flicker.
const _quiet = Duration(milliseconds: 300);

class LinkPreviewCard extends StatefulWidget {
  const LinkPreviewCard({super.key, required this.link});

  final Uri link;

  @visibleForTesting
  static const cardKey = ValueKey('link-preview-card');

  @visibleForTesting
  static const lineKey = ValueKey('link-preview-line');

  @override
  State<LinkPreviewCard> createState() => _LinkPreviewCardState();
}

class _LinkPreviewCardState extends State<LinkPreviewCard> {
  LinkPreviews? _previews;
  late ValueListenable<LinkPreviewState> _state;
  Timer? _timer;
  var _slow = false;
  final _focus = FocusNode(debugLabel: 'link preview');
  var _focused = false;

  // Asked here and never in build: a row is built on every change to its
  // conversation.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final previews = LinkPreviewsScope.of(context);
    if (identical(previews, _previews)) return;
    if (_previews != null) _state.removeListener(_changed);
    _previews = previews;
    _ask();
  }

  @override
  void didUpdateWidget(LinkPreviewCard old) {
    super.didUpdateWidget(old);
    if (old.link == widget.link) return;
    _state.removeListener(_changed);
    _ask();
  }

  void _ask() {
    _state = _previews!.of(widget.link)..addListener(_changed);
    _focused = false;
    _wait();
  }

  void _wait() {
    _timer?.cancel();
    _slow = false;
    if (_state.value is! LinkPreviewLoading) return;
    _timer = Timer(_quiet, () {
      if (mounted) setState(() => _slow = true);
    });
  }

  void _changed() => setState(_wait);

  @override
  void dispose() {
    _timer?.cancel();
    _state.removeListener(_changed);
    _focus.dispose();
    super.dispose();
  }

  void _open() => unawaited(openMessageLink(widget.link));

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final child = switch (_state.value) {
      LinkPreviewNone() => null,
      LinkPreviewLoading() =>
        _slow
            ? Text(
                'loading preview…',
                key: LinkPreviewCard.lineKey,
                style: loafBody(12, 400).copyWith(color: tokens.textMuted),
              )
            : null,
      LinkPreviewReady(:final preview) => _card(tokens, preview),
    };
    if (child == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: LoafSpace.x2),
      child: child,
    );
  }

  Widget _card(LoafTokens tokens, LinkPreview preview) {
    final radius = BorderRadius.circular(LoafRadius.lg);
    final image = preview.image;
    final card = LayoutBuilder(
      builder: (context, constraints) => SizedBox(
        key: LinkPreviewCard.cardKey,
        width: isDesktop
            ? math.min(constraints.maxWidth, _maxWidth)
            : constraints.maxWidth,
        height: _height,
        child: Stack(
          children: [
            Positioned.fill(
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: tokens.card,
                  borderRadius: radius,
                ),
                // Over the picture, not around it: a border in the
                // decoration would inset it.
                foregroundDecoration: BoxDecoration(
                  border: Border.all(color: tokens.border),
                  borderRadius: radius,
                ),
                child: Row(
                  children: [
                    if (image != null)
                      Image(
                        image: image,
                        width: _height,
                        height: _height,
                        fit: BoxFit.cover,
                        // The words take the room a picture would have had.
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    Expanded(child: _words(tokens, preview)),
                  ],
                ),
              ),
            ),
            Positioned.fill(
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: () {
                    if (isDesktop) _focus.requestFocus();
                    _open();
                  },
                  canRequestFocus: false,
                  borderRadius: radius,
                ),
              ),
            ),
            if (_focused)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: tokens.accent, width: 2),
                      borderRadius: radius,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    if (!isDesktop) return card;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): _open,
        const SingleActivator(LogicalKeyboardKey.space): _open,
      },
      child: Focus(
        focusNode: _focus,
        onFocusChange: (focused) => setState(() => _focused = focused),
        child: card,
      ),
    );
  }

  Widget _words(LoafTokens tokens, LinkPreview preview) {
    final muted = loafBody(
      12,
      400,
      height: 1.3,
    ).copyWith(color: tokens.textMuted);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: LoafSpace.x3,
        vertical: LoafSpace.x2,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.link.host,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: muted,
          ),
          if (preview.title case final title?)
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: loafBody(
                14,
                600,
                height: 1.3,
              ).copyWith(color: tokens.textStrong),
            ),
          if (preview.description case final description?)
            // Gives way first when large text leaves no room for it.
            Flexible(
              child: Text(
                description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: muted,
              ),
            ),
        ],
      ),
    );
  }
}
