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

  /// Carries the scope [from] sees into [child]. Dialogs, sheets and popovers
  /// are routes on the root navigator, which sits above the shell that hosts
  /// the scope, so they can't see it. Each shared helper that opens one
  /// re-provides it here, the way it does the presence setting, rather than
  /// hoisting the scope above the navigator: the rooms that own the images
  /// are created and disposed by the shell, not by anything above it.
  static Widget carry(BuildContext from, {required Widget child}) =>
      AvatarImagesScope(images: of(from), child: child);

  @override
  bool updateShouldNotify(AvatarImagesScope old) => images != old.images;
}
