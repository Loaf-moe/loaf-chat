/// What an invite looks like before you accept it: who asked, and the little
/// the invite carries. Nothing from inside the room is shown — you have not
/// joined, and accepting is what shares your presence and read receipts
/// with it.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../call/call_view.dart';
import '../mock/fixtures.dart';
import '../shell/channel_list.dart';
import '../theme/loaf_theme.dart';
import '../widgets/loaf_avatar.dart';
import '../widgets/loaf_button.dart';
import '../window/window_chrome.dart';

/// An answer on its way to the server.
enum Answering { accepting, declining }

class InvitePreview extends StatelessWidget {
  const InvitePreview({
    super.key,
    required this.invite,
    required this.onAccept,
    required this.onDecline,
    this.answering,
    this.onOpenNavigation,
  });

  final Invite invite;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  /// Set while an answer is on its way. Neither button answers then — the
  /// server may already have it, so there is nothing to take back — and
  /// the one pressed spins.
  final Answering? answering;

  /// The phone layout's way back to the list.
  final VoidCallback? onOpenNavigation;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final count = invite.memberCount;

    return ColoredBox(
      color: tokens.page,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            WindowDragArea(
              child: Container(
                height: 56,
                padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x3),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: tokens.border)),
                ),
                child: Row(
                  children: [
                    const WindowControls(WindowEdge.leading),
                    if (onOpenNavigation != null)
                      TopBarButton(
                        icon: LucideIcons.menu,
                        tooltip: 'Channels',
                        onTap: onOpenNavigation,
                      ),
                    const SizedBox(width: LoafSpace.x1),
                    Icon(
                      LucideIcons.mailOpen,
                      size: 18,
                      color: tokens.textMuted,
                    ),
                    const SizedBox(width: LoafSpace.x2),
                    Text(
                      'invite',
                      style: loafBody(
                        15,
                        600,
                      ).copyWith(color: tokens.textStrong),
                    ),
                    const Spacer(),
                    const WindowControls(WindowEdge.trailing),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(LoafSpace.x6),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 360),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        invite.kind == InviteKind.direct
                            ? _PersonAvatar(member: invite.inviter)
                            : RoomAvatar(
                                name: invite.name,
                                id: invite.id,
                                size: 72,
                                color: invite.color,
                                image:
                                    invite.space?.avatar ?? invite.room?.avatar,
                              ),
                        const SizedBox(height: LoafSpace.x4),
                        Text(
                          invite.name,
                          textAlign: TextAlign.center,
                          style: loafDisplay(
                            22,
                            600,
                          ).copyWith(color: tokens.textStrong),
                        ),
                        const SizedBox(height: LoafSpace.x1),
                        Text(
                          invite.summary,
                          style: loafBody(
                            14,
                            500,
                          ).copyWith(color: tokens.textBody),
                        ),
                        if (invite.topic != null) ...[
                          const SizedBox(height: LoafSpace.x3),
                          Text(
                            invite.topic!,
                            textAlign: TextAlign.center,
                            style: loafBody(
                              14,
                              400,
                            ).copyWith(color: tokens.textMuted),
                          ),
                        ],
                        if (count != null) ...[
                          const SizedBox(height: LoafSpace.x2),
                          Text(
                            '$count members',
                            style: loafBody(
                              13,
                              500,
                            ).copyWith(color: tokens.textMuted),
                          ),
                        ],
                        const SizedBox(height: LoafSpace.x6),
                        Row(
                          children: [
                            Expanded(
                              child: LoafButton(
                                label: 'decline',
                                emphasis: LoafButtonEmphasis.outlined,
                                leading: answering == Answering.declining
                                    ? const _Spinner()
                                    : null,
                                onTap: answering == null ? onDecline : null,
                              ),
                            ),
                            const SizedBox(width: LoafSpace.x3),
                            Expanded(
                              child: LoafButton(
                                label: 'accept',
                                leading: answering == Answering.accepting
                                    ? const _Spinner()
                                    : null,
                                onTap: answering == null ? onAccept : null,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: LoafSpace.x3),
                        Text(
                          "you'll see what's inside once you join.",
                          style: loafBody(
                            12,
                            400,
                          ).copyWith(color: tokens.textMuted),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PersonAvatar extends StatelessWidget {
  const _PersonAvatar({required this.member});

  final Member member;

  @override
  Widget build(BuildContext context) => LoafAvatar(
    label: member.initials,
    color: member.color,
    size: 72,
    image: member.avatar,
    textStyle: loafBody(26, 600),
  );
}

/// Sized to sit where a button's icon goes.
class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
    width: 15,
    height: 15,
    child: CircularProgressIndicator.adaptive(strokeWidth: 2),
  );
}
