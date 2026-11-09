import 'dart:async';
import 'dart:io' as io;

import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/update/windows/bundle_swap.dart';
import 'package:path/path.dart' as p;

const _disk = LocalFileSystem();

/// The disk, except that every rename asks [before] first: a throw is a
/// file someone else holds, a future that never ends is a crash mid-swap.
/// A file [held] names cannot be deleted at all, as a running build's and a
/// freshly placed build's cannot be on Windows.
class _Held extends ForwardingFileSystem {
  _Held(this.before, {this.held = _nothing}) : super(_disk);

  final Future<void> Function(String from) before;
  final bool Function(String path) held;

  static bool _nothing(String path) => false;

  @override
  File file(dynamic path) => _HeldFile(this, delegate.file(path));
}

class _HeldFile extends ForwardingFileSystemEntity<File, io.File>
    with ForwardingFile {
  _HeldFile(this.fileSystem, this.delegate);

  @override
  final _Held fileSystem;

  @override
  final io.File delegate;

  @override
  File wrapFile(io.File delegate) => _HeldFile(fileSystem, delegate);

  @override
  Directory wrapDirectory(io.Directory delegate) =>
      _disk.directory(delegate.path);

  @override
  Link wrapLink(io.Link delegate) => _disk.link(delegate.path);

  @override
  Future<File> rename(String newPath) async {
    await fileSystem.before(path);
    return super.rename(newPath);
  }

  @override
  Future<File> delete({bool recursive = false}) async {
    _refuseIfHeld();
    return super.delete(recursive: recursive);
  }

  @override
  void deleteSync({bool recursive = false}) {
    _refuseIfHeld();
    super.deleteSync(recursive: recursive);
  }

  void _refuseIfHeld() {
    if (fileSystem.held(path)) {
      throw FileSystemException('in use by the scanner', path);
    }
  }
}

/// Every file under [dir] as `relative/path` (always `/`) to its contents.
Map<String, String> _tree(Directory dir) => {
  for (final entity in dir.listSync(recursive: true))
    if (entity is File)
      p.posix.joinAll(p.split(p.relative(entity.path, from: dir.path))): entity
          .readAsStringSync(),
};

/// Leaves behind the journal of a swap cut off after [entry].
void _journalOf(Directory install, JournalEntry entry) => install
    .childFile(BundleSwap.journalName)
    .writeAsStringSync('${entry.line}\n');

void _write(Directory root, Map<String, String> files) {
  for (final MapEntry(key: path, value: body) in files.entries) {
    root.fileSystem.file(p.joinAll([root.path, ...p.posix.split(path)]))
      ..createSync(recursive: true)
      ..writeAsStringSync(body);
  }
}

const _installed = {
  'loaf-chat.exe': 'old exe',
  'flutter_windows.dll': 'old engine',
  'gone.dll': 'only in the old build',
  'data/app.so': 'old code',
  'data/flutter_assets/fonts/a.ttf': 'old font',
  'unins000.exe': 'uninstaller',
  'unins000.dat': 'uninstall log',
};

const _incoming = {
  'loaf-chat.exe': 'new exe',
  'flutter_windows.dll': 'new engine',
  'added.dll': 'only in the new build',
  'data/app.so': 'new code',
  'data/flutter_assets/fonts/a.ttf': 'new font',
};

