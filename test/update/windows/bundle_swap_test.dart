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
class _Held extends ForwardingFileSystem {
  _Held(this.before) : super(_disk);

  final Future<void> Function(String from) before;

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
}

/// Every file under [dir] as `relative/path` (always `/`) to its contents.
Map<String, String> _tree(Directory dir) => {
  for (final entity in dir.listSync(recursive: true))
    if (entity is File)
      p.posix.joinAll(p.split(p.relative(entity.path, from: dir.path))): entity
          .readAsStringSync(),
};

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
