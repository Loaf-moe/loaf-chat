/// The SDK's log, kept in a file for a user to send. An installed Windows
/// build has no console, and every failure on the notification path ends
/// in `Logs()` and nowhere else; a user who sees no toast had nothing to
/// show for it. Warnings and worse, one line each, two files at most.
library;

import 'dart:io';

import 'package:matrix/matrix.dart' show Level, LogEvent;
import 'package:path_provider/path_provider.dart';

class LogFile {
  LogFile(this.file, {this.cap = 1 << 20, this.least = Level.warning});

  static Future<LogFile> inSupportDirectory() async => LogFile(
    File(
      '${(await getApplicationSupportDirectory()).path}'
      '${Platform.pathSeparator}loaf.log',
    ),
  );

  final File file;

  /// Past this many bytes the file steps aside as `loaf.log.1`, replacing
  /// the one before, and a new one begins.
  final int cap;

  /// The least level written: the rest is the SDK talking to itself.
  final Level least;

  /// Writes queue behind one another, so two lines never interleave.
  Future<void> _writing = Future.value();

  void write(LogEvent event) {
    if (event.level.index > least.index) return;
    final line = StringBuffer()
      ..write(DateTime.now().toUtc().toIso8601String())
      ..write(' ')
      ..write(event.level.name)
      ..write(' ')
      ..write(event.title);
    if (event.exception case final e?) line.write(': $e');
    if (event.stackTrace case final s?) {
      line.write('\n${'$s'.split('\n').take(8).join('\n')}');
    }
    _writing = _writing.then((_) => _append('$line\n'));
  }

  /// Completes once every line handed over so far is on disk.
  Future<void> get flushed => _writing;

  Future<void> _append(String text) async {
    try {
      // A folder cleared by signing out is not brought back for a log.
      if (!await file.parent.exists()) return;
      if (await file.exists() && await file.length() > cap) {
        await file.rename('${file.path}.1');
      }
      await file.writeAsString(text, mode: FileMode.append, flush: true);
    } on FileSystemException {
      // A log that cannot be written is not worth a word to anyone.
    }
  }
}
