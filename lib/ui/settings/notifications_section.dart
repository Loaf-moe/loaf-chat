/// Notifications: the chime, and on a desktop the notifications themselves
/// and how much they say.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../platform.dart';
import '../theme/loaf_theme.dart';
import '../widgets/loaf_button.dart';
import 'notification_settings.dart';
import 'settings_controls.dart';

class NotificationsSection extends StatefulWidget {
  const NotificationsSection({super.key, required this.controller});

  final NotificationController controller;

  @override
  State<NotificationsSection> createState() => _NotificationsSectionState();
}

class _NotificationsSectionState extends State<NotificationsSection>
    with WidgetsBindingObserver {
  /// Read when the section opens and each time the app comes back, as it
  /// does from System Settings.
  var _blocked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_check());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_check());
  }

  Future<void> _check() async {
    final blocked = await widget.controller.desktop?.blocked() ?? false;
    if (mounted && blocked != _blocked) setState(() => _blocked = blocked);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  String get _os =>
      defaultTargetPlatform == TargetPlatform.windows ? 'windows' : 'macos';

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final desktop = isDesktop ? controller.desktop : null;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(LoafSpace.x6),
        children: [
          const SettingsLabel(label: 'on this device'),
          if (desktop != null) ...[
            SettingsCheck(
              title: 'notifications',
              detail: "a notification when loaf chat isn't in front.",
              value: controller.notifications,
              onChanged: (on) {
                controller.setNotifications(on);
                if (on) unawaited(desktop.prepare().then((_) => _check()));
              },
            ),
            if (_blocked)
              _BlockedLine(os: _os, onOpen: desktop.openSystemSettings),
          ],
          SettingsCheck(
            title: 'sound',
            detail: desktop != null
                ? 'a soft chime for messages in other channels, and on '
                      'notifications.'
                : 'a soft chime for messages in other channels.',
            value: controller.sound,
            onChanged: (on) {
              controller.setSound(on);
              // Turning it on plays it, so you know what you turned on.
              if (on) unawaited(controller.chime.play());
            },
          ),
          if (desktop != null)
            SettingsCheck(
              title: 'show message text',
              detail: 'off, a notification says only who wrote.',
              value: controller.showText,
              enabled: controller.notifications,
              onChanged: controller.setShowText,
            ),
        ],
      ),
    );
  }
}

class _BlockedLine extends StatelessWidget {
  const _BlockedLine({required this.os, required this.onOpen});

  final String os;
  final Future<void> Function() onOpen;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Padding(
      // Lines up with a SettingsCheck's title: the checkbox's 48 and the gap.
      padding: const EdgeInsets.only(
        left: LoafSpace.x12 + LoafSpace.x2,
        bottom: LoafSpace.x3,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$os is blocking notifications from loaf chat.',
            style: loafBody(13, 400).copyWith(color: tokens.textMuted),
          ),
          const SizedBox(height: LoafSpace.x2),
          LoafButton(
            label: 'open system settings',
            icon: LucideIcons.externalLink,
            emphasis: LoafButtonEmphasis.outlined,
            size: LoafButtonSize.small,
            onTap: () => unawaited(onOpen()),
          ),
        ],
      ),
    );
  }
}
