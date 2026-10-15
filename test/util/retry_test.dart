import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/util/retry.dart';

void main() {
  const delay = Duration.zero;

  test('returns the first success', () async {
    var calls = 0;
    final result = await retry<int, FileSystemException>(
      () async {
        if (++calls < 3) throw const FileSystemException('held');
        return calls;
      },
      attempts: 5,
      delay: delay,
    );
    expect(result, 3);
  });

  test('gives up after the last attempt with its error', () async {
    var calls = 0;
    await expectLater(
      retry<void, FileSystemException>(
        () async {
          calls++;
          throw const FileSystemException('held');
        },
        attempts: 3,
        delay: delay,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(calls, 3);
  });

  test('anything else is not retried', () async {
    var calls = 0;
    await expectLater(
      retry<void, FileSystemException>(
        () async {
          calls++;
          throw StateError('a bug');
        },
        attempts: 3,
        delay: delay,
      ),
      throwsStateError,
    );
    expect(calls, 1);
  });
}
