import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/update/bundle_swap.dart';

final _sep = Platform.pathSeparator;

/// Every file under [dir] as `relative/path` (always `/`) to its contents.
Map<String, String> _tree(Directory dir) => {
  for (final entity in dir.listSync(recursive: true))
    if (entity is File)
      entity.path.substring(dir.path.length + 1).replaceAll(_sep, '/'): entity
          .readAsStringSync(),
};

void _write(Directory root, Map<String, String> files) {
  for (final MapEntry(key: path, value: body) in files.entries) {
    File('${root.path}$_sep${path.replaceAll('/', _sep)}')
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
    root = Directory.systemTemp.createTempSync('bundle_swap');
    install = Directory('${root.path}${_sep}Loaf Chat')..createSync();
    staged = Directory('${root.path}${_sep}staged')..createSync();
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
      await BundleSwap(install).apply(staged);
      // The old files wait beside the new ones until the next launch.
      final tree = _tree(install);
      expect(
        Map.fromEntries(tree.entries.where((e) => !e.key.endsWith('.old'))),
        after(_incoming),
      );
      expect(tree['loaf-chat.exe.old'], 'old exe');

      expect(await BundleSwap(install).cleanUp(), isFalse);
      expect(_tree(install), after(_incoming));
    },
  );

  test('a build with no executable is refused before anything moves', () async {
    File('${staged.path}${_sep}loaf-chat.exe').deleteSync();
    await expectLater(
      BundleSwap(install).apply(staged),
      throwsA(isA<StateError>()),
    );
    expect(_tree(install), _installed);
  });

  test('a file held for a moment is waited for', () async {
    var refusals = 2;
    await BundleSwap(
      install,
      rename: (from, to) async {
        if (from.endsWith('flutter_windows.dll') && refusals-- > 0) {
          throw FileSystemException('in use by the scanner', from);
        }
        await File(from).rename(to);
      },
      retryEvery: Duration.zero,
    ).apply(staged);
    expect(_tree(install)['flutter_windows.dll'], 'new engine');
  });

  // However far a swap gets, a failure leaves the old build whole.
  for (var n = 0; n < 10; n++) {
    test('rename $n failing puts everything back', () async {
      var calls = 0;
      await expectLater(
        BundleSwap(
          install,
          rename: (from, to) async {
            if (calls++ == n) throw FileSystemException('disk full', from);
            await File(from).rename(to);
          },
          retryFor: Duration.zero,
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
      unawaited(
        BundleSwap(
          install,
          rename: (from, to) async {
            if (calls++ == n) return Completer<void>().future; // never
            await File(from).rename(to);
          },
        ).apply(staged),
      );
      await pumpEventQueue();

      expect(await BundleSwap(install).cleanUp(), isTrue);
      expect(_tree(install), _installed);
    });
  }
}
