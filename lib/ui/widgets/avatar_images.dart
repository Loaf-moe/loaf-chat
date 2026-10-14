/// How an [AvatarRef] becomes pixels. The UI only knows this interface; the
/// backend that minted the refs supplies the implementation.
library;

import 'package:flutter/widgets.dart';

import '../model/models.dart';

abstract interface class AvatarImages {
  /// Null draws the initials.
  ImageProvider? resolve(AvatarRef ref, double physicalSize);

  /// The picture as uploaded, every frame of it. Null leaves the thumbnail.
  ImageProvider? original(AvatarRef ref);
}

/// Every avatar stays on its initials.
class NoAvatarImages implements AvatarImages {
  const NoAvatarImages();

  @override
  ImageProvider? resolve(AvatarRef ref, double physicalSize) => null;

  @override
  ImageProvider? original(AvatarRef ref) => null;
}

/// An [InheritedTheme], so a menu, dialog or sheet opened from under it
/// captures it along with the themes.
class AvatarImagesScope extends InheritedTheme {
  const AvatarImagesScope({
    super.key,
    required this.images,
    required super.child,
  });

  final AvatarImages images;

  @override
  Widget wrap(BuildContext context, Widget child) =>
      AvatarImagesScope(images: images, child: child);

  /// Without a scope (a widget test, a lone page) avatars keep their initials.
  static AvatarImages of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AvatarImagesScope>()?.images ??
      const NoAvatarImages();

  @override
  bool updateShouldNotify(AvatarImagesScope old) => images != old.images;
}
