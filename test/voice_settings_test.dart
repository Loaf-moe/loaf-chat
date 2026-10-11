import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/mock/mock_audio_devices.dart';
import 'package:loaf_native/ui/settings/voice_settings.dart';

const _rode = AudioDevice('rode', 'RODE NT-USB');
const _sony = AudioDevice('sony', 'WH-1000XM3');

Future<VoiceController> _controller({
  VoiceStore? store,
  AudioDevices? devices,
}) async {
  final controller = await VoiceController.load(
    store ?? MemoryVoiceStore(),
    devices: devices ?? MemoryAudioDevices(),
  );
  addTearDown(controller.dispose);
  return controller;
}

class _FullDisk implements VoiceStore {
  @override
  Future<VoiceSettings?> load() async => null;

  @override
  Future<void> save(VoiceSettings settings) async =>
      throw const FileSystemException('no space left');
}

/// A machine that answers for its microphones when a test says so.
class _Slow implements AudioDevices {
  final microphoneAnswers = <Completer<List<AudioDevice>>>[];

  @override
  Future<List<AudioDevice>> microphones() {
    microphoneAnswers.add(Completer());
    return microphoneAnswers.last.future;
  }

  @override
  Future<List<AudioDevice>> speakers() async => const [];

  @override
  Stream<void> get changes => const Stream.empty();
}

void main() {
  test('nothing saved means the system default for both', () async {
    final controller = await _controller(store: MemoryVoiceStore());

    expect(controller.microphone, isNull);
    expect(controller.speaker, isNull);
  });

  test('the file store reads back what it saved', () async {
    final dir = await Directory.systemTemp.createTemp('voice');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/v/voice.json');

    await FileVoiceStore(file)
        .save(const VoiceSettings(microphone: _rode, speaker: _sony));
    final back = await FileVoiceStore(file).load();

    expect(back, const VoiceSettings(microphone: _rode, speaker: _sony));
    expect(back?.microphone?.label, 'RODE NT-USB');
  });

  test('an unreadable file reads as nothing saved', () async {
    final dir = await Directory.systemTemp.createTemp('voice');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/voice.json')..writeAsStringSync('{nope');

    expect(await FileVoiceStore(file).load(), isNull);
  });

  group('a saved device falls back to the default alone when it', () {
    const shapes = <String, Object?>{
      'is not an object': 'rode',
      'has no id': {'label': 'RODE NT-USB'},
      'has an empty id': {'id': '', 'label': 'RODE NT-USB'},
      'has an id that is no text': {'id': 7, 'label': 'RODE NT-USB'},
      'has no label': {'id': 'rode'},
      'has an empty label': {'id': 'rode', 'label': ''},
      'has a blank label': {'id': 'rode', 'label': '  '},
    };
    for (final MapEntry(key: name, value: shape) in shapes.entries) {
      test(name, () {
        final settings = VoiceSettings.fromJson({
          'microphone': shape,
          'speaker': _sony.toJson(),
        });

        expect(settings.microphone, isNull);
        expect(settings.speaker, _sony);
      });
    }
  });

  test('a choice goes to the store', () async {
    final store = MemoryVoiceStore();
    final controller = await _controller(store: store);

    controller.chooseMicrophone(_rode);

    expect(store.saved, const VoiceSettings(microphone: _rode));
  });

  test('a choice leaves the other device as it was', () async {
    final controller = await _controller(
      store: MemoryVoiceStore(const VoiceSettings(speaker: _sony)),
    );

    controller.chooseMicrophone(_rode);

    expect(controller.speaker, _sony);
  });

  test('choosing nothing goes back to the system default', () async {
    final controller = await _controller(
      store: MemoryVoiceStore(const VoiceSettings(microphone: _rode)),
    );

    controller.chooseMicrophone(null);

    expect(controller.microphone, isNull);
  });

  test('a choice tells the settings page and the calls', () async {
    final controller = await _controller();
    var page = 0;
    var calls = 0;
    controller.addListener(() => page++);
    controller.settings.addListener(() => calls++);

    controller.chooseSpeaker(_sony);

    expect((page, calls), (1, 1));
  });

  test('choosing the same again tells no one', () async {
    final controller = await _controller(
      store: MemoryVoiceStore(const VoiceSettings(speaker: _sony)),
    );
    var told = 0;
    controller.addListener(() => told++);

    controller.chooseSpeaker(_sony);

    expect(told, 0);
  });

  test('the lists are empty until the machine has been asked', () async {
    final controller = await _controller();

    expect(controller.microphones, isEmpty);
    expect(controller.speakers, isEmpty);
  });

  test('asking the machine fills both lists', () async {
    final controller = await _controller(
      devices: MemoryAudioDevices(
        microphones: () => const [_rode],
        speakers: () => const [_sony],
      ),
    );

    await controller.refresh();

    expect(controller.microphones, const [_rode]);
    expect(controller.speakers, const [_sony]);
  });

  test('a saved label loses the space around it', () {
    final device = AudioDevice.fromJson({'id': 'rode', 'label': ' RODE '});

    expect(device?.label, 'RODE');
  });

  test('a choice that cannot be saved still applies', () async {
    final controller = await _controller(store: _FullDisk());

    controller.chooseMicrophone(_rode);
    await pumpEventQueue();

    expect(controller.microphone, _rode);
  });

  test('an answer overtaken by a later asking is dropped', () async {
    final devices = _Slow();
    final controller = await _controller(devices: devices);

    final first = controller.refresh();
    final second = controller.refresh();
    devices.microphoneAnswers[1].complete(const [_rode, _sony]);
    devices.microphoneAnswers[0].complete(const [_rode]);
    await (first, second).wait;

    expect(controller.microphones, const [_rode, _sony]);
  });

  test('the machine is not watched before its devices are asked for', () async {
    // Broadcast: closing a stream nobody listened to otherwise never ends.
    final plugged = StreamController<void>.broadcast();
    addTearDown(plugged.close);

    await _controller(devices: MemoryAudioDevices(changes: plugged.stream));

    expect(plugged.hasListener, isFalse);
  });

  test('the lists follow the machine when it says they changed', () async {
    final plugged = StreamController<void>();
    addTearDown(plugged.close);
    var microphones = const [_rode];
    final controller = await _controller(
      devices: MemoryAudioDevices(
        microphones: () => microphones,
        changes: plugged.stream,
      ),
    );
    await controller.refresh();

    microphones = const [_rode, _sony];
    plugged.add(null);
    await pumpEventQueue();

    expect(controller.microphones, const [_rode, _sony]);
  });
}
