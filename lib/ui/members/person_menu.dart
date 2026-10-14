/// Someone's menu: their card, then what you can do about them here. A
/// menu at the pointer on a computer, a sheet on a phone.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../model/models.dart';
import '../verify/verifier.dart';
import '../widgets/action_menu.dart';
import '../widgets/toast.dart';
import 'person_card.dart';

enum _PersonAction { message, verify, copyId, editProfile, kick }

/// Each callback null leaves its item out; the caller knows who you are and
/// what the room allows. [position] null opens a sheet instead of a menu.
Future<void> showPersonMenu(
  BuildContext context, {
  required Member member,
  required bool isYou,
  PersonTrust? trust,
  bool canVerify = false,
  Offset? position,
  VoidCallback? onMessage,
  VoidCallback? onVerify,
  VoidCallback? onEditProfile,
  ({String from, VoidCallback run})? kick,
}) async {
  final items = [
    if (onMessage != null)
      const ActionItem(
        value: _PersonAction.message,
        icon: LucideIcons.messageCircle,
        label: 'message',
      ),
    if (onVerify != null && trust == PersonTrust.unverified && canVerify)
      const ActionItem(
        value: _PersonAction.verify,
        icon: LucideIcons.shieldCheck,
        label: 'verify',
      ),
    const ActionItem(
      value: _PersonAction.copyId,
      icon: LucideIcons.copy,
      label: 'copy user id',
    ),
    if (onEditProfile != null)
      const ActionItem(
        value: _PersonAction.editProfile,
        icon: LucideIcons.userPen,
        label: 'edit profile',
      ),
    if (kick != null)
      ActionItem(
        value: _PersonAction.kick,
        icon: LucideIcons.userX,
        label: 'kick from ${kick.from}',
        destructive: true,
      ),
  ];
  final _PersonAction? action;
  if (position != null) {
    action = await showActionMenu(
      context,
      position: position,
      leading: [
        PersonCardEntry(
          member: member,
          isYou: isYou,
          trust: trust,
          canVerify: canVerify,
        ),
      ],
      items: items,
    );
  } else {
    action = await showActionSheet(
      context,
      header: (_) => PersonCard(
        member: member,
        isYou: isYou,
        trust: trust,
        canVerify: canVerify,
      ),
      items: items,
    );
  }
  switch (action) {
    case _PersonAction.message:
      onMessage!();
    case _PersonAction.verify:
      onVerify!();
    case _PersonAction.copyId:
      await Clipboard.setData(ClipboardData(text: member.id));
      if (context.mounted) showToast(context, 'copied');
    case _PersonAction.editProfile:
      onEditProfile!();
    case _PersonAction.kick:
      kick!.run();
    case null:
  }
}
