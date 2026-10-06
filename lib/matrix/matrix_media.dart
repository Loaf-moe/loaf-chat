/// Matrix file messages as [ui.Media], and the [ui.MediaSource] that turns
/// them into pictures and files on disk. All of it reads the event's content
/// loosely: a sender may leave out any part of `info`, and a bad block must
/// show as a card or a failed load, never throw while the timeline is drawn.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:loaf_media/loaf_media.dart' show LoafVideo;
import 'package:matrix/matrix.dart';

import '../ui/model/media_source.dart' as ui;
import '../ui/model/models.dart' as ui;
import 'matrix_avatar_images.dart';
import 'media_images.dart';
import 'media_store.dart';

export 'matrix_avatar_images.dart'
    show avatarBuckets, bucketFor, timelineBuckets;

/// What a [ui.Media] from [mediaOf] carries. A copy of the content, so the
/// event itself can go away.
class _Ref {
  _Ref(this.eventId, this.txid, this.content, {this.external = false});

  final String eventId;

  /// The SDK's transaction id, while the file is still going up.
  final String? txid;
  final Map<String, Object?> content;

  /// Whether a link to another site may be fetched for this file. Never in
  /// an encrypted room, and never when the setting is off: see [mediaOf].
  final bool external;

  Map<String, Object?> get info =>
      content.tryGetMap<String, Object?>('info') ?? const {};

  Map<String, Object?>? get file => content.tryGetMap<String, Object?>('file');

  Map<String, Object?>? get thumbnailFile =>
      info.tryGetMap<String, Object?>('thumbnail_file');

  String get name => _nameOf(content);

  bool get encrypted => content['file'] is Map;

  /// Uploading: the SDK holds its bytes, and the server has none yet.
  bool get sending => txid != null && !encrypted && content['url'] is! String;

  /// Where the bytes are: the mxc, plain or encrypted.
  Object? get _mxc => content['url'] ?? file?['url'];

  // The timeline maps every event afresh on each change. Equal refs let the
  // UI recognise the same file across those rebuilds.
  @override
  bool operator ==(Object other) =>
      other is _Ref &&
      other.eventId == eventId &&
      other.txid == txid &&
      other.external == external &&
      other._mxc == _mxc;

