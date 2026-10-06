/// Mock-only levers for states the fake data never reaches on its own: an
/// incoming ring, a dropped connection, a denied permission, a server that
/// shares no presence, a session signed out or expired.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../model/updater.dart';
import '../platform.dart';
import '../widgets/action_menu.dart';

enum MockDebug {
  ringFromMika,
  ringFromCrew,
  reconnecting,
  failNext,
  encryption,
  micBlocked,
  cameraBlocked,
  remoteShare,
  presence,
  signOut,
  expireSession,
  freshAccount,
  newSignIn,
  personAsks,
  forgetUpdate,
  nextUpdateCheck,
}

/// [presenceShared] words the presence lever for the state it would change;
/// [nextCheck] says what the next update check will find.
Future<MockDebug?> showMockDebug(
  BuildContext context,
  Rect anchor, {
  required bool presenceShared,
  required UpdateCheck nextCheck,
}) {
  ActionItem<MockDebug> item(MockDebug d, IconData icon, String label) =>
      ActionItem(value: d, icon: icon, label: label);
  final items = [
    item(MockDebug.ringFromMika, LucideIcons.phoneIncoming, 'call from Mika'),
    item(MockDebug.ringFromCrew, LucideIcons.users, 'call from weekend crew'),
    item(MockDebug.reconnecting, LucideIcons.wifiOff, 'toggle reconnecting'),
    item(MockDebug.failNext, LucideIcons.circleX, 'fail the next connection'),
    item(MockDebug.encryption, LucideIcons.lock, 'toggle encryption'),
    item(MockDebug.micBlocked, LucideIcons.micOff, 'block the microphone'),
    item(MockDebug.cameraBlocked, LucideIcons.videoOff, 'block the camera'),
    item(
      MockDebug.remoteShare,
      LucideIcons.screenShare,
      'someone shares their screen',
    ),
    item(
      MockDebug.presence,
      LucideIcons.circleDashed,
      presenceShared
          ? 'turn presence off on this server'
          : 'turn presence back on',
    ),
    item(MockDebug.signOut, LucideIcons.logOut, 'sign out'),
    item(MockDebug.expireSession, LucideIcons.timerOff, 'expire the session'),
    item(
      MockDebug.freshAccount,
      LucideIcons.userPlus,
      'become a fresh account',
    ),
    item(
      MockDebug.newSignIn,
      LucideIcons.monitorSmartphone,
      'a new sign-in asks to verify',
    ),
    item(
      MockDebug.personAsks,
      LucideIcons.userCheck,
      'Mika asks to verify you',
    ),
    item(MockDebug.forgetUpdate, LucideIcons.archiveX, 'forget the update'),
    item(MockDebug.nextUpdateCheck, LucideIcons.refreshCw, switch (nextCheck) {
      UpdateCheck.upToDate => 'next update check: up to date',
      UpdateCheck.ready => 'next update check: finds 0.3.0',
      UpdateCheck.failed => 'next update check: fails',
    }),
  ];
  if (isDesktop) {
    return showActionMenu(context, position: anchor.topLeft, items: items);
  }
  return showActionSheet(context, items: items);
}
