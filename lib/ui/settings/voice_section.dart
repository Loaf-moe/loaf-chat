/// Settings, voice: which microphone and which speaker calls use, and what
/// is done to the microphone's sound.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/loaf_theme.dart';
import 'settings_controls.dart';
import 'voice_settings.dart';

class VoiceSection extends StatefulWidget {
  const VoiceSection({super.key, required this.controller});

  final VoiceController controller;

  @override
  State<VoiceSection> createState() => _VoiceSectionState();
}

class _VoiceSectionState extends State<VoiceSection> {
  @override
  void initState() {
    super.initState();
    // Not every system says when a device comes or goes; opening the
    // section always looks again.
    unawaited(widget.controller.refresh());
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final settings = controller.settings.value;
      return ListView(
        padding: const EdgeInsets.all(LoafSpace.x6),
        children: [
          const SettingsLabel(label: 'microphone'),
          ..._choices(
            controller.microphones,
            settings.microphone,
            controller.chooseMicrophone,
          ),
          const SizedBox(height: LoafSpace.x4),
          const SettingsLabel(label: 'speaker'),
          ..._choices(
            controller.speakers,
            settings.speaker,
            controller.chooseSpeaker,
          ),
          const SizedBox(height: LoafSpace.x4),
          const SettingsLabel(label: 'processing'),
          SettingsCheck(
            title: 'echo cancellation',
            detail: 'keeps what your speakers play out of your microphone',
            value: settings.echoCancellation,
            onChanged: controller.setEchoCancellation,
          ),
          SettingsCheck(
            title: 'noise suppression',
            detail: 'takes steady background noise out of your microphone',
            value: settings.noiseSuppression,
            onChanged: controller.setNoiseSuppression,
          ),
          SettingsCheck(
            title: 'automatic gain',
            detail: 'evens out how loud you are',
            value: settings.automaticGain,
            onChanged: controller.setAutomaticGain,
          ),
          SettingsCheck(
            title: 'high-pass filter',
            detail: 'takes low rumble out of your microphone',
            value: settings.highPassFilter,
            onChanged: controller.setHighPassFilter,
          ),
        ],
      );
    },
  );

  /// "system default", then what the machine has, then the chosen device
  /// if the machine no longer has it.
  List<Widget> _choices(
    List<AudioDevice> devices,
    AudioDevice? chosen,
    ValueChanged<AudioDevice?> choose,
  ) => [
    SettingsChoice(
      title: 'system default',
      selected: chosen == null,
      onTap: () => choose(null),
    ),
    for (final device in devices) ...[
      const SizedBox(height: LoafSpace.x2),
      SettingsChoice(
        title: device.label,
        selected: device == chosen,
        onTap: () => choose(device),
      ),
    ],
    if (chosen != null && !devices.contains(chosen)) ...[
      const SizedBox(height: LoafSpace.x2),
      SettingsChoice(
        title: '${chosen.label} · not connected',
        selected: true,
        onTap: () => choose(chosen),
      ),
    ],
  ];
}
