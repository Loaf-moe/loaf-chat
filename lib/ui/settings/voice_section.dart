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
    listenable: Listenable.merge([
      widget.controller,
      widget.controller.applying,
    ]),
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

  List<Widget> _choices(
    List<AudioDevice> devices,
    AudioDevice? chosen,
    ValueChanged<AudioDevice?> choose,
  ) => [
    for (final (index, choice) in deviceChoices(devices, chosen).indexed) ...[
      if (index > 0) const SizedBox(height: LoafSpace.x2),
      SettingsChoice(
        title: choice.label,
        selected: choice.chosen,
        busy: choice.chosen && widget.controller.applying.value,
        onTap: () => choose(choice.device),
      ),
    ],
  ];
}
