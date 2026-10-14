/// The one avatar every person, room and space is drawn with: a label on a
/// colour, and their picture over it when there is one. Callers own the label
/// and the type; this owns the shape.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../model/models.dart';
import 'avatar_images.dart';

class LoafAvatar extends StatelessWidget {
  const LoafAvatar({
    super.key,
    required this.label,
    required this.color,
    required this.size,
    required this.textStyle,
    this.radius,
    this.boxShadow,
    this.border,
    this.image,
    this.original = false,
  });

  /// Already-computed initials, drawn as given.
  final String label;
  final Color color;
  final double size;
  final TextStyle textStyle;

  /// Null draws a circle; otherwise a rounded square with this corner radius.
  final double? radius;
  final List<BoxShadow>? boxShadow;

  /// Drawn on the same decoration as the colour, for the call bars' ring.
  final BoxBorder? border;

  /// Null, or a ref the scope cannot resolve, leaves the initials.
  final AvatarRef? image;

  /// Also fetch the upload itself and draw it over the thumbnail: a GIF
  /// plays, where a thumbnail is always still.
  final bool original;

  @override
  Widget build(BuildContext context) {
    final ref = image;
    final images = AvatarImagesScope.of(context);
    final provider = ref == null
        ? null
        : images.resolve(ref, size * MediaQuery.devicePixelRatioOf(context));
    final whole = ref == null || !original ? null : images.original(ref);
    final initials = Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        shape: radius == null ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: radius == null ? null : BorderRadius.circular(radius!),
        boxShadow: boxShadow,
        border: border,
      ),
      child: Text(label, style: textStyle.copyWith(color: Colors.white)),
    );
    return SizedBox(
      width: size,
      height: size,
      child: provider == null && whole == null
          ? initials
          : Stack(
              fit: StackFit.expand,
              children: [
                initials,
                // Inside the ring, so a picture never paints over it.
                if (provider != null)
                  Padding(
                    padding: border?.dimensions ?? EdgeInsets.zero,
                    child: AvatarPicture(provider: provider, radius: radius),
                  ),
                if (whole != null)
                  Padding(
                    padding: border?.dimensions ?? EdgeInsets.zero,
                    child: AvatarPicture(
                      provider: whole,
                      radius: radius,
                      gapless: true,
                    ),
                  ),
              ],
            ),
    );
  }
}

/// The picture as the shape's own fill: an image shader on the circle or
/// rounded square, never a child under a clip. Impeller fills a round shape
/// with an analytic, antialiased edge, but a clip is a stencil whose edge is
/// only as smooth as the target's MSAA. Linux's GLES target has none, so a
/// clipped picture came out stair-stepped, the colour behind showing at the
/// steps.
class AvatarPicture extends StatefulWidget {
  const AvatarPicture({
    super.key,
    required this.provider,
    this.radius,
    this.gapless = false,
  });

  final ImageProvider provider;

  /// As [LoafAvatar.radius]: null is a circle.
  final double? radius;

  /// As [Image.gaplessPlayback]: a new provider keeps the old picture up
  /// until its own arrives, rather than dropping back to what is under it.
  final bool gapless;

  @override
  State<AvatarPicture> createState() => _AvatarPictureState();
}

class _AvatarPictureState extends State<AvatarPicture> {
  ImageStream? _stream;
  ImageInfo? _info;

  // A failed picture leaves the initials; there is nothing to report.
  late final _listener = ImageStreamListener(_onImage, onError: (_, _) {});

  /// Already decoded when asked for: shown at once rather than faded in.
  bool _sync = false;
  bool _resolving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(AvatarPicture old) {
    super.didUpdateWidget(old);
    if (old.provider != widget.provider) _resolve();
  }

  void _resolve() {
    final stream = widget.provider.resolve(
      createLocalImageConfiguration(context),
    );
    if (_stream != null && stream.key == _stream!.key) return;
    _stream?.removeListener(_listener);
    if (!widget.gapless) {
      _replace(null);
      _sync = false;
    }
    _stream = stream;
    // A cached picture calls back inside addListener, before the first build.
    _resolving = true;
    stream.addListener(_listener);
    _resolving = false;
  }

  void _onImage(ImageInfo info, bool synchronousCall) {
    if (_resolving) {
      _sync = _info == null && synchronousCall;
      _replace(info);
    } else {
      // Every frame of an animated avatar arrives here too.
      setState(() => _replace(info));
    }
  }

  void _replace(ImageInfo? info) {
    _info?.dispose();
    _info = info;
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    _replace(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _info?.image;
    final painted = image == null
        ? const SizedBox.expand()
        : CustomPaint(
            size: Size.infinite,
            painter: _PicturePainter(image, widget.radius),
          );
    // Fades in over the initials once decoded, so a slow avatar never
    // flashes. A single shaded draw takes the opacity itself: no layer.
    return _sync
        ? painted
        : AnimatedOpacity(
            opacity: image == null ? 0 : 1,
            duration: const Duration(milliseconds: 150),
            child: painted,
          );
  }
}

class _PicturePainter extends CustomPainter {
  _PicturePainter(this.image, this.radius);

  final ui.Image image;
  final double? radius;

  @override
  void paint(Canvas canvas, Size size) {
    // BoxFit.cover, centred: the shorter side fills, the longer is cropped.
    final scale = math.max(
      size.width / image.width,
      size.height / image.height,
    );
    final transform = Matrix4.identity()
      ..translateByDouble(
        (size.width - image.width * scale) / 2,
        (size.height - image.height * scale) / 2,
        0,
        1,
      )
      ..scaleByDouble(scale, scale, 1, 1);
    final paint = Paint()
      ..shader = ui.ImageShader(
        image,
        TileMode.clamp,
        TileMode.clamp,
        transform.storage,
        // Image's default, so the picture filters as it did.
        filterQuality: FilterQuality.medium,
      );
    final rect = Offset.zero & size;
    final r = radius;
    if (r == null) {
      canvas.drawOval(rect, paint);
    } else {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(r)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_PicturePainter old) =>
      old.image != image || old.radius != radius;
}
