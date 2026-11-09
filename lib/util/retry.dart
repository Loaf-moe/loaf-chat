/// Trying again when a failure is expected to pass.
library;

/// Runs [attempt] up to [attempts] times, [delay] apart, while it throws
/// an [E]. Anything else, or the last [E], is thrown on.
///
/// Name [E] at the call. Nothing in the arguments pins it, so a call that
/// leaves it off gets its bound, `Object`, and retries every error, bugs
/// included. Throws a [RangeError] if [attempts] is below one.
Future<T> retry<T, E extends Object>(
  Future<T> Function() attempt, {
  required int attempts,
  required Duration delay,
}) async {
  if (attempts < 1) throw RangeError.range(attempts, 1, null, 'attempts');
  for (var left = attempts - 1; ; left--) {
    try {
      return await attempt();
    } on E {
      if (left == 0) rethrow;
      await Future<void>.delayed(delay);
    }
  }
}
