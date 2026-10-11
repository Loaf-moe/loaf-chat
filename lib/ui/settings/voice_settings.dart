/// Which microphone and which speaker a call uses.
///
/// Saved to `voice.json` beside the other settings in the support
/// directory. Per device, not per account: the devices are this machine's.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

/// A microphone or a speaker, as the system names it.
@immutable
class AudioDevice {
  const AudioDevice(this.id, this.label);

  /// Null for anything that is not an id and a label, both text and
  /// neither empty.
  static AudioDevice? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final label = json['label'];
    if (id is! String || id.isEmpty || label is! String) return null;
    final trimmed = label.trim();
    return trimmed.isEmpty ? null : AudioDevice(id, trimmed);
  }

  /// What the system knows the device by. Opaque: only ever handed back.
  final String id;
  final String label;

  Map<String, Object> toJson() => {'id': id, 'label': label};

  @override
  bool operator ==(Object other) => other is AudioDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

@immutable
class VoiceSettings {
  const VoiceSettings({this.microphone, this.speaker});

  /// Anything unreadable falls back to that field's default, so a
  /// hand-edited file degrades instead of failing.
  factory VoiceSettings.fromJson(Object? json) {
    if (json is! Map) return const VoiceSettings();
    return VoiceSettings(
      microphone: AudioDevice.fromJson(json['microphone']),
      speaker: AudioDevice.fromJson(json['speaker']),
    );
  }

  /// Null: whichever the system has as its default.
  final AudioDevice? microphone;
  final AudioDevice? speaker;

  Map<String, Object> toJson() => {
    'microphone': ?microphone?.toJson(),
    'speaker': ?speaker?.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is VoiceSettings &&
      other.microphone == microphone &&
      other.speaker == speaker;

  @override
  int get hashCode => Object.hash(microphone, speaker);
}

abstract interface class VoiceStore {
  /// Null when nothing has been saved, or what was saved can't be read.
  Future<VoiceSettings?> load();

  Future<void> save(VoiceSettings settings);
}

/// Forgets on exit: for tests and the mock backend.
class MemoryVoiceStore implements VoiceStore {
  MemoryVoiceStore([this.saved]);

  VoiceSettings? saved;

  @override
  Future<VoiceSettings?> load() async => saved;

  @override
  Future<void> save(VoiceSettings settings) async => saved = settings;
}

class FileVoiceStore implements VoiceStore {
  FileVoiceStore(this.file);

  static Future<FileVoiceStore> inSupportDirectory() async => FileVoiceStore(
    File(
      '${(await getApplicationSupportDirectory()).path}'
      '${Platform.pathSeparator}voice.json',
    ),
  );

  final File file;

  @override
  Future<VoiceSettings?> load() async {
    try {
      return VoiceSettings.fromJson(jsonDecode(await file.readAsString()));
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> save(VoiceSettings settings) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(settings.toJson()));
  }
}

/// The machine's microphones and speakers.
abstract interface class AudioDevices {
  Future<List<AudioDevice>> microphones();

  Future<List<AudioDevice>> speakers();

  /// An event whenever a device may have come or gone.
  Stream<void> get changes;
}

class VoiceController extends ChangeNotifier {
  VoiceController({
    required this._store,
    required this._devices,
    VoiceSettings settings = const VoiceSettings(),
  }) : settings = ValueNotifier(settings);

  static Future<VoiceController> load(
    VoiceStore store, {
    required AudioDevices devices,
  }) async => VoiceController(
    store: store,
    devices: devices,
    settings: await store.load() ?? const VoiceSettings(),
  );

  final VoiceStore _store;
  final AudioDevices _devices;

  /// Null until the first [refresh]: asking the machine about its devices
  /// starts WebRTC, which a launch that never opens a call has no use for.
  StreamSubscription<void>? _changes;

  /// What is chosen, for the calls: they follow it without knowing about
  /// settings pages.
  final ValueNotifier<VoiceSettings> settings;

  /// What the machine has, as of the last [refresh]. Empty before the first.
  List<AudioDevice> microphones = const [];
  List<AudioDevice> speakers = const [];

  /// Counts [refresh]es.
  var _asked = 0;

  AudioDevice? get microphone => settings.value.microphone;
  AudioDevice? get speaker => settings.value.speaker;

  /// Asks the machine again what it has, and from then on whenever it says
  /// that changed.
  Future<void> refresh() async {
    _changes ??= _devices.changes.listen((_) => unawaited(refresh()));
    final asked = ++_asked;
    final (ins, outs) = await (
      _devices.microphones(),
      _devices.speakers(),
    ).wait;
    // Overtaken: a later asking has the newer answer.
    if (asked != _asked) return;
    microphones = ins;
    speakers = outs;
    notifyListeners();
  }

  /// [device] null goes back to the system's default.
  void chooseMicrophone(AudioDevice? device) =>
      _update(VoiceSettings(microphone: device, speaker: speaker));

  void chooseSpeaker(AudioDevice? device) =>
      _update(VoiceSettings(microphone: microphone, speaker: device));

  void _update(VoiceSettings next) {
    if (next == settings.value) return;
    settings.value = next;
    notifyListeners();
    // A pick that can't be saved still applies for this run; losing it at
    // the next launch beats crashing over a microphone.
    unawaited(_store.save(next).onError<FileSystemException>((_, _) {}));
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    settings.dispose();
    super.dispose();
  }
}

/// Sits above `MaterialApp`, so routes on the root navigator (the settings
/// dialog among them) can reach the controller.
class VoiceScope extends InheritedNotifier<VoiceController> {
  const VoiceScope({
    super.key,
    required VoiceController controller,
    required super.child,
  }) : super(notifier: controller);

  static VoiceController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<VoiceScope>()?.notifier;
}
