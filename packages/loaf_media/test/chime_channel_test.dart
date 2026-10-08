import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_media/loaf_media.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('playChime asks the platform to play the asset', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('moe.loaf.chat/media'), (
          call,
        ) async {
          calls.add(call);
          return null;
        });
    await LoafMedia.playChime('assets/sounds/chime.wav');
    expect(calls.single.method, 'chime.play');
    expect(calls.single.arguments, {'asset': 'assets/sounds/chime.wav'});
  });
}
