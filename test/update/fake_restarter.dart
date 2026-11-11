import 'package:loaf_native/update/restarter.dart';

/// Watches instead: what was launched, and how often it quit.
class FakeRestarter extends Restarter {
  final launched = <String>[];
  var quits = 0;

  /// Thrown by the next launch, as if the new build would not start.
  Object? launchFails;

  @override
  Future<void> launch(String executable) async {
    if (launchFails case final error?) throw error;
    launched.add(executable);
  }

  @override
  void quit() => quits++;
}
