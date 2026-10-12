/// The Mac's microphones and speakers as macOS lists them, over the
/// runner's `loaf/audio` (`macos/Runner/AudioDevicesBridge.swift`).
///
/// WebRTC's own list has nothing but the default until a call starts, and
/// during one it takes the echo canceller's tap on each speaker for a
/// microphone. A device's id is the same in both lists.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../ui/settings/voice_settings.dart';

class SystemAudioDevices implements AudioDevices {
  SystemAudioDevices({this._channel = const MethodChannel('loaf/audio')});

  final MethodChannel _channel;

  @override
  Future<List<AudioDevice>> microphones() => _listed('microphones');

  @override
  Future<List<AudioDevice>> speakers() => _listed('speakers');

  @override
  Stream<void> get changes {
    late final StreamController<void> changes;
    changes = StreamController<void>(
      onListen: () => _channel.setMethodCallHandler((call) async {
        if (call.method == 'changed') changes.add(null);
      }),
      onCancel: () => _channel.setMethodCallHandler(null),
    );
    return changes.stream;
  }

  /// Has the runner point WebRTC's playback at the device with [id]. The
  /// plugin's own call does it on the main thread, and rebuilding the audio
  /// engine there stops the app, the call's signalling included, for
  /// seconds; the runner does it off that thread.
  Future<void> selectSpeaker(String id) =>
      _channel.invokeMethod<void>('selectSpeaker', id);

  Future<List<AudioDevice>> _listed(String method) async {
    final List<Object?>? devices;
    try {
      devices = await _channel.invokeListMethod<Object?>(method);
    } on MissingPluginException {
      // A runner without the channel: nothing to choose from but the default.
      return const [];
    } on PlatformException {
      return const [];
    }
    return [
      for (final device in devices ?? const <Object?>[])
        ?AudioDevice.fromJson(device),
    ];
  }
}
