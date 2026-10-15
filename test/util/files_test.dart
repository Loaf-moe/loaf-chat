import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/util/files.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('files_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  test(
    'writes the bytes, making the folder, and leaves nothing beside',
    () async {
      final file = File(p.join(dir.path, 'a', 'b.bin'));
      await writeAtomically(file, [1, 2, 3]);
      expect(file.readAsBytesSync(), [1, 2, 3]);
      expect(file.parent.listSync(), hasLength(1));
    },
  );

  test('replaces what was there whole', () async {
    final file = File(p.join(dir.path, 'b.bin'))..writeAsBytesSync([9, 9]);
    await writeAtomically(file, [4]);
    expect(file.readAsBytesSync(), [4]);
  });

  test('two writes at once each land whole', () async {
    final file = File(p.join(dir.path, 'c.bin'));
    await Future.wait([
      writeAtomically(file, List.filled(4096, 1)),
      writeAtomically(file, List.filled(4096, 2)),
    ]);
    expect(file.readAsBytesSync().toSet(), hasLength(1));
    expect(dir.listSync(), hasLength(1));
  });
}
