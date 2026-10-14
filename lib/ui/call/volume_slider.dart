/// One person's volume, as a slider.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../settings/voice_settings.dart';
import '../theme/loaf_theme.dart';

/// Per-person volume. Local only: it changes what you hear, not them.
class VolumeSlider extends StatefulWidget {
  const VolumeSlider({super.key, required this.voice, required this.id});

  final VoiceController voice;
  final String id;

  @override
  State<VolumeSlider> createState() => _VolumeSliderState();
}

class _VolumeSliderState extends State<VolumeSlider> {
  late double _value = widget.voice.volumeOf(widget.id);

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Row(
      children: [
        Icon(LucideIcons.volume1, size: 18, color: tokens.textMuted),
        Expanded(
          child: Slider(
            value: _value,
            max: VoiceSettings.maxVolume,
            // Steps of five in a hundred, so that 100% can be dragged to.
            divisions: 40,
            onChanged: (v) {
              setState(() => _value = v);
              widget.voice.setVolume(widget.id, v);
            },
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            '${(_value * 100).round()}%',
            textAlign: TextAlign.end,
            style: loafBody(13, 500).copyWith(color: tokens.textBody),
          ),
        ),
      ],
    );
  }
}

/// [VolumeSlider] as a row of a menu whose actions are [T].
class VolumeMenuEntry<T> extends PopupMenuEntry<T> {
  const VolumeMenuEntry({super.key, required this.voice, required this.id});

  final VoiceController voice;
  final String id;

  @override
  double get height => 48;

  @override
  bool represents(T? value) => false;

  @override
  State<VolumeMenuEntry<T>> createState() => _VolumeMenuEntryState<T>();
}

class _VolumeMenuEntryState<T> extends State<VolumeMenuEntry<T>> {
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 240,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x3),
      child: VolumeSlider(voice: widget.voice, id: widget.id),
    ),
  );
}
