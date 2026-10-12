import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/model/chime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('moe.loaf.chat/media');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('the native chime plays the bundled asset', () async {
    String? asset;
    messenger.setMockMethodCallHandler(channel, (call) async {
      asset = (call.arguments as Map)['asset'] as String;
      return null;
    });
    await NativeChime().play();
    expect(asset, chimeAsset);
  });

  group('each sound plays its own bundled file:', () {
    const files = {
      AppSound.message: 'assets/sounds/chime.wav',
      AppSound.callJoined: 'assets/sounds/call_join.wav',
      AppSound.callLeft: 'assets/sounds/call_leave.wav',
    };
    for (final MapEntry(key: sound, value: file) in files.entries) {
      test(sound.name, () async {
        String? asset;
        messenger.setMockMethodCallHandler(channel, (call) async {
          asset = (call.arguments as Map)['asset'] as String;
          return null;
        });

        await NativeChime().play(sound);

        expect(asset, file);
        expect(File(file).existsSync(), isTrue);
      });
    }
  });

  test('a failing chime is swallowed and logged once', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'chime-failed');
    });
    final logged = <Object>[];
    final chime = NativeChime(log: logged.add);
    await chime.play();
    await chime.play();
    expect(logged, hasLength(1));
  });

  test('a platform with no chime is quiet, not an error', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => throw MissingPluginException(),
    );
    await NativeChime(log: (_) => fail('logged')).play();
  });
}
