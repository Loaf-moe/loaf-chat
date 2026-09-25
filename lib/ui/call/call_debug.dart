/// Mock-only levers for states the fake network would never reach on its
/// own: an incoming ring, a dropped connection, a denied permission.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../platform.dart';
import '../widgets/action_menu.dart';

enum CallDebug {
  ringFromMika('call from Mika', LucideIcons.phoneIncoming),
  ringFromCrew('call from weekend crew', LucideIcons.users),
  reconnecting('toggle reconnecting', LucideIcons.wifiOff),
  failNext('fail the next connection', LucideIcons.circleX),
  encryption('toggle encryption', LucideIcons.lock),
  micBlocked('block the microphone', LucideIcons.micOff),
  cameraBlocked('block the camera', LucideIcons.videoOff),
  remoteShare('someone shares their screen', LucideIcons.screenShare);

  const CallDebug(this.label, this.icon);

  final String label;
  final IconData icon;
}

Future<CallDebug?> showCallDebug(BuildContext context, Rect anchor) {
  final items = [
    for (final d in CallDebug.values)
      ActionItem(value: d, icon: d.icon, label: d.label),
  ];
  if (isDesktop) {
    return showActionMenu(context, position: anchor.topLeft, items: items);
  }
  return showActionSheet(context, items: items);
}
