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
import '../platform.dart';
import '../shell/profile.dart';
import '../shell/profile_controller.dart';
import '../theme/loaf_theme.dart';
import '../widgets/action_menu.dart';
import '../widgets/loaf_avatar.dart';
import '../widgets/loaf_button.dart';
import '../widgets/toast.dart';
import 'avatar_picker.dart';

class AccountSection extends StatefulWidget {
  const AccountSection({
    super.key,
    this.profile,
    this.me,
    this.editable = true,
    this.pickPicture = pickAvatarBytes,
  });

  /// Shared with the account panel's picker. Left null (in isolation, as in
  /// tests), the section keeps a profile of its own.
  final ProfileController? profile;

  /// Who is signed in. Left null, the mock's account.
  final Member? me;

  /// False while the backend cannot change a profile yet: everything reads
  /// as fact, with nothing to edit or save.
  final bool editable;

  /// Where a picture comes from: the platform's picker. Swapped in tests.
  final Future<Uint8List?> Function() pickPicture;

  @override
  State<AccountSection> createState() => _AccountSectionState();
}

class _AccountSectionState extends State<AccountSection> {
  Member get _me => widget.me ?? currentUser;

  /// The mock's ids are bare localparts; a real one is whole already.
  String get _matrixId => _me.id.contains(':') ? _me.id : '${_me.id}:loaf.moe';

  late final _ownProfile = widget.profile == null ? ProfileController() : null;
  ProfileController get _profile => widget.profile ?? _ownProfile!;
  late final _name = TextEditingController(text: _profile.displayName);
  late final _status = TextEditingController(text: _profile.status);

  /// What the profile last had, so a field nobody has typed in follows a
  /// change from elsewhere (the name arriving from the server) while one
  /// being edited is left alone.
  late var _seenName = _profile.displayName;
  late var _seenStatus = _profile.status;

  /// A picture is being chosen, read, shrunk or uploaded. The profile only
  /// knows about the upload, so without this the badge is live while the
  /// file is still being read.
  var _changing = false;

  @override
  void initState() {
    super.initState();
    _profile.addListener(_onProfile);
    // Save is only honest while there is a name to save.
    _name.addListener(_onName);
  }

  late var _hadName = _name.text.trim().isNotEmpty;

  void _onName() {
    final has = _name.text.trim().isNotEmpty;
    if (has == _hadName) return;
    _hadName = has;
    setState(() {});
  }

  void _onProfile() {
    // Mid-save the profile moves ahead of the fields, and back again when a
    // write is refused. Neither is news to the fields: their text stays.
    if (!_profile.savingAccount) {
      if (_name.text == _seenName) _name.text = _profile.displayName;
      if (_status.text == _seenStatus) _status.text = _profile.status;
      _seenName = _profile.displayName;
      _seenStatus = _profile.status;
    }
    setState(() {});
  }

  Future<void> _save() async {
    try {
      await _profile.saveAccount(displayName: _name.text, status: _status.text);
    } on AccountSaveFailed catch (e) {
      if (!mounted) return;
      showToast(context, switch ((e.name, e.status)) {
        (true, true) => "couldn't save your changes. try again?",
        (true, false) => "couldn't save your name. try again?",
        _ => "couldn't save your status. try again?",
      });
    }
  }

  void _discard() {
    _name.text = _profile.displayName;
    _status.text = _profile.status;
  }

  /// Choosing runs the platform picker, shrinks the result and uploads it;
  /// removing uploads nothing. Either failing is one toast, and the badge is
  /// live again.
  Future<void> _changePicture(Offset at) async {
    final items = [
      const ActionItem(
        value: _PictureAction.choose,
        icon: LucideIcons.image,
        label: 'choose a picture…',
      ),
      if (_profile.avatar != null)
        const ActionItem(
          value: _PictureAction.remove,
          icon: LucideIcons.trash2,
          label: 'remove picture',
          destructive: true,
        ),
    ];
    final action = isDesktop
        ? await showActionMenu<_PictureAction>(
            context,
            position: at,
            items: items,
          )
        : await showActionSheet<_PictureAction>(context, items: items);
    if (action == null || !mounted) return;
    setState(() => _changing = true);
    try {
      switch (action) {
        case _PictureAction.choose:
          final bytes = await widget.pickPicture();
          if (bytes == null) return;
          await _profile.setAvatar(await shrinkToPng(bytes));
        case _PictureAction.remove:
          await _profile.setAvatar(null);
      }
    } catch (_) {
      if (mounted) {
        showToast(context, "couldn't change your picture. try again?");
      }
    } finally {
      if (mounted) setState(() => _changing = false);
    }
  }