  @override
  int get hashCode => Object.hash(eventId, txid, external, _mxc);
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
///
/// A file a bridge links to on another site (an `https` URL where an mxc
/// should be) is fetched only when [external] allows it, and never in an
/// encrypted room: there a plain link is not what the sender's client wrote,
/// and fetching it would tell that site who reads the room.
ui.Media? mediaOf(Event event, {bool external = true}) {
  try {
    final kind = _kindOf(event.messageType);
    if (kind == null) return null;
    final content = _copy(event.content)! as Map<String, Object?>;
    final ref = _Ref(
      event.eventId,
      event.transactionId,
      content,
      external: external && !event.room.encrypted,
    );
    final info = ref.info;
    final w = _int(info['w']), h = _int(info['h']);
    final ms = _int(info['duration']);
    final size = _int(info['size']);
    final mime = info.tryGet<String>('mimetype', TryGet.silent);
    final mimeType = mime == null || mime.isEmpty ? null : mime.toLowerCase();
    final plan = _planOf(ref, kind, size, mimeType);
    return ui.Media(
      kind: kind,
      name: ref.name,
      size: size,
      mimeType: mimeType,
      dimensions: w != null && h != null && w > 0 && h > 0
          ? Size(w.toDouble(), h.toDouble())
          : null,
      duration: ms == null ? null : Duration(milliseconds: ms),
      hasPreview: plan != _Preview.none,
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

/// The file itself. A `file` map missing its key or iv gets empty ones,
/// which the store refuses: the download fails, the timeline doesn't.
MediaSpec? _fullSpec(_Ref ref) => _spec(
  ref.file,
  ref.content['url'],
  ref.name,
  _int(ref.info['size']),
  external: ref.external,
);

MediaSpec? _thumbnailSpec(_Ref ref) => _spec(
  ref.thumbnailFile,
  ref.info['thumbnail_url'],
  '${ref.name}.thumbnail',
  _int(ref.info.tryGetMap<String, Object?>('thumbnail_info')?['size']),
  external: ref.external,
);

MediaSpec? _spec(
  Map<String, Object?>? file,
  Object? plainUrl,
  String name,
  int? size, {
  required bool external,
}) {
  final url = file != null ? file['url'] : plainUrl;
  final mxc = url is String ? Uri.tryParse(url) : null;
  if (mxc == null) return null;
  // Another site's file, only over https, only plain (an encrypted file
  // map points at the homeserver's own media), and only when allowed.
  final elsewhere =
      external && file == null && mxc.isScheme('https') && mxc.host.isNotEmpty;
  if (!mxc.isScheme('mxc') && !elsewhere) return null;
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

/// What a row's preview is made of. Decided once, so that a row only offers
/// a preview that [MatrixMediaSource.preview] can really draw.
enum _Preview {
  none,

  /// The SDK's own copy of a file still going up.
  sending,

  /// A GIF within the cap, whole, so that it animates in the row.
  gif,

  /// The sender's thumbnail, through the store.
  thumbnail,

  /// The server's thumbnail of a plain image.
  server,

  /// A small encrypted image, itself.
  file,
}

_Preview _planOf(_Ref ref, ui.MediaKind kind, int? size, String? mime) {
  final image = kind == ui.MediaKind.image;
  final thumbnail = _thumbnailSpec(ref) != null;
  if (ref.sending) {
    return image || thumbnail ? _Preview.sending : _Preview.none;
  }
  final full = _fullSpec(ref);
  if (image &&
      full != null &&
      mime == 'image/gif' &&
      size != null &&
      size <= ui.inlinePreviewCap) {
    return _Preview.gif;
  }
  if (thumbnail) return _Preview.thumbnail;
  if (!image || full == null) return _Preview.none;
  // The server can only thumbnail what it holds; a link to another site
  // is drawn from the file itself, like a small encrypted image.
  if (!ref.encrypted && full.mxc.isScheme('mxc')) return _Preview.server;
  return size != null && size <= ui.inlinePreviewCap
      ? _Preview.file
      : _Preview.none;
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
  MatrixMediaSource(this.client, this.store) : _closed = false;

  /// What [MatrixRooms.media] gives after it is disposed: no store, no
  /// previews, and every file already failed, so a late rebuild after
  /// sign-out opens nothing.
  MatrixMediaSource.closed(this.client) : store = null, _closed = true;

  final bool _closed;

  final Client client;
  final MediaStore? store;

  /// Signing out. The rows go with the account, but a video floating in
  /// picture in picture would play on, and a player waiting on bytes that
  /// will never come would wait for ever: every player is stopped, and
  /// every stream ended, failing its readers.
  void dispose() {
    final store = this.store;
    if (store == null) return;
    store.dispose();
    LoafVideo.endAll();
  }

  ui.MediaFile _open(MediaSpec? spec, String missing) {
    final store = this.store;
    if (store == null) {
      return _FailedFile(
        StateError(_closed ? 'signed out' : 'no media folder'),
      );
    }
    if (spec == null) return _FailedFile(StateError(missing));
    return store.open(spec);
  }

  // ── ui.MediaSource ─────────────────────────────────────────────────────

  @override
  ImageProvider? preview(ui.Media media, double physicalWidth) {
    final ref = media.ref;
    if (ref is! _Ref || _closed) return null;
    final txid = ref.txid;
    switch (_planOf(ref, media.kind, media.size, media.mimeType)) {
      case _Preview.none:
        return null;
      case _Preview.sending:
        if (txid == null) return null;
        return FileStoreImage(
          client,
          Uri(scheme: 'cache', host: 'thumbnail', path: txid),
          fallback: media.kind == ui.MediaKind.image
              ? Uri(scheme: 'cache', host: 'file', path: txid)
              : null,
        );
      case _Preview.gif || _Preview.file:
        return StoredFileImage(_open(_fullSpec(ref), ''), physicalWidth);
      case _Preview.thumbnail:
        return StoredFileImage(_open(_thumbnailSpec(ref), ''), physicalWidth);
      case _Preview.server:
        final mxc = _fullSpec(ref)?.mxc;
        if (mxc == null) return null;
        return MxcThumbnail(
          client,
          mxc,
          bucketFor(physicalWidth, buckets: timelineBuckets),
        );
    }
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
    final spec = switch (_planOf(ref, media.kind, media.size, media.mimeType)) {
      _Preview.gif || _Preview.file => _fullSpec(ref),
      _Preview.thumbnail => _thumbnailSpec(ref),
      _ => null,
    };
    if (spec != null) store.open(spec).retry();
  }
}
