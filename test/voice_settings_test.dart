import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/mock/mock_audio_devices.dart';
import 'package:loaf_native/ui/settings/voice_settings.dart';
import 'package:loaf_native/util/json_store.dart';

const _rode = AudioDevice('rode', 'RODE NT-USB');
const _sony = AudioDevice('sony', 'WH-1000XM3');

Future<VoiceController> _controller({
  Store<VoiceSettings>? store,
  AudioDevices? devices,
}) async {
  final controller = await VoiceController.load(
    store ?? MemoryStore<VoiceSettings>(),
    devices: devices ?? MemoryAudioDevices(),
  );
  addTearDown(controller.dispose);
  return controller;
}

/// A store whose first write takes longest, as a file's may.
class _SlowFirst implements Store<VoiceSettings> {
  VoiceSettings? saved;

  /// How many writes were begun.
  var writes = 0;

  @override
  Future<VoiceSettings?> load() async => null;

  @override
  Future<void> save(VoiceSettings settings) async {
    await Future<void>.delayed(Duration(milliseconds: writes++ == 0 ? 60 : 0));
    saved = settings;
  }
}

class _FullDisk implements Store<VoiceSettings> {
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
    final controller = await _controller(store: MemoryStore<VoiceSettings>());

    expect(controller.microphone, isNull);
    expect(controller.speaker, isNull);
  });

  test('the file store reads back what it saved', () async {
    final dir = await Directory.systemTemp.createTemp('voice');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/v/voice.json');

    await JsonFileStore(
      file,
      VoiceSettings.fromJson,
    ).save(const VoiceSettings(microphone: _rode, speaker: _sony));
    final back = await JsonFileStore(file, VoiceSettings.fromJson).load();

    expect(back, const VoiceSettings(microphone: _rode, speaker: _sony));
    expect(back?.microphone?.label, 'RODE NT-USB');
  });

  test('an unreadable file reads as nothing saved', () async {
    final dir = await Directory.systemTemp.createTemp('voice');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/voice.json')..writeAsStringSync('{nope');

    expect(await JsonFileStore(file, VoiceSettings.fromJson).load(), isNull);
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
    final store = MemoryStore<VoiceSettings>();
    final controller = await _controller(store: store);

    controller.chooseMicrophone(_rode);

    await pumpEventQueue();

    expect(store.saved, const VoiceSettings(microphone: _rode));
  });

  test('a choice leaves the other device as it was', () async {
    final controller = await _controller(
      store: MemoryStore<VoiceSettings>(const VoiceSettings(speaker: _sony)),
    );

    controller.chooseMicrophone(_rode);

    expect(controller.speaker, _sony);
  });

  test('choosing nothing goes back to the system default', () async {
    final controller = await _controller(
      store: MemoryStore<VoiceSettings>(const VoiceSettings(microphone: _rode)),
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
      store: MemoryStore<VoiceSettings>(const VoiceSettings(speaker: _sony)),
    );
    var told = 0;
    controller.addListener(() => told++);

    controller.chooseSpeaker(_sony);

    expect(told, 0);
  });

  test('nothing saved means every kind of processing is on but the '
      'high-pass filter', () async {
    final controller = await _controller(store: MemoryStore<VoiceSettings>());

    expect(controller.settings.value.echoCancellation, isTrue);
    expect(controller.settings.value.noiseSuppression, isTrue);
    expect(controller.settings.value.automaticGain, isTrue);
    expect(controller.settings.value.highPassFilter, isFalse);
  });

  group('switched from what it starts as, read back from the file:', () {
    const off = <String, VoiceSettings>{
      'echo cancellation': VoiceSettings(echoCancellation: false),
      'noise suppression': VoiceSettings(noiseSuppression: false),
      'automatic gain': VoiceSettings(automaticGain: false),
      'high-pass filter': VoiceSettings(highPassFilter: true),
    };
    for (final MapEntry(key: name, value: settings) in off.entries) {
      test(name, () async {
        final dir = await Directory.systemTemp.createTemp('voice');
        addTearDown(() => dir.delete(recursive: true));
        final file = File('${dir.path}/voice.json');

        await JsonFileStore(file, VoiceSettings.fromJson).save(settings);

        expect(
          await JsonFileStore(file, VoiceSettings.fromJson).load(),
          settings,
        );
      });
    }
  });

  test('a switch that is no yes or no falls back to what it starts as, '
      'alone', () {
    final settings = VoiceSettings.fromJson({
      'echoCancellation': 'no',
      'noiseSuppression': false,
      'highPassFilter': 'yes',
    });

    expect(settings.echoCancellation, isTrue);
    expect(settings.noiseSuppression, isFalse);
    expect(settings.highPassFilter, isFalse);
  });

  group('switching', () {
    final switches = <String, (void Function(VoiceController), VoiceSettings)>{
      'echo cancellation': (
        (c) => c.setEchoCancellation(false),
        const VoiceSettings(
          microphone: _rode,
          speaker: _sony,
          echoCancellation: false,
        ),
      ),
      'noise suppression': (
        (c) => c.setNoiseSuppression(false),
        const VoiceSettings(
          microphone: _rode,
          speaker: _sony,
          noiseSuppression: false,
        ),
      ),
      'automatic gain': (
        (c) => c.setAutomaticGain(false),
        const VoiceSettings(
          microphone: _rode,
          speaker: _sony,
          automaticGain: false,
        ),
      ),
      'high-pass filter': (
        (c) => c.setHighPassFilter(true),
        const VoiceSettings(
          microphone: _rode,
          speaker: _sony,
          highPassFilter: true,
        ),
      ),
    };
    for (final MapEntry(key: name, value: (flip, after)) in switches.entries) {
      test('$name is saved, the rest left as it was', () async {
        final store = MemoryStore<VoiceSettings>(
          const VoiceSettings(microphone: _rode, speaker: _sony),
        );
        final controller = await _controller(store: store);

        flip(controller);

        await pumpEventQueue();

        expect(store.saved, after);
      });
    }
  });

  test('a switch tells the settings page and the calls', () async {
    final controller = await _controller();
    var page = 0;
    var calls = 0;
    controller.addListener(() => page++);
    controller.settings.addListener(() => calls++);

    controller.setNoiseSuppression(false);

    expect((page, calls), (1, 1));
  });

  test('a switch set to what it is tells no one', () async {
    final controller = await _controller();
    var told = 0;
    controller.addListener(() => told++);

    controller.setNoiseSuppression(true);

    expect(told, 0);
  });

  group("each person's volume", () {
    const ada = '@ada:example.com';
    const bo = '@bo:example.com';

    test('is 1 for someone never set', () async {
      final controller = await _controller();

      expect(controller.volumeOf(ada), 1);
    });

    test('is read back from the file', () async {
      final dir = await Directory.systemTemp.createTemp('voice');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/voice.json');
      const settings = VoiceSettings(volumes: {ada: 0.4});

      await JsonFileStore(file, VoiceSettings.fromJson).save(settings);

      expect(
        await JsonFileStore(file, VoiceSettings.fromJson).load(),
        settings,
      );
    });

    test('goes to the store when set', () async {
      final store = MemoryStore<VoiceSettings>();
      final controller = await _controller(store: store);

      controller.setVolume(ada, 0.4);

      expect(controller.volumeOf(ada), 0.4);
      await pumpEventQueue();
      expect(store.saved, const VoiceSettings(volumes: {ada: 0.4}));
    });

    test('is forgotten when set back to 1', () async {
      final store = MemoryStore<VoiceSettings>(
        const VoiceSettings(volumes: {ada: 0.4}),
      );
      final controller = await _controller(store: store);

      controller.setVolume(ada, 1);

      await pumpEventQueue();

      expect(store.saved, const VoiceSettings());
    });

    test("leaves another person's, and the devices, as they were", () async {
      final store = MemoryStore<VoiceSettings>(
        const VoiceSettings(microphone: _rode, volumes: {bo: 1.5}),
      );
      final controller = await _controller(store: store);

      controller.setVolume(ada, 0.4);

      await pumpEventQueue();

      expect(
        store.saved,
        const VoiceSettings(microphone: _rode, volumes: {bo: 1.5, ada: 0.4}),
      );
    });

    test('tells the calls when set', () async {
      final controller = await _controller();
      var calls = 0;
      controller.settings.addListener(() => calls++);

      controller.setVolume(ada, 0.4);

      expect(calls, 1);
    });

    group('is dropped, alone, when saved as', () {
      const shapes = <String, Map<String, Object?>>{
        'no number': {ada: 'loud'},
        'less than nothing': {ada: -0.1},
        'more than double': {ada: 2.1},
        'for nobody': {'': 0.4},
      };
      for (final MapEntry(key: name, value: shape) in shapes.entries) {
        test(name, () {
          final settings = VoiceSettings.fromJson({
            'volumes': {...shape, bo: 1.5},
          });

          expect(settings.volumes, {bo: 1.5});
        });
      }
    });

    test('saved as a whole number is read', () {
      final settings = VoiceSettings.fromJson({
        'volumes': {ada: 2, bo: 0},
      });

      expect(settings.volumes, {ada: 2.0, bo: 0.0});
    });

    test('volumes that are no list of people read as none', () {
      expect(VoiceSettings.fromJson({'volumes': 'loud'}).volumes, isEmpty);
    });
  });

  test('changes in quick succession leave the last in the store', () async {
    final store = _SlowFirst();
    final controller = await _controller(store: store);

    controller.setVolume('@ada:example.com', 0.2);
    controller.setVolume('@ada:example.com', 0.4);
    controller.setVolume('@ada:example.com', 0.6);
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(store.saved?.volumes, {'@ada:example.com': 0.6});
  });

  test('changes made while a write is under way are written as one', () async {
    final store = _SlowFirst();
    final controller = await _controller(store: store);

    for (var tenth = 1; tenth <= 9; tenth++) {
      controller.setVolume('@ada:example.com', tenth / 10);
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(store.writes, lessThan(9));
    expect(store.saved?.volumes, {'@ada:example.com': 0.9});
  });

  test('volumes read from a file cannot be changed in place', () {
    final settings = VoiceSettings.fromJson({
      'volumes': {'@ada:example.com': 0.4},
    });

    expect(
      () => settings.volumes['@bo:example.com'] = 0.2,
      throwsUnsupportedError,
    );
  });

  test('volumes that were set cannot be changed in place', () async {
    final controller = await _controller();
    controller.setVolume('@ada:example.com', 0.4);

    expect(
      () => controller.settings.value.volumes['@bo:example.com'] = 0.2,
      throwsUnsupportedError,
    );
  });

  group('the rows to choose a device from', () {
    test('are the system default, then the devices in order', () {
      final rows = deviceChoices(const [_rode, _sony], null);

      expect(
        [for (final row in rows) (row.device, row.label)],
        const [
          (null, 'system default'),
          (_rode, 'RODE NT-USB'),
          (_sony, 'WH-1000XM3'),
        ],
      );
    });

    test('mark the system default when nothing is chosen', () {
      final rows = deviceChoices(const [_rode, _sony], null);

      expect([for (final row in rows) row.chosen], [true, false, false]);
    });

    test('mark the device chosen', () {
      final rows = deviceChoices(const [_rode, _sony], _sony);

      expect([for (final row in rows) row.chosen], [false, false, true]);
    });

    test('end with a chosen device the machine does not have, as not '
        'connected', () {
      final rows = deviceChoices(const [_rode], _sony);

      expect(
        (rows.last.device, rows.last.label, rows.last.chosen),
        (_sony, 'WH-1000XM3 · not connected', true),
      );
      expect([for (final row in rows) row.chosen], [false, false, true]);
    });
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
