/// Matrix file messages as [ui.Media], and the [ui.MediaSource] that turns
/// them into pictures and files on disk. All of it reads the event's content
/// loosely: a sender may leave out any part of `info`, and a bad block must
/// show as a card or a failed load, never throw while the timeline is drawn.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:matrix/matrix.dart';

import '../ui/model/media_source.dart' as ui;
import '../ui/model/models.dart' as ui;
import 'matrix_avatar_images.dart';
import 'media_images.dart';
import 'media_store.dart';

export 'matrix_avatar_images.dart'
    show avatarBuckets, bucketFor, timelineBuckets;

/// Past this, an encrypted image with no thumbnail is not fetched for a
/// preview: the whole thing would be downloaded to draw a small row.
const _smallImage = 2 * 1000 * 1000;

/// What a [ui.Media] from [mediaOf] carries. A copy of the content, so the
/// event itself can go away.
class _Ref {
  _Ref(this.eventId, this.txid, this.content);

  final String eventId;

  /// The SDK's transaction id, while the file is still going up.
  final String? txid;
  final Map<String, Object?> content;

  Map<String, Object?> get info =>
      content.tryGetMap<String, Object?>('info') ?? const {};

  Map<String, Object?>? get file => content.tryGetMap<String, Object?>('file');

  Map<String, Object?>? get thumbnailFile =>
      info.tryGetMap<String, Object?>('thumbnail_file');

  String get name => _nameOf(content);

  bool get encrypted => content['file'] is Map;

  /// Uploading: the SDK holds its bytes, and the server has none yet.
  bool get sending => txid != null && !encrypted && content['url'] is! String;
}

Object? _copy(Object? value) => switch (value) {
  final Map<dynamic, dynamic> m => {
    for (final e in m.entries) e.key.toString(): _copy(e.value),
  },
  final List<dynamic> l => [for (final e in l) _copy(e)],
  _ => value,
};

int? _int(Object? value) =>
    value is num && value.isFinite ? value.toInt() : null;

String _nameOf(Map<String, Object?> content) {
  for (final key in const ['filename', 'body']) {
    final value = content.tryGet<String>(key, TryGet.silent);
    if (value != null && value.isNotEmpty) return value;
  }
  return 'file';
}

/// [content]'s words, when it has some beyond the file's name: a `filename`
/// that differs from `body` makes `body` a caption.
String? captionOf(Map<String, Object?> content) {
  final filename = content.tryGet<String>('filename', TryGet.silent);
  final body = content.tryGet<String>('body', TryGet.silent);
  if (filename == null || body == null || body.isEmpty || body == filename) {
    return null;
  }
  return body;
}

ui.MediaKind? _kindOf(String type) => switch (type) {
  MessageTypes.Image || MessageTypes.Sticker => ui.MediaKind.image,
  MessageTypes.Video => ui.MediaKind.video,
  MessageTypes.Audio => ui.MediaKind.audio,
  MessageTypes.File => ui.MediaKind.file,
  _ => null,
};

/// [event] as media, or null for anything that is not a file message.
/// Never throws: a missing info block gives a file with what is known.
ui.Media? mediaOf(Event event) {
  try {
    final kind = _kindOf(event.messageType);
    if (kind == null) return null;
    final content = _copy(event.content)! as Map<String, Object?>;
    final ref = _Ref(event.eventId, event.transactionId, content);
    final info = ref.info;
    final w = _int(info['w']), h = _int(info['h']);
    final ms = _int(info['duration']);
    final size = _int(info['size']);
    final mime = info.tryGet<String>('mimetype', TryGet.silent);
    return ui.Media(
      kind: kind,
      name: ref.name,
      size: size,
      mimeType: mime == null || mime.isEmpty ? null : mime.toLowerCase(),
      dimensions: w != null && h != null && w > 0 && h > 0
          ? Size(w.toDouble(), h.toDouble())
          : null,
      duration: ms == null ? null : Duration(milliseconds: ms),
      hasPreview:
          event.hasThumbnail ||
          (kind == ui.MediaKind.image &&
              (!ref.encrypted || (size != null && size <= _smallImage))),
      ref: ref,
    );
  } on Object catch (e) {
    Logs().v('[loaf] media event ${event.eventId} unreadable: $e');
    // Still a card, so the message is not lost.
    return ui.Media(
      kind: ui.MediaKind.file,
      name: 'file',
      ref: _Ref(event.eventId, null, const {}),
    );
  }
}

/// A file that has already failed, for a ref with nowhere to fetch from.
/// [retry] changes nothing: the ref is what is broken.
class _FailedFile extends ChangeNotifier implements ui.MediaFile {
  _FailedFile(this.error);