void main() {
  late Directory root;
  late Directory install;
  late Directory staged;

  setUp(() {
    root = _disk.systemTempDirectory.createTempSync('bundle_swap');
    install = root.childDirectory('Loaf Chat')..createSync();
    staged = root.childDirectory('staged')..createSync();
    _write(install, _installed);
    _write(staged, _incoming);
  });

  tearDown(() => root.deleteSync(recursive: true));

  Map<String, String> after(Map<String, String> bundle) => {
    ...bundle,
    'unins000.exe': 'uninstaller',
    'unins000.dat': 'uninstall log',
  };

  test(
    'the new build takes the old one\'s place; Setup\'s files stay',
    () async {
      await BundleSwap(install.path).apply(staged);
      // The old files wait beside the new ones until the next launch.
      final tree = _tree(install);
      expect(
        Map.fromEntries(tree.entries.where((e) => !e.key.endsWith('.old'))),
        after(_incoming),
      );
      expect(tree['loaf-chat.exe.old'], 'old exe');

      expect(await BundleSwap(install.path).cleanUp(), isFalse);
      expect(_tree(install), after(_incoming));
    },
  );

  test('a build with no executable is refused before anything moves', () async {
    staged.childFile('loaf-chat.exe').deleteSync();
    await expectLater(
      BundleSwap(install.path).apply(staged),
      throwsA(isA<StateError>()),
    );
    expect(_tree(install), _installed);
  });

  test('a file held for a moment is waited for', () async {
    var refusals = 2;
    await BundleSwap(
      install.path,
      fs: _Held((from) async {
        if (from.endsWith('flutter_windows.dll') && refusals-- > 0) {
          throw FileSystemException('in use by the scanner', from);
        }
      }),
      attemptDelay: Duration.zero,
    ).apply(staged);
    expect(_tree(install)['flutter_windows.dll'], 'new engine');
  });

  test('a file held longer than every attempt fails the swap', () async {
    var tries = 0;
    await expectLater(
      BundleSwap(
        install.path,
        fs: _Held((from) async {
          if (from.endsWith('flutter_windows.dll')) {
            tries++;
            throw FileSystemException('in use by the scanner', from);
          }
        }),
        attempts: 3,
        attemptDelay: Duration.zero,
      ).apply(staged),
      throwsA(isA<FileSystemException>()),
    );
    expect(tries, 3);
    expect(_tree(install), _installed);
  });

  // However far a swap gets, a failure leaves the old build whole.
  for (var n = 0; n < 10; n++) {
    test('rename $n failing puts everything back', () async {
      var calls = 0;
      await expectLater(
        BundleSwap(
          install.path,
          fs: _Held((from) async {
            if (calls++ == n) throw FileSystemException('disk full', from);
          }),
          attempts: 1,
        ).apply(staged),
        throwsA(isA<FileSystemException>()),
      );
      expect(_tree(install), _installed);
    });
  }

  // A crash or a power cut mid-swap: the next launch finds the journal.
  for (var n = 0; n < 10; n++) {
    test('a swap cut off at rename $n is undone by the next launch', () async {
      var calls = 0;
      // Renames are real disk work, so no count of event-loop turns is sure
      // to reach the cut; the swap says when it has.
      final cut = Completer<void>();
      unawaited(
        BundleSwap(
          install.path,
          fs: _Held((_) {
            if (calls++ != n) return Future.value();
            cut.complete();
            return Completer<void>().future; // never
          }),
        ).apply(staged),
      );
      await cut.future;

      expect(await BundleSwap(install.path).cleanUp(), isTrue);
      expect(_tree(install), _installed);
    });
  }

  // The undo meets the same locks the swap does. What it cannot put back
  // keeps its `.old` self, and the journal stays to say so.
  test(
    'an undo a held file cuts short is finished by the next launch',
    () async {
      var calls = 0;
      await expectLater(
        BundleSwap(
          install.path,
          // The last rename fails with the new engine already in place, and
          // nothing can delete that engine until the next launch.
          fs: _Held((from) async {
            if (calls++ == 9) throw FileSystemException('disk full', from);
          }, held: (path) => p.basename(path) == 'flutter_windows.dll'),
          attempts: 1,
        ).apply(staged),
        // The failure that started the undo, not one raised undoing it.
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.message,
            'message',
            'disk full',
          ),
        ),
      );

      final tree = _tree(install);
      // The new engine could not go, so the old one waits under `.old` for
      // the undo to be finished, and the journal says it is not.
      expect(tree['flutter_windows.dll'], 'new engine');
      expect(tree['flutter_windows.dll.old'], 'old engine');
      expect(tree, contains(BundleSwap.journalName));
      // Everything the undo did reach is back.
      expect(tree['loaf-chat.exe'], 'old exe');
      expect(tree['data/app.so'], 'old code');
      expect(tree, isNot(contains('added.dll')));

      // The next launch, with nothing held: the undo finishes, and the old
      // build is whole again.
      expect(await BundleSwap(install.path).cleanUp(), isTrue);
      expect(_tree(install), _installed);
    },
  );

  test('an undo waits for a file held for a moment', () async {
    var refusals = 2;
    await expectLater(
      BundleSwap(
        install.path,
        fs: _Held(
          // The new executable, swapped last, never goes in: by then the
          // new engine is in place, and the undo has to take it out again.
          (from) async {
            if (p.basename(from) == 'loaf-chat.exe' &&
                p.isWithin(staged.path, from)) {
              throw FileSystemException('held for good', from);
            }
          },
          // The scanner lets the new engine go while the undo is asking.
          held: (path) =>
              p.basename(path) == 'flutter_windows.dll' && refusals-- > 0,
        ),
        attemptDelay: Duration.zero,
      ).apply(staged),
      throwsA(isA<FileSystemException>()),
    );
    expect(refusals, isNegative, reason: 'the undo never asked for the engine');
    // Waited for, so the undo ran to the end and took its journal with it.
    expect(_tree(install), _installed);
  });

  test('a journal played again leaves the old build where it is', () async {
    // An undo that finished but could not delete its own journal: every
    // old file is back under its own name with no `.old` beside it, and
    // the next launch must take none of them for the new build.
    install
        .childFile(BundleSwap.journalName)
        .writeAsStringSync(
          [
            const SetAside(BuildFile('data/app.so')).line,
            const PutInPlace(BuildFile('data/app.so')).line,
            '',
          ].join('\n'),
        );
    expect(await BundleSwap(install.path).cleanUp(), isTrue);
    expect(_tree(install), _installed);
  });

  test('a swap is refused while an undo is unfinished', () async {
    _journalOf(install, const SetAside(BuildFile('flutter_windows.dll')));
    await expectLater(
      BundleSwap(install.path).apply(staged),
      throwsA(isA<StateError>()),
    );
    expect(_tree(install)..remove(BundleSwap.journalName), _installed);
  });

  test('an undo that cannot finish keeps what it has to put back', () async {
    // Cut off with the engine stepped aside: that `.old` is the only copy
    // of it left, and no launch may throw it away before it is back.
    _journalOf(install, const SetAside(BuildFile('flutter_windows.dll')));
    final engine = install.childFile('flutter_windows.dll');
    engine.renameSync('${engine.path}${BuildFile.aside}');

    await expectLater(
      BundleSwap(
        install.path,
        fs: _Held((from) async {
          if (from.endsWith(BuildFile.aside)) {
            throw FileSystemException('in use by the scanner', from);
          }
        }),
        attempts: 1,
      ).cleanUp(),
      throwsA(isA<StateError>()),
    );
    final tree = _tree(install);
    expect(tree['flutter_windows.dll.old'], 'old engine');
    expect(tree, contains(BundleSwap.journalName));
  });

  group('a journal line', () {
    test('reads back as what was written', () {
      for (final entry in [
        const SetAside(BuildFile('data/app.so')),
        const PutInPlace(BuildFile('loaf-chat.exe')),
      ]) {
        final read = JournalEntry.parse(entry.line);
        expect(read.runtimeType, entry.runtimeType);
        expect(read!.file, entry.file);
      }
    });

    test('torn by a crash is no entry', () {
      for (final torn in ['', 'ol', 'old', 'new\t', 'moved\tdata/app.so']) {
        expect(JournalEntry.parse(torn), isNull, reason: torn);
      }
    });
  });
}
