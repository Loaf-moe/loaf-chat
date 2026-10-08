/// Notifications — what Loaf Chat does when a message arrives somewhere
/// you aren't looking. For now, the chime; step D adds the rest.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/loaf_theme.dart';
import 'notification_settings.dart';
import 'settings_controls.dart';

class NotificationsSection extends StatelessWidget {
  const NotificationsSection({super.key, required this.controller});

  final NotificationController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => ListView(
      padding: const EdgeInsets.all(LoafSpace.x6),
      children: [
        const SettingsLabel(label: 'on this device'),
        SettingsCheck(
          title: 'sound',
          detail: 'a soft chime for messages in other channels.',
          value: controller.sound,
          onChanged: (on) {
            controller.setSound(on);
            // Turning it on plays it, so you know what you turned on.
            if (on) unawaited(controller.chime.play());
          },
        ),
      ],
    ),
  );
}
