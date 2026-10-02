/// Opening, saving and sharing a message's file, each the platform's own way:
/// Quick Look on Apple, the default app through the portal on Linux (with a
/// viewer of our own for pictures), the save panel, and the share sheet.
///
/// Each waits for the whole file first. While it comes, [fetchingMedia] says
/// so, and the row shows how far it has got.
library;

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:loaf_media/loaf_media.dart';
import 'package:share_plus/share_plus.dart';

import '../mock/fixtures.dart';
import '../model/media_source.dart';
import '../widgets/toast.dart';
import 'image_viewer.dart';

/// The media whose files are being fetched to open, save or share, by
/// [Media.ref]. A row listens, and shows progress while its own is here.
class FetchingMedia extends ChangeNotifier {
  final _counts = <Object, int>{};

  bool contains(Media media) => _counts.containsKey(media.ref);

  void _add(Media media) {
    _counts.update(media.ref, (n) => n + 1, ifAbsent: () => 1);
    notifyListeners();
  }

  void _remove(Media media) {
    final n = _counts[media.ref];
    if (n == null) return;
    if (n > 1) {
      _counts[media.ref] = n - 1;
    } else {
      _counts.remove(media.ref);
    }
    notifyListeners();
  }
}

final fetchingMedia = FetchingMedia();

/// Somewhere to toast from that outlives the row: a download can take long
/// enough for the row to scroll away.
BuildContext _toastContext(BuildContext context) =>
    Navigator.maybeOf(context, rootNavigator: true)?.context ?? context;

/// Waits for [media]'s whole file, keeping it through eviction meanwhile,
/// and hands its path to [use].
Future<T> _withFile<T>(
  MediaSource source,
  Media media,
  Future<T> Function(String path) use,
) async {
  final file = source.open(media)..hold();
  fetchingMedia._add(media);
  try {
    final String path;
    try {
      path = await file.path;
    } finally {
      // Whatever happens next, the download is over: no more progress.
      fetchingMedia._remove(media);
    }
    return await use(path);
  } finally {
    file.release();
  }
}

/// The app each file extension opens in on a Mac, as it last said. The menu
/// naming it cannot wait for the answer, since a channel that never answered
/// would keep it from opening; so the name is asked for when a file comes on
/// screen, and the menu uses what has come back.
final _defaultApps = <String, String>{};
final _asking = <String>{};

String? _extensionOf(Media media) {
  final dot = media.name.lastIndexOf('.');
  if (dot <= 0 || dot == media.name.length - 1) return null;
  return media.name.substring(dot + 1).toLowerCase();
}

/// macOS: asks which app opens files like [media], for [defaultAppFor].
/// Once at a time per extension; elsewhere, nothing.
void lookUpDefaultApp(Media media) {
  if (defaultTargetPlatform != TargetPlatform.macOS) return;
  final extension = _extensionOf(media);
  if (extension == null || !_asking.add(extension)) return;
  unawaited(_askDefaultApp(extension));
}

Future<void> _askDefaultApp(String extension) async {
  try {
    final app = await LoafMedia.defaultAppName(extension);
    if (app == null) {
      _defaultApps.remove(extension);
    } else {
      _defaultApps[extension] = app;
    }
  } on Exception catch (e) {
    debugPrint('[loaf media] default app for .$extension: $e');
  } finally {
    _asking.remove(extension);
  }
}

/// The app [lookUpDefaultApp] found for files like [media], if any yet.
String? defaultAppFor(Media media) {
  final extension = _extensionOf(media);
  return extension == null ? null : _defaultApps[extension];
}

/// Shows [media] in the platform's own viewer: Quick Look on iOS and macOS;
/// on Linux, pictures in [ImageViewer] and anything else in its default app.
Future<void> openMedia(BuildContext context, Media media) async {
  final source = MediaSourceScope.of(context);
  final navigator = Navigator.of(context, rootNavigator: true);
  final toast = _toastContext(context);
  try {
    await _withFile(source, media, (path) async {
      switch (defaultTargetPlatform) {
        case TargetPlatform.iOS || TargetPlatform.macOS:
          await LoafMedia.quickLook(path);
        case TargetPlatform.linux when media.kind == MediaKind.image:
          // The root navigator sits above the scope, so the viewer carries
          // it, as `MediaSourceScope.carry` does. The source was read before
          // the wait: the row may have scrolled away since.
          unawaited(
            navigator.push(
              MaterialPageRoute<void>(
                builder: (_) => MediaSourceScope(
                  source: source,
                  child: ImageViewer(
                    provider: source.image(media),
                    media: media,
                  ),
                ),
              ),
            ),
          );
        case TargetPlatform.linux:
          await LoafMedia.openWithPortal(path);
        case final platform:
          throw UnsupportedError('no viewer on $platform');
      }
    });
  } catch (e) {
    debugPrint('[loaf media] open ${media.name}: $e');
    if (toast.mounted) showToast(toast, "couldn't open ${media.name}");
  }
}

/// macOS: opens [media] in the app Finder would open it with.
Future<void> openMediaWithDefaultApp(BuildContext context, Media media) async {
  final source = MediaSourceScope.of(context);
  final toast = _toastContext(context);
  try {
    await _withFile(source, media, LoafMedia.openWithDefaultApp);
  } catch (e) {
    debugPrint('[loaf media] open ${media.name} with its app: $e');
    if (toast.mounted) showToast(toast, "couldn't open ${media.name}");
  }
}

/// Asks where to save [media], then copies it there. Nothing is fetched
/// until a place is picked.
Future<void> saveMediaAs(BuildContext context, Media media) async {
  final source = MediaSourceScope.of(context);
  final toast = _toastContext(context);
  try {
    final location = await getSaveLocation(suggestedName: media.name);
    if (location == null) return;
    await _withFile(source, media, (path) => File(path).copy(location.path));
    if (toast.mounted) showToast(toast, 'saved');
  } catch (e) {
    debugPrint('[loaf media] save ${media.name}: $e');
    if (toast.mounted) showToast(toast, "couldn't save ${media.name}");
  }
}

/// The system share sheet with [media]'s file. [origin] is where it points
/// from on an iPad.
Future<void> shareMedia(
  BuildContext context,
  Media media, {
  Rect? origin,
}) async {
  final source = MediaSourceScope.of(context);
  final toast = _toastContext(context);
  try {
    await _withFile(
      source,
      media,
      (path) => SharePlus.instance.share(
        ShareParams(
          files: [XFile(path, name: media.name, mimeType: media.mimeType)],
          sharePositionOrigin: origin,
        ),
      ),
    );
  } catch (e) {
    debugPrint('[loaf media] share ${media.name}: $e');
    if (toast.mounted) showToast(toast, "couldn't share ${media.name}");
  }
}
