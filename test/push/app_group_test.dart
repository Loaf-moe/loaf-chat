// The move into the App Group container runs on launch, on a phone, and can
// be killed half way through it: iOS suspends an app whenever it likes. These
// pin the two things that would cost a user their history — overwriting a
// live database, and laying a stale -wal beside one — and the resume after a
// move cut short.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/push/app_group.dart';

void main() {
  late Directory from, to;
  setUp(() async {
    from = await Directory.systemTemp.createTemp('support');
    to = await Directory.systemTemp.createTemp('group');
  });
  tearDown(() async {
    await from.delete(recursive: true);
    await to.delete(recursive: true);
  });

  Future<void> put(Directory d, String name, String body) =>
      File('${d.path}/$name').writeAsString(body);
  String? read(Directory d, String name) {
    final f = File('${d.path}/$name');
    return f.existsSync() ? f.readAsStringSync() : null;
  }

  test('moves the database, its journal and the settings', () async {
    await put(from, 'loaf.sqlite', 'db');
    await put(from, 'loaf.sqlite-wal', 'wal');
    await put(from, 'notifications.json', '{}');
    await moveIntoGroup(from: from, to: to);
    expect(read(to, 'loaf.sqlite'), 'db');
    expect(read(to, 'loaf.sqlite-wal'), 'wal');
    expect(read(to, 'notifications.json'), '{}');
    expect(read(from, 'loaf.sqlite'), isNull);
  });

  test('a fresh install has nothing to move', () async {
    await moveIntoGroup(from: from, to: to);
    expect(to.listSync(), isEmpty);
  });

  test('never overwrites a database already in the group', () async {
    await put(from, 'loaf.sqlite', 'old');
    await put(to, 'loaf.sqlite', 'new');
    await moveIntoGroup(from: from, to: to);
    expect(read(to, 'loaf.sqlite'), 'new');
  });

  test("never lays the old database's journal beside the live one", () async {
    await put(from, 'loaf.sqlite', 'old');
    await put(from, 'loaf.sqlite-wal', 'old wal');
    await put(to, 'loaf.sqlite', 'new');
    await moveIntoGroup(from: from, to: to);
    expect(read(to, 'loaf.sqlite-wal'), isNull);
  });

  test('finishes a move interrupted after the database', () async {
    // Killed after the first rename: the db is in the group, its WAL is not.
    await put(to, 'loaf.sqlite', 'db');
    await put(from, 'loaf.sqlite-wal', 'wal');
    await moveIntoGroup(from: from, to: to);
    expect(read(to, 'loaf.sqlite-wal'), 'wal');
  });
}
