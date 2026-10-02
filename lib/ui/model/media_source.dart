/// How a [Media] becomes pixels and bytes. The UI only knows this interface;
/// the backend that minted the refs supplies the implementation, so nothing
/// here ever sees a URL, an mxc or a key.
library;

import 'package:flutter/widgets.dart';
import 'package:loaf_media/loaf_media.dart';

import 'models.dart';

/// The whole file on disk, started on first ask and shared by every caller.
abstract interface class MediaFile implements GrowingFile {
  /// Completes with the finished file's path; errors as [error] does.
  Future<String> get path;

  /// After a failure, starts again from nothing.
  void retry();

  /// Keeps the file through cache eviction while held. Balanced by [release].
  void hold();
  void release();
}

abstract interface class MediaSource {
  /// The row's picture: a thumbnail, or the image itself when it is small.
  /// Null when the row should offer "load" rather than fetch on its own.
  ImageProvider? preview(Media media, double physicalWidth);

  /// The full image, for the viewer.
  ImageProvider image(Media media);

  /// The file on disk.
  MediaFile open(Media media);

  /// Asks again for whatever [preview] needs, after it failed. Starts no
  /// download that the preview did not.
  void retryPreview(Media media);
}

/// Nothing to show: rows keep their placeholders.
class NoMediaSource implements MediaSource {
  const NoMediaSource();

  @override
  ImageProvider? preview(Media media, double physicalWidth) => null;

  @override
  ImageProvider image(Media media) =>
      throw UnsupportedError('no media source here');

  @override
  MediaFile open(Media media) => throw UnsupportedError('no media source here');

  @override
  void retryPreview(Media media) {}
}

class MediaSourceScope extends InheritedWidget {
  const MediaSourceScope({
    super.key,
    required this.source,
    required super.child,
  });

  final MediaSource source;

  /// Without a scope (a widget test, a lone page) rows keep their placeholders.
  static MediaSource of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MediaSourceScope>()?.source ??
      const NoMediaSource();

  /// Carries the scope [from] sees into [child], for routes on the root
  /// navigator that sit above the shell hosting it. See
  /// `AvatarImagesScope.carry`.
  static Widget carry(BuildContext from, {required Widget child}) =>
      MediaSourceScope(source: of(from), child: child);

  @override
  bool updateShouldNotify(MediaSourceScope old) => source != old.source;
}
