/// Writing files so a reader, a crash or a power cut never sees half of one.
library;

import 'dart:io';

var _writes = 0;

/// Writes [bytes] beside [file], flushed to disk, then renames it over
/// [file]: anyone reading it sees the old contents or the new, never part
/// of them. Creates [file]'s folder. The name written beside is unique to
/// this process and this call, so two writes of one file never share it.
Future<File> writeAtomically(File file, List<int> bytes) async {
  await file.parent.create(recursive: true);
  final part = File('${file.path}.$pid-${_writes++}.part');
  try {
    await part.writeAsBytes(bytes, flush: true);
    return await part.rename(file.path);
  } on Object {
    await part.delete().then((_) {}, onError: (_) {});
    rethrow;
  }
}
