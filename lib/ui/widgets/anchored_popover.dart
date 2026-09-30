/// A desktop popover that opens beside the thing that opened it — above it
/// where there is room, below where there is not — and never on top of it.
///
/// `showMenu` can only place a menu's top edge, so a short popover opened
/// from a button near the bottom of the window lands over the button. This
/// measures the popover first and places it whole.
library;

import 'package:flutter/material.dart';

import '../theme/loaf_theme.dart';
import 'avatar_images.dart';

/// Opens [builder]'s popover next to [anchor] (global coordinates). A click
/// outside or Escape closes it.
Future<T?> showAnchoredPopover<T>(
  BuildContext context, {
  required Rect anchor,
  required WidgetBuilder builder,
}) {
  final tokens = LoafTokens.of(context);
  final from = context;
  return Navigator.of(context).push(
    _AnchoredPopoverRoute<T>(
      anchor: anchor,
      capturedThemes: InheritedTheme.capture(
        from: context,
        to: Navigator.of(context).context,
      ),
      builder: (context) => Material(
        color: tokens.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LoafRadius.lg),
          side: BorderSide(color: tokens.border),
        ),
        clipBehavior: Clip.antiAlias,
        // The route is on the root navigator, above the shell's scope.
        child: AvatarImagesScope.carry(from, child: builder(context)),
      ),
    ),
  );
}

class _AnchoredPopoverRoute<T> extends PopupRoute<T> {
  _AnchoredPopoverRoute({
    required this.anchor,
    required this.capturedThemes,
    required this.builder,
  });

  final Rect anchor;
  final CapturedThemes capturedThemes;
  final WidgetBuilder builder;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Dismiss';

  @override
  Duration get transitionDuration => LoafMotion.fast;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => capturedThemes.wrap(
    CustomSingleChildLayout(
      delegate: _BesideAnchor(anchor),
      child: Builder(builder: builder),
    ),
  );

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => FadeTransition(opacity: animation, child: child);
}

/// Above the anchor if the popover fits there, else below. Horizontally it
/// lines up with whichever edge of the anchor faces the middle of the
/// window, so it grows into the room rather than off the edge.
class _BesideAnchor extends SingleChildLayoutDelegate {
  const _BesideAnchor(this.anchor);

  final Rect anchor;

  static const _gap = LoafSpace.x2;
  static const _margin = LoafSpace.x2;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(constraints.biggest)
          .deflate(const EdgeInsets.all(_margin));

  @override
  Offset getPositionForChild(Size size, Size child) {
    final leftSide = anchor.center.dx < size.width / 2;
    final x = (leftSide ? anchor.left : anchor.right - child.width).clamp(
      _margin,
      size.width - child.width - _margin,
    );
    final above = anchor.top - _gap - child.height;
    final y = above >= _margin
        ? above
        : (anchor.bottom + _gap).clamp(
            _margin,
            size.height - child.height - _margin,
          );
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_BesideAnchor oldDelegate) =>
      anchor != oldDelegate.anchor;
}