  @override
  final Object error;

  @override
  String get id => 'failed';
  @override
  String get partialPath => '';
  @override
  int get received => 0;
  @override
  int? get total => null;
  @override
  bool get complete => false;
  @override
  Future<String> get path => Future.error(error);

  @override
  void retry() {}
  @override
  void hold() {}
  @override
  void release() {}
}

class MatrixMediaSource implements ui.MediaSource {
  /// A null [store] is a client with nowhere to keep files: every file it
  /// is asked for has already failed.
  MatrixMediaSource(this.client, this.store);

  final Client client;
  final MediaStore? store;

  void dispose() => store?.dispose();

  // ── What a ref names ───────────────────────────────────────────────────

  /// The file itself. A `file` map missing its key or iv gets empty ones,
  /// which the store refuses: the download fails, the timeline doesn't.
  MediaSpec? _fullSpec(_Ref ref) =>
      _spec(ref.file, ref.content['url'], ref.name, _int(ref.info['size']));

  MediaSpec? _thumbnailSpec(_Ref ref) => _spec(
    ref.thumbnailFile,
    ref.info['thumbnail_url'],
    '${ref.name}.thumbnail',
    _int(ref.info.tryGetMap<String, Object?>('thumbnail_info')?['size']),
  );

  MediaSpec? _spec(
    Map<String, Object?>? file,
    Object? plainUrl,
    String name,
    int? size,
  ) {
    final url = file != null ? file['url'] : plainUrl;
    final mxc = url is String ? Uri.tryParse(url) : null;
    if (mxc == null || !mxc.isScheme('mxc')) return null;
    return MediaSpec(
      mxc: mxc,
      name: name,
      size: size,
      key: file == null
          ? null
          : file.tryGetMap<String, Object?>('key')?.tryGet<String>('k') ?? '',
      iv: file == null ? null : file.tryGet<String>('iv') ?? '',
    );
  }

  ui.MediaFile _open(MediaSpec? spec, String missing) {
    final store = this.store;
    if (store == null) return _FailedFile(StateError('no media folder'));
    if (spec == null) return _FailedFile(StateError(missing));
    return store.open(spec);
  }

  // ── ui.MediaSource ─────────────────────────────────────────────────────

  @override
  ImageProvider? preview(ui.Media media, double physicalWidth) {
    final ref = media.ref;
    if (ref is! _Ref) return null;
    final txid = ref.txid;
    if (ref.sending && txid != null) {
      return FileStoreImage(
        client,
        Uri(scheme: 'cache', host: 'thumbnail', path: txid),
        fallback: media.kind == ui.MediaKind.image
            ? Uri(scheme: 'cache', host: 'file', path: txid)
            : null,
      );
    }
    final thumbnail = _thumbnailSpec(ref);
    if (thumbnail != null) {
      return StoredFileImage(_open(thumbnail, ''), physicalWidth);
    }
    if (media.kind != ui.MediaKind.image) return null;
    final full = _fullSpec(ref);
    if (full == null) return null;
    if (!ref.encrypted) {
      return MxcThumbnail(
        client,
        full.mxc,
        bucketFor(physicalWidth, buckets: timelineBuckets),
      );
    }
    final size = media.size;
    if (size != null && size <= _smallImage) {
      return StoredFileImage(_open(full, ''), physicalWidth);
    }
    return null;
  }

  @override
  ImageProvider image(ui.Media media) {
    final ref = media.ref;
    final file = ref is _Ref
        ? _open(_fullSpec(ref), 'no file in this message')
        : _FailedFile(StateError('not a matrix media ref'));
    return StoredFileImage(file, null);
  }

  @override
  ui.MediaFile open(ui.Media media) {
    final ref = media.ref;
    if (ref is! _Ref) return _FailedFile(StateError('not a matrix media ref'));
    return _open(_fullSpec(ref), 'no file in this message');
  }

  @override
  void retryPreview(ui.Media media) {
    final ref = media.ref;
    final store = this.store;
    if (ref is! _Ref || store == null) return;
    // Only the file the preview itself reads: a plain image's preview is a
    // server thumbnail with nothing on disk, and opening the full file here
    // would download it.
    final size = media.size;
    final spec =
        _thumbnailSpec(ref) ??
        (media.kind == ui.MediaKind.image &&
                ref.encrypted &&
                size != null &&
                size <= _smallImage
            ? _fullSpec(ref)
            : null);
    if (spec != null) store.open(spec).retry();
  }
}
