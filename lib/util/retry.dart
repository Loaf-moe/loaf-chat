/// Trying again when a failure is expected to pass.
library;

/// Runs [attempt] up to [attempts] times, [delay] apart, while it throws
/// an [E]. Anything else, or the last [E], is thrown on.
Future<T> retry<T, E extends Object>(
  Future<T> Function() attempt, {
  required int attempts,
  required Duration delay,
}) async {
  assert(attempts > 0);
  for (var left = attempts - 1; ; left--) {
    try {
      return await attempt();
    } on E {
      if (left == 0) rethrow;
      await Future<void>.delayed(delay);
    }
  }
}
