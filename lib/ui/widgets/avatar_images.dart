/// How an [AvatarRef] becomes pixels. The UI only knows this interface; the
/// backend that minted the refs supplies the implementation.
library;

import 'package:flutter/widgets.dart';

import '../model/models.dart';

abstract interface class AvatarImages {
  /// Null draws the initials.
  ImageProvider? resolve(AvatarRef ref, double physicalSize);
}

/// Every avatar stays on its initials.
class NoAvatarImages implements AvatarImages {
  const NoAvatarImages();

  @override
  ImageProvider? resolve(AvatarRef ref, double physicalSize) => null;
}

class AvatarImagesScope extends InheritedWidget {
  const AvatarImagesScope({
    super.key,
    required this.images,
    required super.child,
  });

  final AvatarImages images;

  /// Without a scope (a widget test, a lone page) avatars keep their initials.
  static AvatarImages of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AvatarImagesScope>()?.images ??
      const NoAvatarImages();

  @override
  bool updateShouldNotify(AvatarImagesScope old) => images != old.images;
}
