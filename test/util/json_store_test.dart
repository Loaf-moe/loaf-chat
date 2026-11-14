import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/util/json_store.dart';
import 'package:path/path.dart' as p;

class _Count implements Jsonable {
  const _Count(this.n);

  static _Count fromJson(Object? json) => json is Map && json['n'] is int
      ? _Count(json['n'] as int)
      : const _Count(0);

  final int n;

  @override
  Object? toJson() => {'n': n};
}

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('json_store_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('reads back what it saved', () async {
    final store = JsonFileStore(
      File(p.join(dir.path, 'n.json')),
      _Count.fromJson,
    );
    await store.save(const _Count(3));
    expect((await store.load())?.n, 3);
  });

  test('nothing saved, or nothing readable, loads as null', () async {
    final file = File(p.join(dir.path, 'n.json'));
    final store = JsonFileStore(file, _Count.fromJson);
    expect(await store.load(), isNull);
    file.writeAsStringSync('{not json');
    expect(await store.load(), isNull);
  });

  test('memory keeps the last value', () async {
    final store = MemoryStore<int>(1);
    expect(await store.load(), 1);
    await store.save(2);
    expect(store.saved, 2);
  });
}
