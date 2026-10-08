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
