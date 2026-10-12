import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/platform/system_audio_devices.dart';

const _channel = MethodChannel('loaf/audio');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  group('a runner that lists its devices', () {
    setUp(() {
      messenger.setMockMethodCallHandler(
        _channel,
        (call) async => switch (call.method) {
          'microphones' => [
            {'id': 'rode:2', 'label': 'RODE NT-USB'},
            {'id': 'built-in', 'label': 'MacBook Pro Microphone'},
          ],
          'speakers' => [
            {'id': 'fiio:2', 'label': 'FiiO K11'},
          ],
          _ => null,
        },
      );
    });

    test('has the microphones it names', () async {
      final devices = await SystemAudioDevices().microphones();

      expect(devices.map((device) => (device.id, device.label)), [
        ('rode:2', 'RODE NT-USB'),
        ('built-in', 'MacBook Pro Microphone'),
      ]);
    });

    test('has the speakers it names', () async {
      final devices = await SystemAudioDevices().speakers();

      expect(devices.map((device) => (device.id, device.label)), [
        ('fiio:2', 'FiiO K11'),
      ]);
    });

    test('says so when it reports a change', () async {
      final changed = SystemAudioDevices().changes.first;

      await messenger.handlePlatformMessage(
        _channel.name,
        _channel.codec.encodeMethodCall(const MethodCall('changed')),
        (_) {},
      );

      await expectLater(changed, completes);
    });
  });

  test('switching the speaker is asked of the runner, by id', () async {
    final asked = <MethodCall>[];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      asked.add(call);
      return null;
    });

    await SystemAudioDevices().selectSpeaker('fiio:2');

    expect(asked.map((call) => (call.method, call.arguments)), [
      ('selectSpeaker', 'fiio:2'),
    ]);
  });

  test('a runner without the channel has nothing to choose from', () async {
    final devices = SystemAudioDevices();

    expect(await devices.microphones(), isEmpty);
    expect(await devices.speakers(), isEmpty);
  });
}
