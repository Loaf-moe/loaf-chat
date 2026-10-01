import 'package:flutter/foundation.dart';

/// A file on disk that may still be arriving. Players read [partialPath]
/// up to [received]; the bytes there never change once written.
abstract interface class GrowingFile implements Listenable {
  /// Stable for the same remote file, and safe in a URI path segment.
  String get id;
  String get partialPath;
  int get received;

  /// Known once the server says, or from the sender's `info.size`.
  int? get total;
  bool get complete;
  Object? get error;
}
