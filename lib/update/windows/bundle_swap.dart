/// Replaces the Windows install with a newer build, file by file, while the
/// old one is still running. Windows will not let a running program's files
/// be overwritten or deleted, but it will let them be renamed: each old file
/// steps aside as `<name>.old`, the new one takes its name, and the next
/// launch deletes what was set aside.
///
/// A journal written before every rename makes the swap all or nothing. A
/// failure plays it backwards at once; a crash or power cut leaves it for
/// the next launch's [BundleSwap.cleanUp] to play backwards instead.
library;

import 'dart:async';

import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:path/path.dart' as p;

import '../../util/retry.dart';

class BundleSwap {
  BundleSwap(
    String install, {
    this.fs = const LocalFileSystem(),
    this.attempts = 20,
    this.attemptDelay = const Duration(milliseconds: 100),
  }) : install = fs.directory(install);

  final FileSystem fs;

  /// The folder Setup installed into, holding the running build.
  final Directory install;

  /// How many times a rename is tried, [attemptDelay] apart, before the
  /// swap gives up: a file someone else holds (Defender scanning a new DLL,
  /// say) is usually let go within a second or two.
  final int attempts;
  final Duration attemptDelay;

  /// Swapped last so the Start-menu shortcut is broken for the shortest
  /// time.
  static const executable = BuildFile('loaf-chat.exe');

  /// The updater's own folder inside the install: the download, the staged
  /// build, the journal. Never swapped.
  static const workName = 'update';

  Directory get work => install.childDirectory(workName);
  File get _journal => work.childFile('journal');

  /// Puts [staged], an unpacked build, in place of the running one. Throws,
  /// with the old build put back, if any of it could not be done.
  Future<void> apply(Directory staged) async {
    final incoming = _files(staged);
    if (!incoming.contains(executable)) {
      throw StateError('the new build has no ${executable.posix}');
    }
    final outgoing = _files(install).where((f) => f.swappable);

    work.createSync(recursive: true);
    _journal.writeAsStringSync('');
    try {
      for (final file in _executableLast(outgoing)) {
        final at = file.under(install);
        _record(SetAside(file));
        await _rename(at, '$at${BuildFile.aside}');
      }
      for (final file in _executableLast(incoming)) {
        final to = fs.file(file.under(install));
        _record(PutInPlace(file));
        to.parent.createSync(recursive: true);
        await _rename(file.under(staged), to.path);
      }
    } catch (_) {
      _rollBack();
      rethrow;
    }
    // The swap is whole: without a journal there is nothing to undo.
    _journal.deleteSync();
  }

  /// At launch: finishes undoing a swap a crash cut short, then deletes the
  /// set-aside files of the last one and the updater's leftovers. True when
  /// a swap was undone. Anything still held is left for the next launch.
  Future<bool> cleanUp() async {
    final interrupted = _journal.existsSync();
    if (interrupted) _rollBack();
    for (final file in _files(install)) {
      if (file.isSetAside) _tryDelete(fs.file(file.under(install)));
    }
    if (work.existsSync()) {
      try {
        work.deleteSync(recursive: true);
      } on FileSystemException {
        // Held; next time.
      }
    }
    return interrupted;
  }

  /// Plays the journal backwards: every new file out, every old file back
  /// under its own name. A line written for a rename that never happened
  /// finds nothing to undo.
  void _rollBack() {
    final entries = _journal.readAsLinesSync().map(JournalEntry.parse);
    for (final entry in entries.toList().reversed) {
      switch (entry) {
        case PutInPlace(:final file):
          _tryDelete(fs.file(file.under(install)));
        case SetAside(:final file):
          final at = fs.file(file.under(install));
          final aside = fs.file('${at.path}${BuildFile.aside}');
          if (aside.existsSync()) {
            if (at.existsSync()) at.deleteSync();
            aside.renameSync(at.path);
          }
        case null: // torn by the crash
      }
    }
    _journal.deleteSync();
  }

  /// Written and flushed before the rename it names, so the journal never
  /// misses a rename that happened. Closed again straight after: Windows
  /// will not delete a file anyone holds open, and a swap that stalls must
  /// still leave a journal [cleanUp] can play back and delete.
  void _record(JournalEntry entry) => _journal.writeAsStringSync(
    '${entry.line}\n',
    mode: FileMode.append,
    flush: true,
  );

  /// Through [fs], where a test holds a file.
  Future<void> _rename(String from, String to) =>
      retry<File, FileSystemException>(
        () => fs.file(from).rename(to),
        attempts: attempts,
        delay: attemptDelay,
      );

  /// Every file under [dir], sorted.
  static List<BuildFile> _files(Directory dir) => [
    for (final entity in dir.listSync(recursive: true, followLinks: false))
      if (entity is File) BuildFile.of(entity, dir),
  ]..sort((a, b) => a.posix.compareTo(b.posix));

  static List<BuildFile> _executableLast(Iterable<BuildFile> files) => [
    ...files.where((f) => f != executable),
    if (files.contains(executable)) executable,
  ];

  static void _tryDelete(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // Still held by the build that just quit; next launch.
    }
  }
}

/// A file's place inside a build, written the same on every platform:
/// relative, with `/` between folders. The journal holds these.
extension type const BuildFile(String posix) {
  BuildFile.of(File file, Directory root)
    : this(
        p.posix.joinAll(
          file.fileSystem.path.split(
            file.fileSystem.path.relative(file.path, from: root.path),
          ),
        ),
      );

  /// Added to a file's name when the swap sets it aside.
  static const aside = '.old';

  /// Setup's uninstaller and its log belong to Setup, not to any build.
  static const _setupFiles = {'unins000.exe', 'unins000.dat'};

  /// What the last swap set aside, for the next launch to delete.
  bool get isSetAside => posix.toLowerCase().endsWith(aside);

  /// Part of the running build: not Setup's, not the updater's own folder,
  /// not set aside by the last swap.
  bool get swappable {
    final top = p.posix.split(posix).first.toLowerCase();
    return top != BundleSwap.workName &&
        !_setupFiles.contains(top) &&
        !isSetAside;
  }

  /// Its path in [root]'s copy of the build.
  String under(Directory root) =>
      root.fileSystem.path.joinAll([root.path, ...p.posix.split(posix)]);
}

/// One line of the journal: a rename about to happen.
sealed class JournalEntry {
  const JournalEntry(this.file);

  final BuildFile file;

  String get line;

  /// Null for a line a crash tore. Windows allows no tab in a file name, so
  /// the first one always ends the kind.
  static JournalEntry? parse(String line) => switch (line.split('\t')) {
    ['old', final path] when path.isNotEmpty => SetAside(BuildFile(path)),
    ['new', final path] when path.isNotEmpty => PutInPlace(BuildFile(path)),
    _ => null,
  };
}

/// The running build's [file] steps aside as `<file>.old`.
final class SetAside extends JournalEntry {
  const SetAside(super.file);

  @override
  String get line => 'old\t${file.posix}';
}

/// The new build's [file] takes its place in the install.
final class PutInPlace extends JournalEntry {
  const PutInPlace(super.file);

  @override
  String get line => 'new\t${file.posix}';
}