  @override
  void dispose() {
    _profile.removeListener(_onProfile);
    _name.removeListener(_onName);
    _ownProfile?.dispose();
    _name.dispose();
    _status.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final saving = _profile.savingAccount;
    // Editing shows what the profile has; a read-only backend, what it was
    // given.
    final me = widget.editable ? _profile.me : _me;

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
              _AvatarRow(
                tokens: tokens,
                me: me,
                editable: widget.editable,
                uploading: _profile.uploadingAvatar || _changing,
                onChange: _changePicture,
              ),
              const SizedBox(height: LoafSpace.x6),

              _FieldLabel(tokens: tokens, label: 'display name'),
              if (widget.editable)
                _TextRow(tokens: tokens, controller: _name, readOnly: saving)
              else
                _ReadOnlyRow(tokens: tokens, value: _me.name, mono: false),
              const SizedBox(height: LoafSpace.x5),

              _FieldLabel(tokens: tokens, label: 'matrix id'),
              // A computer keeps text selection; an id is what gets copied.
              _ReadOnlyRow(
                tokens: tokens,
                value: _matrixId,
                selectable: isDesktop,
              ),
              if (widget.editable) ...[
                const SizedBox(height: LoafSpace.x5),

                _FieldLabel(tokens: tokens, label: 'presence'),
                // Applies at once, like the picker: presence is a switch, not
                // a form field.
                if (_profile.presenceShared)
                  _PresenceChips(
                    value: _profile.choice,
                    onChanged: _profile.choose,
                  )
                else
                  // Nothing to choose: this server neither sends nor takes
                  // presence. Same words as the status picker.
                  Text(
                    "this server doesn't share presence",
                    style: loafBody(13, 400).copyWith(color: tokens.textMuted),
                  ),
                const SizedBox(height: LoafSpace.x5),

                _FieldLabel(tokens: tokens, label: 'status'),
                _TextRow(
                  tokens: tokens,
                  controller: _status,
                  hint: 'what are you up to?',
                  readOnly: saving,
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
                        label: saving ? 'saving…' : 'save changes',
                        size: LoafButtonSize.small,
                        // A save can't be called back, so no cancel: the
                        // button just waits, drawn as unavailable. It also
                        // waits for a name: a blank one saves to nothing.
                        onTap: saving || _name.text.trim().isEmpty
                            ? null
                            : _save,
                      ),
                      const SizedBox(width: LoafSpace.x2),
                      LoafButton(
                        label: 'discard',
                        emphasis: LoafButtonEmphasis.quiet,
                        size: LoafButtonSize.small,
                        onTap: saving ? null : _discard,
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

enum _PictureAction { choose, remove }

class _AvatarRow extends StatelessWidget {
  const _AvatarRow({
    required this.tokens,
    required this.me,
    required this.editable,
    required this.uploading,
    required this.onChange,
  });

  final LoafTokens tokens;
  final Member me;

  /// Offers a new picture: the camera badge and its hint.
  final bool editable;

  /// A picture is on its way up. There is no stopping it, so the badge
  /// waits instead.
  final bool uploading;

  /// Opens the choices at a point (where a menu goes on a computer).
  final void Function(Offset at) onChange;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      GestureDetector(
        key: const Key('change-picture'),
        behavior: HitTestBehavior.opaque,
        onTapUp: editable && !uploading
            ? (d) => onChange(d.globalPosition)
            : null,
        // Right-click is the computer's way in; a phone has no such thing.
        onSecondaryTapUp: editable && !uploading && isDesktop
            ? (d) => onChange(d.globalPosition)
            : null,
        child: SizedBox(
          width: 88,
          height: 88,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              LoafAvatar(
                label: me.initials,
                color: me.color,
                size: 88,
                image: me.avatar,
                textStyle: loafBody(30, 600),
              ),
              if (uploading)
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: tokens.card.withValues(alpha: 0.6),
                    ),
                    child: const Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator.adaptive(
                          strokeWidth: 2.5,
                        ),
                      ),
                    ),
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
  const _TextRow({
    required this.tokens,
    required this.controller,
    this.hint,
    this.readOnly = false,
  });

  final LoafTokens tokens;
  final TextEditingController controller;
  final String? hint;

  /// Held still while a save is on its way.
  final bool readOnly;

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
        readOnly: readOnly,
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
    this.selectable = false,
  });

  final LoafTokens tokens;
  final String value;

  /// Drawn as selectable text, the desktop idiom.
  final bool selectable;

  /// Ids are set in mono; names are not.
  final bool mono;

  TextStyle get _style => (mono ? loafMono(13) : loafBody(15, 400)).copyWith(
    color: tokens.textBody,
  );

  Widget _plain() =>
      Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: _style);

  Widget _selectable() => SelectableText(value, maxLines: 1, style: _style);

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
        Expanded(child: selectable ? _selectable() : _plain()),
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
