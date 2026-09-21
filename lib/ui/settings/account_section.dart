/// Account — what settings opens on, and where the profile lives.
///
/// Matrix profiles are global: one display name and one avatar, seen in every
/// room on every server. The copy says so, because people arriving from
/// Discord reasonably expect per-server identity. Per-space profiles exist as
/// a proposal and are deliberately not designed here yet.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../mock/fixtures.dart';
import '../theme/loaf_theme.dart';
import '../widgets/loaf_button.dart';

/// Matrix presence, in words people use. `busy` has no spec-level equivalent
/// yet; it rides on the status message.
enum Presence {
  online('online', Color(0xFF4E9E76)),
  away('away', Color(0xFFD97B2A)),
  busy('do not disturb', Color(0xFFD62828)),
  invisible('invisible', Color(0xFF8098A4));

  const Presence(this.label, this.dot);

  final String label;
  final Color dot;
}

class AccountSection extends StatefulWidget {
  const AccountSection({super.key});

  @override
  State<AccountSection> createState() => _AccountSectionState();
}

class _AccountSectionState extends State<AccountSection> {
  final _name = TextEditingController(text: currentUser.name);
  final _status = TextEditingController(text: 'feeding the starter');
  var _presence = Presence.online;

  @override
  void dispose() {
    _name.dispose();
    _status.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(LoafSpace.x6),
      child: Center(
        child: ConstrainedBox(
          // Forms read badly at full window width.
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // No page title: the nav says which section this is, and on a
              // phone so does the card header.
              _FieldLabel(tokens: tokens, label: 'avatar'),
              _AvatarRow(tokens: tokens),
              const SizedBox(height: LoafSpace.x6),

              _FieldLabel(tokens: tokens, label: 'display name'),
              _TextRow(tokens: tokens, controller: _name),
              const SizedBox(height: LoafSpace.x5),

              _FieldLabel(tokens: tokens, label: 'matrix id'),
              _ReadOnlyRow(tokens: tokens, value: '${currentUser.id}:loaf.moe'),
              const SizedBox(height: LoafSpace.x5),

              _FieldLabel(tokens: tokens, label: 'presence'),
              _PresenceChips(
                value: _presence,
                onChanged: (p) => setState(() => _presence = p),
              ),
              const SizedBox(height: LoafSpace.x5),

              _FieldLabel(tokens: tokens, label: 'status'),
              _TextRow(
                tokens: tokens,
                controller: _status,
                hint: 'what are you up to?',
              ),
              const SizedBox(height: LoafSpace.x6),

              // Left-aligned with the form rather than stretched: the fields
              // are the subject here, not the button.
              Align(
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LoafButton(
                      label: 'save changes',
                      size: LoafButtonSize.small,
                      onTap: () {},
                    ),
                    const SizedBox(width: LoafSpace.x2),
                    LoafButton(
                      label: 'discard',
                      emphasis: LoafButtonEmphasis.quiet,
                      size: LoafButtonSize.small,
                      onTap: () {},
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AvatarRow extends StatelessWidget {
  const _AvatarRow({required this.tokens});

  final LoafTokens tokens;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(
        width: 88,
        height: 88,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              decoration: BoxDecoration(
                color: currentUser.color,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text(
                currentUser.initials,
                style: loafBody(30, 600).copyWith(color: Colors.white),
              ),
            ),
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: tokens.card,
                  shape: BoxShape.circle,
                  border: Border.all(color: tokens.border),
                  boxShadow: tokens.shadowSm,
                ),
                child: Icon(
                  LucideIcons.camera,
                  size: 15,
                  color: tokens.textBody,
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(width: LoafSpace.x5),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              currentUser.name,
              style: loafDisplay(20, 600).copyWith(color: tokens.textStrong),
            ),
            const SizedBox(height: 2),
            Text(
              'png or jpg, at least 256px',
              style: loafBody(11, 400).copyWith(color: tokens.textMuted),
            ),
          ],
        ),
      ),
    ],
  );
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.tokens, required this.label});

  final LoafTokens tokens;
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: LoafSpace.x2),
    child: Text(
      label.toUpperCase(),
      style: loafBody(
        11,
        600,
      ).copyWith(color: tokens.textMuted, letterSpacing: 0.04 * 11),
    ),
  );
}

class _TextRow extends StatelessWidget {
  const _TextRow({required this.tokens, required this.controller, this.hint});

  final LoafTokens tokens;
  final TextEditingController controller;
  final String? hint;

  @override
  Widget build(BuildContext context) => Container(
    height: 46,
    padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x3),
    decoration: BoxDecoration(
      color: tokens.card,
      borderRadius: BorderRadius.circular(LoafRadius.lg),
      border: Border.all(color: tokens.border),
    ),
    child: Center(
      child: TextField(
        controller: controller,
        style: loafBody(15, 400, height: 1.4).copyWith(color: tokens.textBody),
        decoration: InputDecoration(
          // Collapsed so the Center does the vertical work; a decorator left
          // to its own padding pushes the text off the field's centreline.
          isCollapsed: true,
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
          hintText: hint,
          hintStyle: loafBody(
            15,
            400,
            height: 1.4,
          ).copyWith(color: tokens.textMuted),
        ),
      ),
    ),
  );
}

/// Your Matrix ID is not editable — it is who you are, not what you are
/// called — so it reads as a fact you can copy rather than a field.
class _ReadOnlyRow extends StatelessWidget {
  const _ReadOnlyRow({required this.tokens, required this.value});

  final LoafTokens tokens;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
    height: 46,
    padding: const EdgeInsets.only(left: LoafSpace.x3, right: LoafSpace.x1),
    decoration: BoxDecoration(
      color: tokens.sunken,
      borderRadius: BorderRadius.circular(LoafRadius.lg),
      border: Border.all(color: tokens.border),
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: loafMono(13).copyWith(color: tokens.textBody),
          ),
        ),
        IconButton(
          onPressed: () {},
          iconSize: 16,
          color: tokens.textMuted,
          tooltip: 'Copy',
          icon: const Icon(LucideIcons.copy),
        ),
      ],
    ),
  );
}

class _PresenceChips extends StatelessWidget {
  const _PresenceChips({required this.value, required this.onChanged});

  final Presence value;
  final ValueChanged<Presence> onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);

    return Wrap(
      spacing: LoafSpace.x2,
      runSpacing: LoafSpace.x2,
      children: [
        for (final presence in Presence.values)
          GestureDetector(
            onTap: () => onChanged(presence),
            behavior: HitTestBehavior.opaque,
            child: Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x3),
              decoration: BoxDecoration(
                color: presence == value ? tokens.card : Colors.transparent,
                borderRadius: BorderRadius.circular(LoafRadius.full),
                border: Border.all(
                  color: presence == value
                      ? tokens.accent
                      : tokens.borderStrong,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: presence.dot,
                      shape: BoxShape.circle,
                      // Invisible reads as a hollow dot, not a grey one.
                      border: presence == Presence.invisible
                          ? Border.all(color: presence.dot)
                          : null,
                    ),
                  ),
                  const SizedBox(width: LoafSpace.x2),
                  Text(
                    presence.label,
                    style: loafBody(13, presence == value ? 600 : 400).copyWith(
                      color: presence == value
                          ? tokens.textStrong
                          : tokens.textBody,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
