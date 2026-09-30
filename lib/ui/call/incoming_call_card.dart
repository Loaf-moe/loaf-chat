/// A DM call ringing at you, drawn by us. Desktop shows it in a corner over
/// whatever you are doing; Android pins it to the top. iOS never shows it:
/// a rung iPhone gets CallKit's own screen.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/loaf_theme.dart';
import '../widgets/loaf_avatar.dart';
import '../widgets/loaf_button.dart';
import 'call_controller.dart';
import 'call_tile.dart';

class IncomingCallCard extends StatelessWidget {
  const IncomingCallCard({
    super.key = const ValueKey('incoming-call'),
    required this.ring,
    required this.onAccept,
    required this.onDecline,
    required this.onOpen,
  });

  final IncomingRing ring;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  /// Clicking the card's body opens the DM without answering.
  final VoidCallback onOpen;

  static const width = 340.0;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final caller = ring.caller;
    final group = ring.chat.members.length > 1;
    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onTap: onOpen,
        child: Container(
          padding: const EdgeInsets.all(LoafSpace.x4),
          decoration: BoxDecoration(
            color: tokens.card,
            borderRadius: BorderRadius.circular(LoafRadius.xl),
            border: Border.all(color: tokens.border),
            boxShadow: tokens.shadowLg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Pulse(
                    child: LoafAvatar(
                      label: caller.initials,
                      color: caller.color,
                      size: 44,
                      border: Border.all(color: tokens.online, width: 2),
                      image: caller.avatar,
                      textStyle: loafBody(15, 600),
                    ),
                  ),
                  const SizedBox(width: LoafSpace.x3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          group
                              ? '${caller.name} is calling · ${ring.chat.name}'
                              : '${caller.name} is calling',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: loafBody(
                            15,
                            600,
                          ).copyWith(color: tokens.textStrong),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Icon(
                              LucideIcons.phoneIncoming,
                              size: 13,
                              color: tokens.online,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              group ? 'group call' : 'voice call',
                              style: loafBody(
                                13,
                                400,
                              ).copyWith(color: tokens.textMuted),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: LoafSpace.x3),
              Row(
                children: [
                  Expanded(
                    child: LoafButton(
                      label: 'decline',
                      icon: LucideIcons.phoneOff,
                      size: LoafButtonSize.small,
                      emphasis: LoafButtonEmphasis.outlined,
                      onTap: onDecline,
                    ),
                  ),
                  const SizedBox(width: LoafSpace.x2),
                  Expanded(child: _AcceptButton(onTap: onAccept)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Accepting is green, not the accent: red here would read as hang up.
class _AcceptButton extends StatelessWidget {
  const _AcceptButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: tokens.online,
          borderRadius: BorderRadius.circular(LoafRadius.full),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(LucideIcons.phone, size: 16, color: Colors.white),
            const SizedBox(width: LoafSpace.x2),
            Text(
              'accept',
              style: loafBody(13, 600).copyWith(color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}
