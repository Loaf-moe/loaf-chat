import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/call/call_view.dart';
import 'package:loaf_native/ui/call/calls.dart';

void main() {
  test('a live call has no status words', () {
    expect(callStatus(CallPhase.live), isNull);
  });

  test('a live call taking up another device says so', () {
    expect(
      callStatus(CallPhase.live, switchingAudio: true),
      'switching audio…',
    );
  });

  test('a call that is not live says that first', () {
    expect(
      callStatus(CallPhase.reconnecting, switchingAudio: true),
      'reconnecting…',
    );
  });
}
