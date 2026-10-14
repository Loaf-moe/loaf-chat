import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/log_file.dart';
import 'package:matrix/matrix.dart' show Level, LogEvent;

void main() {
  late Directory dir;
  late LogFile log;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('loaf-log');
    log = LogFile(File('${dir.path}/loaf.log'), cap: 200);
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<List<String>> lines() async {
    await log.flushed;
    return log.file.readAsLinesSync();
  }

  test('writes a line per event, with its level and exception', () async {
    log.write(
      LogEvent(
        '[loaf] notification failed',
        exception: 'show failed: status -3',
        level: Level.warning,
      ),
    );
    log.write(LogEvent('[loaf] members not loaded', level: Level.error));
    final written = await lines();
    expect(written, hasLength(2));
    expect(
      written[0],
      endsWith(' warning [loaf] notification failed: show failed: status -3'),
    );
    expect(written[1], endsWith(' error [loaf] members not loaded'));
    expect(
      DateTime.tryParse(written[0].split(' ').first),
      isNotNull,
      reason: 'the time comes first',
    );
  });

  test('keeps a stack trace\'s first lines', () async {
    log.write(
      LogEvent(
        'failed',
        stackTrace: StackTrace.fromString(
          List.generate(12, (i) => '#$i frame').join('\n'),
        ),
        level: Level.error,
      ),
    );
    final written = await lines();
    expect(written, hasLength(9));
    expect(written.last, '#7 frame');
  });

  test('the SDK talking to itself is not written', () async {
    log.write(LogEvent('Initialize client', level: Level.info));
    log.write(LogEvent('syncing', level: Level.verbose));
    await log.flushed;
    expect(log.file.existsSync(), isFalse);
  });

  test('rotates past the cap, keeping one file behind', () async {
    for (var i = 0; i < 12; i++) {
      log.write(LogEvent('line $i ${'x' * 40}', level: Level.warning));
    }
    await log.flushed;
    final behind = File('${dir.path}/loaf.log.1');
    expect(behind.existsSync(), isTrue);
    expect(behind.lengthSync(), greaterThan(200), reason: 'stepped aside full');
    // What stepped aside came before what is current, nothing lost between.
    int lineOf(String line) => int.parse(line.split(' line ')[1].split(' ')[0]);
    final before = behind.readAsLinesSync().map(lineOf).toList();
    final current = log.file.readAsLinesSync().map(lineOf).toList();
    expect(current.first, before.last + 1);
    expect(current.last, 11);
    expect(
      dir.listSync().length,
      2,
      reason: 'the file behind is replaced, never stacked',
    );
  });

  test('a folder that is gone takes no line and throws nothing', () async {
    dir.deleteSync(recursive: true);
    log.write(LogEvent('late', level: Level.warning));
    await log.flushed;
    expect(dir.existsSync(), isFalse);
  });

  test('lines written together never interleave', () async {
    log.write(LogEvent('a' * 50, level: Level.warning));
    log.write(LogEvent('b' * 50, level: Level.warning));
    final written = await lines();
    expect(written, hasLength(2));
    expect(written[0], endsWith('a' * 50));
    expect(written[1], endsWith('b' * 50));
  });
}
