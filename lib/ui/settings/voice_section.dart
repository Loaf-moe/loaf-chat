/// Settings, voice: which microphone and which speaker calls use.
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
      return ListView(
        padding: const EdgeInsets.all(LoafSpace.x6),
        children: [
          const SettingsLabel(label: 'microphone'),
          ..._choices(
            controller.microphones,
            controller.microphone,
            controller.chooseMicrophone,
          ),
          const SizedBox(height: LoafSpace.x4),
          const SettingsLabel(label: 'speaker'),
          ..._choices(
            controller.speakers,
            controller.speaker,
            controller.chooseSpeaker,
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
