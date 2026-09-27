/// Account — what settings opens on, and where the profile lives.
///
/// Matrix profiles are global: one display name and one avatar, seen in every
/// room on every server. The copy says so, because people arriving from
/// Discord reasonably expect per-server identity. Per-space profiles exist as
/// a proposal and are deliberately not designed here yet.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../members/presence.dart';
import '../members/presence_dot.dart';
import '../mock/fixtures.dart';
import '../shell/profile_controller.dart';
import '../theme/loaf_theme.dart';
import '../widgets/loaf_button.dart';

class AccountSection extends StatefulWidget {
  const AccountSection({
    super.key,
    this.profile,
    this.me,
    this.editable = true,
  });

  /// Shared with the account panel's picker. Left null (in isolation, as in
  /// tests), the section keeps a profile of its own.
  final ProfileController? profile;

  /// Who is signed in. Left null, the mock's account.
  final Member? me;

  /// False while the backend cannot change a profile yet: everything reads
  /// as fact, with nothing to edit or save.
  final bool editable;

  @override
  State<AccountSection> createState() => _AccountSectionState();
}

class _AccountSectionState extends State<AccountSection> {
  Member get _me => widget.me ?? currentUser;

  /// The mock's ids are bare localparts; a real one is whole already.
  String get _matrixId => _me.id.contains(':') ? _me.id : '${_me.id}:loaf.moe';

  late final _name = TextEditingController(text: _me.name);
  late final _ownProfile = widget.profile == null ? ProfileController() : null;
  ProfileController get _profile => widget.profile ?? _ownProfile!;
  late final _status = TextEditingController(text: _profile.status);

  @override
  void initState() {
    super.initState();
    _profile.addListener(_onProfile);
  }

  void _onProfile() => setState(() {});

  @override
  void dispose() {
    _profile.removeListener(_onProfile);
    _ownProfile?.dispose();
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
              _AvatarRow(tokens: tokens, me: _me, editable: widget.editable),
              const SizedBox(height: LoafSpace.x6),

              _FieldLabel(tokens: tokens, label: 'display name'),
              if (widget.editable)
                _TextRow(tokens: tokens, controller: _name)
              else
                _ReadOnlyRow(tokens: tokens, value: _me.name, mono: false),
              const SizedBox(height: LoafSpace.x5),

              _FieldLabel(tokens: tokens, label: 'matrix id'),
              _ReadOnlyRow(tokens: tokens, value: _matrixId),
              if (widget.editable) ...[
                const SizedBox(height: LoafSpace.x5),

                _FieldLabel(tokens: tokens, label: 'presence'),
                // Applies at once, like the picker: presence is a switch, not
                // a form field.
                _PresenceChips(
                  value: _profile.choice,
                  onChanged: _profile.choose,
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
                        onTap: () => _profile.setStatus(_status.text),
                      ),
                      const SizedBox(width: LoafSpace.x2),
                      LoafButton(
                        label: 'discard',
                        emphasis: LoafButtonEmphasis.quiet,
                        size: LoafButtonSize.small,
                        onTap: () => _status.text = _profile.status,
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _AvatarRow extends StatelessWidget {
  const _AvatarRow({
    required this.tokens,
    required this.me,
    required this.editable,
  });

  final LoafTokens tokens;
  final Member me;

  /// Offers a new picture: the camera badge and its hint.
  final bool editable;

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
                color: me.color,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text(
                me.initials,
                style: loafBody(30, 600).copyWith(color: Colors.white),
              ),
            ),
            if (editable)
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
              me.name,
              style: loafDisplay(20, 600).copyWith(color: tokens.textStrong),
            ),
            if (editable) ...[
              const SizedBox(height: 2),
              Text(
                'png or jpg, at least 256px',
                style: loafBody(11, 400).copyWith(color: tokens.textMuted),
              ),
            ],
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
  const _ReadOnlyRow({
    required this.tokens,
    required this.value,
    this.mono = true,
  });

  final LoafTokens tokens;
  final String value;

  /// Ids are set in mono; names are not.
  final bool mono;

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
            style: (mono ? loafMono(13) : loafBody(15, 400)).copyWith(
              color: tokens.textBody,
            ),
          ),
        ),
        IconButton(
          onPressed: () => Clipboard.setData(ClipboardData(text: value)),
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

  final PresenceChoice value;
  final ValueChanged<PresenceChoice> onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);

    return Wrap(
      spacing: LoafSpace.x2,
      runSpacing: LoafSpace.x2,
      children: [
        for (final choice in PresenceChoice.values)
          GestureDetector(
            onTap: () => onChanged(choice),
            behavior: HitTestBehavior.opaque,
            child: Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x3),
              decoration: BoxDecoration(
                color: choice == value ? tokens.card : Colors.transparent,
                borderRadius: BorderRadius.circular(LoafRadius.full),
                border: Border.all(
                  color: choice == value ? tokens.accent : tokens.borderStrong,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PresenceDot(
                    presence: choice.shown,
                    ring: choice == value ? tokens.card : tokens.page,
                    size: 10,
                  ),
                  const SizedBox(width: LoafSpace.x2),
                  Text(
                    choice.label,
                    style: loafBody(13, choice == value ? 600 : 400).copyWith(
                      color: choice == value
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
