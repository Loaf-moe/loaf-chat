/// A message's picture, video, sound or file, drawn under (or instead of)
/// its words. Which bytes go in it is the [MediaSource]'s business.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../mock/fixtures.dart';
import '../model/media_source.dart';
import '../platform.dart';
import '../theme/loaf_theme.dart';
import 'media_open.dart';

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

class MediaRow extends StatefulWidget {
  /// The picture or video frame, for tests to measure.
  @visibleForTesting
  static const pictureKey = ValueKey('media-picture');

  const MediaRow({
    super.key,
    required this.media,
    this.uploaded,
    this.onOpen,
    this.onRetry,
  });

  final Media media;

  /// How much of an outgoing file has gone up, 0 to 1.
  final double? uploaded;

  /// Null draws no affordance: the row is a picture, not a button.
  final VoidCallback? onOpen;

  /// Starts the preview's download again after it failed. Null draws no
  /// "try again": there would be nothing behind it.
  final VoidCallback? onRetry;

  @override
  State<MediaRow> createState() => _MediaRowState();
}

class _MediaRowState extends State<MediaRow> {
  Media get media => widget.media;

  /// The preview failed and has not been asked for again.
  var _failed = false;

  /// Bumped on retry so the [Image] resolves afresh.
  var _attempt = 0;

  /// On a computer the media takes focus when clicked, and Space then opens
  /// it, as in Finder.
  final _focus = FocusNode(debugLabel: 'media');
  var _focused = false;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  /// Reported from a build, so it lands after the frame.
  void _fail() {
    if (_failed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _failed = true);
    });
  }

  void _retry(ImageProvider preview) {
    widget.onRetry?.call();
    // The failed load is not cached, but a pending one may be.
    PaintingBinding.instance.imageCache.evict(preview);
    setState(() {
      _failed = false;
      _attempt++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final uploaded = widget.uploaded;
    final tokens = LoafTokens.of(context);
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

  /// Wraps [child] in a tap target, only when there is something to open,
  /// with a ring over it while its file comes for an open.
  Widget _tappable(Widget child, double radius) {
    final onOpen = widget.onOpen;
    // A failed picture's one control is "try again": nothing lies over it.
    if (onOpen == null || _failed) return child;
    final tokens = LoafTokens.of(context);
    final target = Stack(
      children: [
        child,
        Positioned.fill(
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: () {
                if (isDesktop) _focus.requestFocus();
                onOpen();
              },
              canRequestFocus: false,
              borderRadius: BorderRadius.circular(radius),
            ),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: ListenableBuilder(
              listenable: fetchingMedia,
              builder: (context, _) => fetchingMedia.contains(media)
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(radius),
                      child: _Fetching(
                        file: MediaSourceScope.of(context).open(media),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
        if (_focused)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: tokens.accent, width: 2),
                  borderRadius: BorderRadius.circular(radius),
                ),
              ),
            ),
          ),
      ],
    );
    if (!isDesktop) return target;
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.space): _OpenIntent(),
      },
      child: Actions(
        actions: {
          _OpenIntent: CallbackAction<_OpenIntent>(onInvoke: (_) => onOpen()),
        },
        child: Focus(
          focusNode: _focus,
          onFocusChange: (focused) => setState(() => _focused = focused),
          child: target,
        ),
      ),
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
    final bigGif = media.animated && (media.size ?? 0) > inlinePreviewCap;

    final picture = SizedBox(
      key: MediaRow.pictureKey,
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
                key: ValueKey(_attempt),
                image: preview,
                fit: BoxFit.cover,
                // Nothing to draw yet: keep the placeholder, then fade in.
                frameBuilder: (_, child, frame, sync) => AnimatedOpacity(
                  opacity: sync || frame != null ? 1 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: child,
                ),
                errorBuilder: (_, _, _) {
                  _fail();
                  return _Failed(
                    onRetry: widget.onRetry == null
                        ? null
                        : () => _retry(preview),
                  );
                },
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

class _OpenIntent extends Intent {
  const _OpenIntent();
}

/// How far a file being fetched to open has got. The download cannot be
/// stopped once running, so this is only a ring, never a button.
class _Fetching extends StatelessWidget {
  const _Fetching({required this.file});

  /// The same file the open is waiting on: opens are shared.
  final MediaFile file;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0x66000000),
    child: Center(
      child: ListenableBuilder(
        listenable: file,
        builder: (context, _) {
          final total = file.total;
          return CircularProgressIndicator(
            value: total == null || total == 0
                ? null
                : (file.received / total).clamp(0.0, 1.0),
            color: Colors.white,
          );
        },
      ),
    ),
  );
}

/// What a picture that would not load says, with the way forward.
class _Failed extends StatelessWidget {
  const _Failed({this.onRetry});

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final style = loafBody(12, 400).copyWith(color: tokens.textMuted);
    return ColoredBox(
      color: tokens.sunken,
      child: Center(
        child: Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              onRetry == null ? "couldn't load" : "couldn't load · ",
              style: style,
            ),
            if (onRetry != null)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onRetry,
                child: Text(
                  'try again',
                  style: style.copyWith(
                    decoration: TextDecoration.underline,
                    color: tokens.textStrong,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
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
