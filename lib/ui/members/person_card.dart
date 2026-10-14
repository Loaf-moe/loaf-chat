/// Who someone is, on top of their menu: avatar, name, role, id, status,
/// and for someone else how far this device trusts them.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../model/models.dart';
import '../theme/loaf_theme.dart';
import '../verify/verifier.dart';
import '../widgets/loaf_avatar.dart';
import 'person_name.dart';
import 'presence_dot.dart';
import 'role_colors.dart';

class PersonCard extends StatelessWidget {
  const PersonCard({
    super.key,
    required this.member,
    required this.isYou,
    this.trust,
    this.canVerify = false,
    this.compact = false,
  });

  final Member member;

  /// Your own row: nobody to verify.
  final bool isYou;

  /// Null where nothing knows: a call's menu has no verifier.
  final PersonTrust? trust;

  /// Whether this session can vouch for anyone: it must be verified itself.
  final bool canVerify;

  /// Tighter padding, for a menu rather than a sheet.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final status = member.statusMessage;
    final trust = this.trust;
    final role = member.role;
    final inset = compact ? LoafSpace.x4 : LoafSpace.x5;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Hero(member: member, tokens: tokens, compact: compact),
        Padding(
          padding: EdgeInsets.fromLTRB(inset, LoafSpace.x3, inset, inset),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: PersonName(
                  member,
                  size: 20,
                  weight: 600,
                  serif: true,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (role != Role.member) ...[
                const SizedBox(height: LoafSpace.x1),
                Center(
                  child: _RoleChip(role: role, tokens: tokens),
                ),
              ],
              const SizedBox(height: LoafSpace.x2),
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
              if (!isYou && trust != null) ...[
                const SizedBox(height: LoafSpace.x3),
                _TrustLine(trust: trust, tokens: tokens),
                if (trust == PersonTrust.unverified && !canVerify) ...[
                  const SizedBox(height: 2),
                  Text(
                    'verify this session first, so it can vouch for them.',
                    textAlign: TextAlign.center,
                    style: loafBody(12, 400).copyWith(color: tokens.textMuted),
                  ),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// A band in their colour, the avatar overlapping its bottom edge.
class _Hero extends StatelessWidget {
  const _Hero({
    required this.member,
    required this.tokens,
    required this.compact,
  });

  final Member member;
  final LoafTokens tokens;
  final bool compact;

  static const _band = 88.0;
  static const _avatar = 128.0;
  static const _ring = 3.0;

  @override
  Widget build(BuildContext context) {
    final radius = Radius.circular(LoafRadius.lg);
    return SizedBox(
      height: _band + _avatar / 2 + _ring,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            key: const ValueKey('person-banner'),
            height: _band,
            decoration: BoxDecoration(
              color: member.color.withValues(alpha: 0.35),
              // Flush with the menu's own corners; its own card in a sheet.
              borderRadius: compact
                  ? BorderRadius.vertical(top: radius)
                  : BorderRadius.all(radius),
            ),
          ),
          Positioned(
            top: _band - _avatar / 2 - _ring,
            left: 0,
            right: 0,
            child: Center(
              child: SizedBox(
                width: _avatar + _ring * 2,
                height: _avatar + _ring * 2,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: tokens.card,
                      ),
                      padding: const EdgeInsets.all(_ring),
                      child: LoafAvatar(
                        label: member.initials,
                        color: member.color,
                        size: _avatar,
                        image: member.avatar,
                        textStyle: loafBody(40, 600),
                        original: true,
                      ),
                    ),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: PresenceDot(
                        presence: member.presence,
                        ring: tokens.card,
                        size: 20,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// [PersonCard] as the first row of a menu whose actions are [T].
class PersonCardEntry<T> extends PopupMenuEntry<T> {
  const PersonCardEntry({
    super.key,
    required this.member,
    required this.isYou,
    this.trust,
    this.canVerify = false,
  });

  final Member member;
  final bool isYou;
  final PersonTrust? trust;
  final bool canVerify;

  // Only places the menu's first item; the card lays itself out.
  @override
  double get height => 160;

  @override
  bool represents(T? value) => false;

  @override
  State<PersonCardEntry<T>> createState() => _PersonCardEntryState<T>();
}

class _PersonCardEntryState<T> extends State<PersonCardEntry<T>> {
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 280,
    child: PersonCard(
      member: widget.member,
      isYou: widget.isYou,
      trust: widget.trust,
      canVerify: widget.canVerify,
      compact: true,
    ),
  );
}

class _RoleChip extends StatelessWidget {
  const _RoleChip({required this.role, required this.tokens});

  final Role role;
  final LoafTokens tokens;

  @override
  Widget build(BuildContext context) => Container(
    key: ValueKey('role-${role.name}'),
    padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x3, vertical: 2),
    decoration: BoxDecoration(
      color: tokens.sunken,
      borderRadius: BorderRadius.circular(LoafRadius.full),
    ),
    child: Text(
      role.name,
      style: loafBody(
        11,
        600,
      ).copyWith(color: tokens.nameColor(role), letterSpacing: 0.04 * 11),
    ),
  );
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
    return Column(
      key: ValueKey('trust-${trust.name}'),
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: LoafSpace.x2),
            Flexible(
              child: Text(
                lead,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: loafBody(13, 600).copyWith(color: tokens.textStrong),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          note,
          textAlign: TextAlign.center,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: loafBody(12, 400).copyWith(color: tokens.textMuted),
        ),
      ],
    );
  }
}
