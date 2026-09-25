/// A task that needs a moment of your attention: a bottom sheet on a phone,
/// a dialog on a computer. The new-message picker and adding a space both
/// open this way.
library;

import 'package:flutter/material.dart';

import '../members/presence_dot.dart';
import '../platform.dart';
import '../theme/loaf_theme.dart';

Future<T?> showAdaptivePanel<T>(
  BuildContext context, {
  required Widget child,
  double maxWidth = 440,
  double maxHeight = 580,
}) {
  final tokens = LoafTokens.of(context);
  // Routes sit above the shell, so carry its presence setting across the
  // way themes are carried: the panel's avatars follow it too.
  child = PresenceScope(shared: PresenceScope.sharedOf(context), child: child);
  if (isDesktop) {
    return showDialog<T>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: tokens.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LoafRadius.xl),
          side: BorderSide(color: tokens.border),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
          child: child,
        ),
      ),
    );
  }
  // Read outside the sheet: a bottom sheet strips the top inset from its
  // own MediaQuery.
  final statusBar = MediaQuery.paddingOf(context).top;
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: tokens.card,
    showDragHandle: true,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(LoafRadius.xxxl),
      ),
    ),
    // Rides up with the keyboard, and never taller than the room it
    // leaves: past that the drag handle slides under the status bar.
    builder: (context) {
      final media = MediaQuery.of(context);
      // The drag handle sits above the content and takes its own height.
      const handle = LoafSpace.x12;
      final room =
          media.size.height -
          media.viewInsets.bottom -
          statusBar -
          handle -
          LoafSpace.x4;
      return Padding(
        padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
        child: SizedBox(
          height: room.clamp(0.0, media.size.height * 0.8),
          child: SafeArea(top: false, child: child),
        ),
      );
    },
  );
}
