/// Microphones and speakers held in memory: the mock backend's, and the
/// tests'. What the machine "has" is whatever the two functions answer when
/// asked, so a test plugs a device in by changing what they return.
library;

import '../settings/voice_settings.dart';

const mockMicrophones = [
  AudioDevice('builtin-mic', 'MacBook Pro Microphone'),
  AudioDevice('airpods-mic', 'AirPods Pro'),
  AudioDevice('yeti', 'Blue Yeti'),
];

const mockSpeakers = [
  AudioDevice('builtin-out', 'MacBook Pro Speakers'),
  AudioDevice('airpods-out', 'AirPods Pro'),
];

class MemoryAudioDevices implements AudioDevices {
  MemoryAudioDevices({
    List<AudioDevice> Function()? microphones,
    List<AudioDevice> Function()? speakers,
    this.changes = const Stream.empty(),
  }) : _microphones = microphones ?? (() => mockMicrophones),
       _speakers = speakers ?? (() => mockSpeakers);

  final List<AudioDevice> Function() _microphones;
  final List<AudioDevice> Function() _speakers;

  @override
  final Stream<void> changes;

  @override
  Future<List<AudioDevice>> microphones() async => _microphones();

  @override
  Future<List<AudioDevice>> speakers() async => _speakers();
}
