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
import 'dart:io';

typedef FileRename = Future<void> Function(String from, String to);

class BundleSwap {
  BundleSwap(
    this.install, {
    FileRename? rename,
    this.retryFor = const Duration(seconds: 2),
    this.retryEvery = const Duration(milliseconds: 100),
  }) : _rename = rename ?? _renameFile;

  /// The folder Setup installed into, holding the running build.
  final Directory install;

  /// How long a file someone else holds (Defender scanning a new DLL, say)
  /// is waited for before the swap gives up.
  final Duration retryFor;
  final Duration retryEvery;
  final FileRename _rename;

  /// What every build has, and what goes in last and comes out last, so the
  /// shortcut points at nothing for as short a time as possible.
  static const executable = 'loaf-chat.exe';

  /// The updater's own folder inside the install: the download, the staged
  /// build, the journal. Never swapped.
  static const workName = 'update';

  /// Setup's uninstaller and its log belong to Setup, not to any build.
  static const _setupFiles = {'unins000.exe', 'unins000.dat'};

  static const _old = '.old';

  Directory get work => Directory(_join(install.path, workName));
  File get _journal => File(_join(work.path, 'journal'));

  /// Puts [staged], an unpacked build, in place of the running one. Throws,
  /// with the old build put back, if any of it could not be done.
  Future<void> apply(Directory staged) async {
    final incoming = _files(staged);
    if (!incoming.contains(executable)) {
      throw StateError('the new build has no $executable');
    }
    final outgoing = _files(install).where(_swappable).toList();

    work.createSync(recursive: true);
    final journal = _journal.openSync(mode: FileMode.writeOnly);
    try {
      for (final rel in _executableLast(outgoing)) {
        _record(journal, 'old', rel);
        await _retrying(_at(install, rel), '${_at(install, rel)}$_old');
      }
      for (final rel in _executableLast(incoming)) {
        _record(journal, 'new', rel);
        final to = _at(install, rel);
        File(to).parent.createSync(recursive: true);
        await _retrying(_at(staged, rel), to);
      }
    } catch (_) {
      journal.closeSync();
      _rollBack();
      rethrow;
    }
    journal.closeSync();
    // The swap is whole: without a journal there is nothing to undo.
    _journal.deleteSync();
  }

  /// At launch: finishes undoing a swap a crash cut short, then deletes the
  /// set-aside files of the last one and the updater's leftovers. True when
  /// a swap was undone. Anything still held is left for the next launch.
  Future<bool> cleanUp() async {
    final interrupted = _journal.existsSync();
    if (interrupted) _rollBack();
    for (final rel in _files(install)) {
      if (rel.endsWith(_old)) _tryDelete(File(_at(install, rel)));
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
    final lines = _journal.readAsLinesSync().reversed;
    for (final line in lines) {
      final tab = line.indexOf('\t');
      if (tab < 0) continue; // torn by the crash
      final rel = line.substring(tab + 1);
      final at = _at(install, rel);
      switch (line.substring(0, tab)) {
        case 'new':
          _tryDelete(File(at));
        case 'old':
          final aside = File('$at$_old');
          if (aside.existsSync()) {
            if (File(at).existsSync()) File(at).deleteSync();
            aside.renameSync(at);
          }
      }
    }
    _journal.deleteSync();
  }

  Future<void> _retrying(String from, String to) async {
    final until = DateTime.now().add(retryFor);
    while (true) {
      try {
        return await _rename(from, to);
      } on FileSystemException {
        if (!DateTime.now().isBefore(until)) rethrow;
        await Future<void>.delayed(retryEvery);
      }
    }
  }

  /// Written and flushed before the rename it names, so the journal never
  /// misses a rename that happened.
  static void _record(RandomAccessFile journal, String kind, String rel) {
    journal.writeStringSync('$kind\t$rel\n');
    journal.flushSync();
  }

  bool _swappable(String rel) {
    final top = rel.split('/').first.toLowerCase();
    return top != workName &&
        !_setupFiles.contains(top) &&
        !rel.toLowerCase().endsWith(_old);
  }

  static List<String> _executableLast(Iterable<String> rels) => [
    ...rels.where((r) => r != executable),
    if (rels.contains(executable)) executable,
  ];

  /// Every file under [dir], relative, with `/` between folders.
  static List<String> _files(Directory dir) {
    final sep = Platform.pathSeparator;
    return [
      for (final entity in dir.listSync(recursive: true, followLinks: false))
        if (entity is File)
          entity.path.substring(dir.path.length + 1).replaceAll(sep, '/'),
    ]..sort();
  }

  static String _at(Directory dir, String rel) =>
      _join(dir.path, rel.replaceAll('/', Platform.pathSeparator));

  static String _join(String a, String b) => '$a${Platform.pathSeparator}$b';

  static void _tryDelete(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // Still held by the build that just quit; next launch.
    }
  }
}

Future<void> _renameFile(String from, String to) => File(from).rename(to);
