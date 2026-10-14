/// What has to happen before the app ends: leaving a call, so far.
library;

import 'dart:async';

class BeforeQuit {
  /// How long the app waits on any one thing before it ends regardless.
  static const limit = Duration(seconds: 3);

  final _work = <Future<void> Function()>[];

  void add(Future<void> Function() work) => _work.add(work);

  void remove(Future<void> Function() work) => _work.remove(work);

  /// Runs everything added, side by side, each for at most [limit]. All of
  /// it runs even if some of it fails; the first failure is then thrown.
  Future<void> run() => Future.wait([
    for (final work in [..._work])
      Future.sync(work).timeout(limit, onTimeout: () {}),
  ]);
}
