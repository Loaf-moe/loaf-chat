/// A picture, full window, for Linux, where there is no Quick Look to hand it
/// to. Scroll or pinch to zoom, drag to pan, Escape to close.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../mock/fixtures.dart';
import '../theme/loaf_theme.dart';
import 'media_open.dart';

class ImageViewer extends StatefulWidget {
  const ImageViewer({super.key, required this.provider, required this.media});

  final ImageProvider provider;
  final Media media;

  @override
  State<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<ImageViewer> {
  final _transform = TransformationController();

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = loafBody(14, 500).copyWith(color: Colors.white);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.maybePop(context),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              // InteractiveViewer's own handling already turns the wheel
              // into zoom about the pointer, and a trackpad's pinch too.
              Positioned.fill(
                child: InteractiveViewer(
                  transformationController: _transform,
                  minScale: 1,
                  maxScale: 8,
                  child: Center(
                    child: Image(
                      image: widget.provider,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => Text(
                        "couldn't show this picture",
                        style: style.copyWith(color: Colors.white70),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: _Bar(media: widget.media, style: style),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.media, required this.style});

  final Media media;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x99000000), Color(0x00000000)],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.all(LoafSpace.x2),
          child: Row(
            children: [
              const SizedBox(width: LoafSpace.x2),
              Expanded(
                child: SelectableText(media.name, style: style, maxLines: 1),
              ),
              TextButton.icon(
                onPressed: () => saveMediaAs(context, media),
                icon: const Icon(LucideIcons.download, color: Colors.white),
                label: Text('Save as…', style: style),
              ),
              IconButton(
                tooltip: 'Close (Esc)',
                onPressed: () => Navigator.maybePop(context),
                icon: const Icon(LucideIcons.x, color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
