import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/shell/before_quit.dart';

void main() {
  test('running runs everything added', () async {
    final ran = <String>[];
    final quit = BeforeQuit()
      ..add(() async => ran.add('one'))
      ..add(() async => ran.add('two'));

    await quit.run();

    expect(ran, unorderedEquals(['one', 'two']));
  });

  test('something removed is not run', () async {
    final ran = <String>[];
    Future<void> one() async => ran.add('one');
    final quit = BeforeQuit()
      ..add(one)
      ..add(() async => ran.add('two'))
      ..remove(one);

    await quit.run();

    expect(ran, ['two']);
  });

  test('one that never finishes holds the run for the limit, no longer', () {
    fakeAsync((async) {
      final quit = BeforeQuit()..add(() => Completer<void>().future);
      var done = false;
      unawaited(quit.run().then((_) => done = true));

      async.elapse(BeforeQuit.limit - const Duration(milliseconds: 1));
      final before = done;
      async.elapse(const Duration(milliseconds: 1));

      expect(before, isFalse);
      expect(done, isTrue);
    });
  });

  test('one that fails before it has begun does not stop the rest', () async {
    final ran = <String>[];
    final quit = BeforeQuit()
      ..add(() => throw StateError('no'))
      ..add(() async => ran.add('two'));

    await expectLater(quit.run(), throwsStateError);

    expect(ran, ['two']);
  });

  test('one that fails does not stop the rest', () async {
    final ran = <String>[];
    final quit = BeforeQuit()
      ..add(() async => throw StateError('no'))
      ..add(() async => ran.add('two'));

    await expectLater(quit.run(), throwsStateError);

    expect(ran, ['two']);
  });
}
