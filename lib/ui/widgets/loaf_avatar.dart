/// The one avatar every person, room and space is drawn with: a label on a
/// colour, and their picture over it when there is one. Callers own the label
/// and the type; this owns the shape.
library;

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
                    child: _clip(_picture(provider)),
                  ),
                if (whole != null)
                  Padding(
                    padding: border?.dimensions ?? EdgeInsets.zero,
                    child: _clip(_picture(whole, gapless: true)),
                  ),
              ],
            ),
    );
  }

  /// Fades in once decoded, so a slow picture never flashes; a failed one
  /// leaves what is under it.
  Widget _picture(ImageProvider provider, {bool gapless = false}) => Image(
    image: provider,
    fit: BoxFit.cover,
    width: size,
    height: size,
    gaplessPlayback: gapless,
    frameBuilder: (_, child, frame, sync) => sync
        ? child
        : AnimatedOpacity(
            opacity: frame == null ? 0 : 1,
            duration: const Duration(milliseconds: 150),
            child: child,
          ),
    errorBuilder: (_, _, _) => const SizedBox.shrink(),
  );

  Widget _clip(Widget child) => radius == null
      ? ClipOval(child: child)
      : ClipRRect(borderRadius: BorderRadius.circular(radius!), child: child);
}
