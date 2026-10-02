/// The mock backend's [MediaSource]: bundled samples, and whatever the
/// composer "sent" this session, copied out to a folder so the rest of the
/// app can treat them as files on disk.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../model/media_source.dart';
import '../model/models.dart';

class MockMediaSource implements MediaSource {
  MockMediaSource(this.root);

  /// Where opened files are written. The caller owns and deletes it.
  final Directory root;

  final _open = <Object, _MockFile>{};

  // Bundled samples and memory images never fail to load.
  @override
  void retryPreview(Media media) {}

  @override
  ImageProvider? preview(Media media, double physicalWidth) {
    final image = this.image(media);
    return ResizeImage.resizeIfNeeded(physicalWidth.round(), null, image);
  }

  @override
  ImageProvider image(Media media) => switch (media.ref) {
    final Uint8List bytes => MemoryImage(bytes),
    final String asset => AssetImage(asset),
    _ => throw ArgumentError('not a mock media ref: ${media.ref}'),
  };

  @override
  MediaFile open(Media media) => _open.putIfAbsent(media.ref, () {
    final ref = media.ref;
    // An outgoing file has no asset name; its own is the only one it has.
    final name = ref is String ? ref.split('/').last : media.name;
    return _MockFile(name, '${root.path}/$name').._fill(switch (ref) {
      final Uint8List bytes => Future.value(bytes),
      final String asset =>
        rootBundle
            .load(asset)
            .then(
              (data) => data.buffer.asUint8List(
                data.offsetInBytes,
                data.lengthInBytes,
              ),
            ),
      _ => throw ArgumentError('not a mock media ref: $ref'),
    });
  });
}

class _MockFile extends ChangeNotifier implements MediaFile {
  _MockFile(this.id, this._path);

  @override
  final String id;
  final String _path;
  final _done = Completer<String>();
  var _received = 0;
  int? _total;
  Object? _error;

  Future<void> _fill(Future<Uint8List> bytes) async {
    try {
      final data = await bytes;
      await File(_path).writeAsBytes(data);
      _total = data.length;
      _received = data.length;
      _done.complete(_path);
    } catch (e) {
      _error = e;
      _done.completeError(e);
      // Nobody may be awaiting it; the error is also on [error].
      _done.future.ignore();
    }
    notifyListeners();
  }

  @override
  String get partialPath => _path;
  @override
  int get received => _received;
  @override
  int? get total => _total;
  @override
  bool get complete => _total != null && _received == _total;
  @override
  Object? get error => _error;
  @override
  Future<String> get path => _done.future;

  // Nothing here is ever evicted or fails, so there is nothing to do.
  @override
  void retry() {}
  @override
  void hold() {}
  @override
  void release() {}
}
