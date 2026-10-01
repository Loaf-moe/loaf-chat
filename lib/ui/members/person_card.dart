/// Someone in the member list, opened: who they are, whether you have
/// checked that they are who they say, and the way to check. A sheet on a
/// phone, a dialog on a computer.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../model/models.dart';
import '../theme/loaf_theme.dart';
import '../verify/verifier.dart';
import '../widgets/adaptive_panel.dart';
import '../widgets/loaf_avatar.dart';
import '../widgets/loaf_button.dart';

/// Completes with true when verify was chosen; the caller runs it, once the
/// card has gone.
Future<bool?> showPersonCard(
  BuildContext context, {
  required Member member,
  required PersonTrust trust,
  required bool isYou,
  required bool canVerify,
}) => showAdaptivePanel<bool>(
  context,
  maxWidth: 360,
  child: PersonCard(
    member: member,
    trust: trust,
    isYou: isYou,
    canVerify: canVerify,
  ),
);

class PersonCard extends StatelessWidget {
  const PersonCard({
    super.key,
    required this.member,
    required this.trust,
    required this.isYou,
    required this.canVerify,
  });

  final Member member;
  final PersonTrust trust;

  /// Your own row: there is nobody to verify, and your session's own trust
  /// lives in the rail's notice.
  final bool isYou;

  /// Whether this session can vouch for anyone: it must be verified itself.
  final bool canVerify;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final status = member.statusMessage;
    return Padding(
      padding: const EdgeInsets.all(LoafSpace.x5),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: LoafAvatar(
              label: member.initials,
              color: member.color,
              size: 64,
              image: member.avatar,
              textStyle: loafBody(22, 600),
            ),
          ),
          const SizedBox(height: LoafSpace.x3),
          Text(
            member.name,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: loafBody(17, 600).copyWith(color: tokens.textStrong),
          ),
          const SizedBox(height: LoafSpace.x1),
          SelectableText(
            member.id,
            textAlign: TextAlign.center,
            style: loafMono(12).copyWith(color: tokens.textMuted),
          ),
          if (status != null) ...[
            const SizedBox(height: LoafSpace.x2),
            Text(
              status,
              textAlign: TextAlign.center,
              style: loafBody(14, 400).copyWith(color: tokens.textBody),
            ),
          ],
          if (!isYou) ...[
            const SizedBox(height: LoafSpace.x5),
            _TrustLine(trust: trust, tokens: tokens),
            if (trust == PersonTrust.unverified) ...[
              const SizedBox(height: LoafSpace.x4),
              LoafButton(
                label: 'verify',
                icon: LucideIcons.shieldCheck,
                onTap: canVerify ? () => Navigator.of(context).pop(true) : null,
              ),
              if (!canVerify) ...[
                const SizedBox(height: LoafSpace.x2),
                Text(
                  'verify this session first, so it can vouch for them.',
                  textAlign: TextAlign.center,
                  style: loafBody(13, 400).copyWith(color: tokens.textMuted),
                ),
              ],
            ],
          ],
        ],
      ),
    );
  }
}

class _TrustLine extends StatelessWidget {
  const _TrustLine({required this.trust, required this.tokens});

  final PersonTrust trust;
  final LoafTokens tokens;

  @override
  Widget build(BuildContext context) {
    final (icon, color, lead, note) = switch (trust) {
      // Green, not the accent: the accent red reads as a warning.
      PersonTrust.verified => (
        LucideIcons.shieldCheck,
        tokens.online,
        'verified',
        'you checked their emoji, so their messages are really theirs.',
      ),
      PersonTrust.unverified => (
        LucideIcons.shield,
        tokens.textMuted,
        'not verified',
        'compare emoji with them, in person or on a call you trust.',
      ),
      PersonTrust.noIdentity => (
        LucideIcons.shieldOff,
        tokens.textMuted,
        'nothing to verify yet',
        "they haven't set up encryption, or you share no encrypted room.",
      ),
    };
    return Container(
      key: ValueKey('trust-${trust.name}'),
      padding: const EdgeInsets.all(LoafSpace.x3),
      decoration: BoxDecoration(
        color: tokens.sunken,
        borderRadius: BorderRadius.circular(LoafRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: LoafSpace.x2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  lead,
                  style: loafBody(14, 600).copyWith(color: tokens.textStrong),
                ),
                const SizedBox(height: 2),
                Text(
                  note,
                  style: loafBody(13, 400).copyWith(color: tokens.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
