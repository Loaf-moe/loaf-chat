/// Which microphone and which speaker a call uses, what is done to the
/// microphone's sound, and how loud each person is played.
///
/// Saved to `voice.json` beside the other settings in the support
/// directory. Per device, not per account: the devices are this machine's.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
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

/// One row to choose a device from. A null [device] is the system's
/// default.
typedef DeviceChoice = ({AudioDevice? device, String label, bool chosen});

/// The rows to choose one of [devices] from: the system's default, what the
/// machine has, then [chosen] if the machine does not have it.
List<DeviceChoice> deviceChoices(
  List<AudioDevice> devices,
  AudioDevice? chosen,
) => [
  (device: null, label: 'system default', chosen: chosen == null),
  for (final device in devices)
    (device: device, label: device.label, chosen: device == chosen),
  if (chosen != null && !devices.contains(chosen))
    (device: chosen, label: '${chosen.label} · not connected', chosen: true),
];

@immutable
class VoiceSettings {
  const VoiceSettings({
    this.microphone,
    this.speaker,
    this.echoCancellation = true,
    this.noiseSuppression = true,
    this.automaticGain = true,
    this.highPassFilter = false,
    this.volumes = const {},
  });

  /// The loudest anyone is played: twice as loud as sent.
  static const maxVolume = 2.0;

  /// Anything unreadable falls back to that field's default, so a
  /// hand-edited file degrades instead of failing.
  factory VoiceSettings.fromJson(Object? json) {
    if (json is! Map) return const VoiceSettings();
    return VoiceSettings(
      microphone: AudioDevice.fromJson(json['microphone']),
      speaker: AudioDevice.fromJson(json['speaker']),
      echoCancellation: _switch(json['echoCancellation'], otherwise: true),
      noiseSuppression: _switch(json['noiseSuppression'], otherwise: true),
      automaticGain: _switch(json['automaticGain'], otherwise: true),
      highPassFilter: _switch(json['highPassFilter'], otherwise: false),
      volumes: _volumes(json['volumes']),
    );
  }

  static Map<String, double> _volumes(Object? json) => Map.unmodifiable({
    if (json is Map)
      for (final MapEntry(key: user, value: volume) in json.entries)
        if (user is String &&
            user.isNotEmpty &&
            volume is num &&
            volume >= 0 &&
            volume <= maxVolume)
          user: volume.toDouble(),
  });

  static bool _switch(Object? json, {required bool otherwise}) =>
      json is bool ? json : otherwise;

  /// Null: whichever the system has as its default.
  final AudioDevice? microphone;
  final AudioDevice? speaker;

  /// Keeps what the speaker plays out of the microphone.
  final bool echoCancellation;
  final bool noiseSuppression;

  /// Evens out how loud the microphone is.
  final bool automaticGain;

  /// Takes the lowest of the microphone's sound out.
  final bool highPassFilter;

  /// How loud each person is played, by user id, where 1 is as loud as
  /// sent. Someone absent is played at 1.
  final Map<String, double> volumes;

  /// A device is given as a function, so that null can be chosen.
  VoiceSettings copyWith({
    AudioDevice? Function()? microphone,
    AudioDevice? Function()? speaker,
    bool? echoCancellation,
    bool? noiseSuppression,
    bool? automaticGain,
    bool? highPassFilter,
    Map<String, double>? volumes,
  }) => VoiceSettings(
    microphone: microphone == null ? this.microphone : microphone(),
    speaker: speaker == null ? this.speaker : speaker(),
    echoCancellation: echoCancellation ?? this.echoCancellation,
    noiseSuppression: noiseSuppression ?? this.noiseSuppression,
    automaticGain: automaticGain ?? this.automaticGain,
    highPassFilter: highPassFilter ?? this.highPassFilter,
    volumes: volumes ?? this.volumes,
  );

  Map<String, Object> toJson() => {
    'microphone': ?microphone?.toJson(),
    'speaker': ?speaker?.toJson(),
    'echoCancellation': echoCancellation,
    'noiseSuppression': noiseSuppression,
    'automaticGain': automaticGain,
    'highPassFilter': highPassFilter,
    'volumes': volumes,
  };

  @override
  bool operator ==(Object other) =>
      other is VoiceSettings &&
      other.microphone == microphone &&
      other.speaker == speaker &&
      other.echoCancellation == echoCancellation &&
      other.noiseSuppression == noiseSuppression &&
      other.automaticGain == automaticGain &&
      other.highPassFilter == highPassFilter &&
      mapEquals(other.volumes, volumes);

  @override
  int get hashCode => Object.hash(
    microphone,
    speaker,
    echoCancellation,
    noiseSuppression,
    automaticGain,
    highPassFilter,
    Object.hashAllUnordered([
      for (final MapEntry(:key, :value) in volumes.entries)
        Object.hash(key, value),
    ]),
  );
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

  /// The newest settings not yet handed to the store, and whether a save
  /// is under way.
  VoiceSettings? _unsaved;
  var _saving = false;

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
      _update(settings.value.copyWith(microphone: () => device));

  void chooseSpeaker(AudioDevice? device) =>
      _update(settings.value.copyWith(speaker: () => device));

  void setEchoCancellation(bool on) =>
      _update(settings.value.copyWith(echoCancellation: on));

  void setNoiseSuppression(bool on) =>
      _update(settings.value.copyWith(noiseSuppression: on));

  void setAutomaticGain(bool on) =>
      _update(settings.value.copyWith(automaticGain: on));

  void setHighPassFilter(bool on) =>
      _update(settings.value.copyWith(highPassFilter: on));

  /// How loud [userId] is played, where 1 is as loud as sent.
  double volumeOf(String userId) => settings.value.volumes[userId] ?? 1;

  void setVolume(String userId, double volume) => _update(
    settings.value.copyWith(
      volumes: Map.unmodifiable({
        for (final MapEntry(:key, :value) in settings.value.volumes.entries)
          if (key != userId) key: value,
        if (volume != 1) userId: volume,
      }),
    ),
  );

  void _update(VoiceSettings next) {
    if (next == settings.value) return;
    settings.value = next;
    notifyListeners();
    _unsaved = next;
    if (!_saving) unawaited(_save());
  }

  /// One write at a time, and only the newest of those waiting: writes
  /// begun together may finish in any order, and a slider makes many.
  Future<void> _save() async {
    _saving = true;
    try {
      for (var next = _unsaved; next != null; next = _unsaved) {
        _unsaved = null;
        try {
          await _store.save(next);
        } on FileSystemException {
          // A pick that can't be saved still applies for this run; losing
          // it at the next launch beats crashing over a microphone.
        }
      }
    } finally {
      _saving = false;
    }
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

  /// For event handlers: looks the controller up without subscribing.
  static VoiceController? find(BuildContext context) =>
      context.getInheritedWidgetOfExactType<VoiceScope>()?.notifier;
}
