/// What a link in a message leads to, as the backend can tell: a title, a
/// few words and a picture. The UI only knows this interface, so nothing
/// here ever sees where a preview came from.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

abstract interface class LinkPreviews {
  /// What is known of [link], shared by every row showing it. Asked of the
  /// backend on first call; a backend that got no answer may ask again on
  /// a later one.
  ValueListenable<LinkPreviewState> of(Uri link);
}

sealed class LinkPreviewState {
  const LinkPreviewState();
}

final class LinkPreviewLoading extends LinkPreviewState {
  const LinkPreviewLoading();
}

/// The backend has nothing to draw for the link.
final class LinkPreviewNone extends LinkPreviewState {
  const LinkPreviewNone();
}

final class LinkPreviewReady extends LinkPreviewState {
  const LinkPreviewReady(this.preview);
  final LinkPreview preview;
}

/// Always has something to draw: a title, a description or an image.
@immutable
class LinkPreview {
  const LinkPreview._(this.title, this.description, this.image);

  /// Null when there is nothing to draw. Text loses the space around it,
  /// and blank text counts as none.
  static LinkPreview? of({
    String? title,
    String? description,
    ImageProvider? image,
  }) {
    final t = _text(title);
    final d = _text(description);
    if (t == null && d == null && image == null) return null;
    return LinkPreview._(t, d, image);
  }

  static String? _text(String? raw) {
    final trimmed = raw?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  final String? title;
  final String? description;
  final ImageProvider? image;
}

/// No link has a preview.
class NoLinkPreviews implements LinkPreviews {
  const NoLinkPreviews();

  static final _none = ValueNotifier<LinkPreviewState>(const LinkPreviewNone());

  @override
  ValueListenable<LinkPreviewState> of(Uri link) => _none;
}

class LinkPreviewsScope extends InheritedWidget {
  const LinkPreviewsScope({
    super.key,
    required this.previews,
    required super.child,
  });

  final LinkPreviews previews;

  /// Without a scope (a widget test, a lone page) no link has a preview.
  static LinkPreviews of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<LinkPreviewsScope>()
          ?.previews ??
      const NoLinkPreviews();

  @override
  bool updateShouldNotify(LinkPreviewsScope old) => previews != old.previews;
}
