/// A message's picture, video, sound or file, drawn under (or instead of)
/// its words. Which bytes go in it is the [MediaSource]'s business.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../mock/fixtures.dart';
import '../model/media_source.dart';
import '../platform.dart';
import '../theme/loaf_theme.dart';

/// A GIF this small animates in the row; a larger one waits for a tap.
const _gifInlineCap = 2000000;

const _maxWidth = 400.0;
const _maxHeight = 360.0;

/// What a picked file is, from its mime type.
MediaKind kindOf(String? mimeType) {
  final type = mimeType ?? '';
  if (type.startsWith('image/')) return MediaKind.image;
  if (type.startsWith('video/')) return MediaKind.video;
  if (type.startsWith('audio/')) return MediaKind.audio;
  return MediaKind.file;
}

/// One line saying what [m] is, for a reply's quote or the composer's banner:
/// its words, else what kind of thing it is, else its name.
String quoteOf(Message m) {
  if (m.body.isNotEmpty) return m.body;
  final media = m.media;
  if (media == null) return m.body;
  return switch (media.kind) {
    MediaKind.image => media.animated ? 'gif' : 'photo',
    MediaKind.video => 'video',
    MediaKind.audio => 'audio',
    MediaKind.file => media.name,
  };
}

/// Bytes as Finder says them: 1000s, one decimal at most.
String formatSize(int bytes) {
  String one(double n) {
    final s = n.toStringAsFixed(1);
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  if (bytes < 1000) return '$bytes B';
  if (bytes < 1000000) return '${one(bytes / 1000)} KB';
  return '${one(bytes / 1000000)} MB';
}

String _clock(Duration d) {
  final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '${d.inMinutes}:$seconds';
}

class MediaRow extends StatelessWidget {
  /// The picture or video frame, for tests to measure.
  @visibleForTesting
  static const pictureKey = ValueKey('media-picture');

  const MediaRow({super.key, required this.media, this.uploaded, this.onOpen});

  final Media media;

  /// How much of an outgoing file has gone up, 0 to 1.
  final double? uploaded;

  /// Null draws no affordance: the row is a picture, not a button.
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final uploaded = this.uploaded;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final column = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : _maxWidth;
            // A computer caps the width; a phone fills the column.
            final width = isDesktop ? column.clamp(0.0, _maxWidth) : column;
            return switch (media.kind) {
              MediaKind.image || MediaKind.video => _picture(context, width),
              MediaKind.audio || MediaKind.file => _card(context, width),
            };
          },
        ),
        if (uploaded != null)
          Padding(
            padding: const EdgeInsets.only(top: LoafSpace.x1),
            child: Text(
              'uploading ${(uploaded * 100).round()}%',
              style: loafBody(12, 400).copyWith(color: tokens.textMuted),
            ),
          ),
      ],
    );
  }

  /// Wraps [child] in a tap target, only when there is something to open.
  Widget _tappable(Widget child, double radius) {
    final onOpen = this.onOpen;
    if (onOpen == null) return child;
    return Stack(
      children: [
        child,
        Positioned.fill(
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onOpen,
              borderRadius: BorderRadius.circular(radius),
            ),
          ),
        ),
      ],
    );
  }

  Widget _picture(BuildContext context, double maxWidth) {
    final tokens = LoafTokens.of(context);
    final dimensions = media.dimensions;
    final aspect = dimensions == null || dimensions.isEmpty
        ? 4 / 3
        : dimensions.width / dimensions.height;
    var width = maxWidth;
    var height = width / aspect;
    if (height > _maxHeight) {
      height = _maxHeight;
      width = height * aspect;
    }

    final placeholder = DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.sunken,
        border: Border.all(color: tokens.border),
        borderRadius: BorderRadius.circular(LoafRadius.lg),
      ),
      child: Center(
        child: Icon(
          media.kind == MediaKind.video ? LucideIcons.video : LucideIcons.image,
          color: tokens.textMuted,
        ),
      ),
    );

    final source = MediaSourceScope.of(context);
    final preview = media.hasPreview
        ? source.preview(media, width * MediaQuery.devicePixelRatioOf(context))
        : null;
    // A big GIF shows the preview and a badge instead of playing.
    final bigGif = media.animated && (media.size ?? 0) > _gifInlineCap;

    final picture = SizedBox(
      key: pictureKey,
      width: width,
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          placeholder,
          if (preview != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(LoafRadius.lg),
              child: Image(
                image: preview,
                fit: BoxFit.cover,
                // Nothing to draw yet: keep the placeholder, then fade in.
                frameBuilder: (_, child, frame, sync) => AnimatedOpacity(
                  opacity: sync || frame != null ? 1 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: child,
                ),
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          if (media.kind == MediaKind.video) ...[
            const Center(child: _PlayBadge()),
            if (media.duration != null)
              Positioned(
                right: LoafSpace.x2,
                bottom: LoafSpace.x2,
                child: _Chip(_clock(media.duration!)),
              ),
          ],
          if (bigGif)
            const Positioned(
              left: LoafSpace.x2,
              bottom: LoafSpace.x2,
              child: _Chip('gif'),
            ),
        ],
      ),
    );
    return _tappable(picture, LoafRadius.lg);
  }

  Widget _card(BuildContext context, double width) {
    final tokens = LoafTokens.of(context);
    final size = media.size;
    final icon = switch (media.kind) {
      MediaKind.audio => LucideIcons.fileAudio,
      _ when media.mimeType == 'application/pdf' => LucideIcons.fileText,
      _ => LucideIcons.file,
    };
    final card = Container(
      width: width,
      padding: const EdgeInsets.all(LoafSpace.x3),
      decoration: BoxDecoration(
        color: tokens.card,
        border: Border.all(color: tokens.border),
        borderRadius: BorderRadius.circular(LoafRadius.lg),
      ),
      child: Row(
        children: [
          Icon(icon, size: 24, color: tokens.textMuted),
          const SizedBox(width: LoafSpace.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  media.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: loafBody(14, 600).copyWith(color: tokens.textStrong),
                ),
                if (size != null)
                  Text(
                    formatSize(size),
                    style: loafBody(12, 400).copyWith(color: tokens.textMuted),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    return _tappable(card, LoafRadius.lg);
  }
}

class _PlayBadge extends StatelessWidget {
  const _PlayBadge();

  @override
  Widget build(BuildContext context) => Container(
    width: 48,
    height: 48,
    decoration: const BoxDecoration(
      color: Color(0x99000000),
      shape: BoxShape.circle,
    ),
    child: const Icon(LucideIcons.play, color: Colors.white),
  );
}

class _Chip extends StatelessWidget {
  const _Chip(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(
      horizontal: LoafSpace.x2,
      vertical: LoafSpace.x1 / 2,
    ),
    decoration: BoxDecoration(
      color: const Color(0x99000000),
      borderRadius: BorderRadius.circular(LoafRadius.sm),
    ),
    child: Text(label, style: loafBody(12, 600).copyWith(color: Colors.white)),
  );
}
