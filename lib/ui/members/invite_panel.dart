/// Adding people to a room or space you're already in: check off who you
/// know, or type a full id for someone new to loaf. A sheet on a phone, a
/// dialog on a computer, like every adaptive panel.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../mock/fixtures.dart';
import '../rooms/rooms.dart';
import '../theme/loaf_theme.dart';
import '../widgets/adaptive_panel.dart';
import '../widgets/loaf_avatar.dart';
import '../widgets/loaf_button.dart';

/// A full Matrix id, such as `@someone:matrix.org`.
final _mxid = RegExp(r'^@[^:\s]+:[^\s]+$');

Future<void> showInvitePanel(
  BuildContext context, {
  required String roomName,
  required List<Member> people,
  required Future<void> Function(List<String> ids) onInvite,
}) => showAdaptivePanel(
  context,
  // The sheet's drag-to-close pops straight past the panel's PopScope, and
  // an invite in flight must not be put away.
  enableDrag: false,
  child: InvitePanel(roomName: roomName, people: people, onInvite: onInvite),
);

class InvitePanel extends StatefulWidget {
  const InvitePanel({
    super.key,
    required this.roomName,
    required this.people,
    required this.onInvite,
  });

  final String roomName;

  /// Everyone you could invite: people you share a space or a DM with, and
  /// who are not already here.
  final List<Member> people;

  /// Sends the invite. Throws [InviteRefused] naming who did not go
  /// through, which this panel handles itself; any other error is treated
  /// as a lost connection.
  final Future<void> Function(List<String> ids) onInvite;

  @override
  State<InvitePanel> createState() => _InvitePanelState();
}

class _InvitePanelState extends State<InvitePanel> {
  final _search = TextEditingController();
  final _idField = TextEditingController();

  /// Checked people from [InvitePanel.people], by id.
  final _checked = <String>{};

  /// Ids added by typing a full `@name:server`.
  final _chips = <String>[];

  var _sending = false;

  /// Who the server turned down last time, and why, in its own words.
  /// Anyone here is offered "try again", resending only them.
  var _failed = <String, String>{};

  /// Set only for an error that is not [InviteRefused] — a dropped
  /// connection, say.
  String? _error;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    _idField.addListener(() {
      if (_idNote != null) setState(() => _idNote = null);
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _idField.dispose();
    super.dispose();
  }

  List<String> get _selectedIds => [..._checked, ..._chips];

  List<Member> get _matches {
    final q = _search.text.trim().toLowerCase();
    return [
      for (final m in widget.people)
        if (q.isEmpty ||
            m.name.toLowerCase().contains(q) ||
            m.id.toLowerCase().contains(q))
          m,
    ]..sort((a, b) => a.name.compareTo(b.name));
  }

  void _toggle(Member m) => setState(() {
    if (!_checked.remove(m.id)) _checked.add(m.id);
  });

  /// Why the typed id made no chip, until the text changes.
  String? _idNote;

  void _addChip() {
    final typed = _idField.text.trim();
    if (typed.isEmpty) return;
    // The field already shows an "@", so typing one is optional.
    final id = typed.startsWith('@') ? typed : '@$typed';
    if (!_mxid.hasMatch(id)) {
      setState(() => _idNote = "that's not an id like @name:server");
      return;
    }
    if (_chips.contains(id) || _checked.contains(id)) return;
    setState(() {
      _chips.add(id);
      _idField.clear();
      _failed.remove(id);
    });
  }

  Future<void> _send() async {
    final retrying = _failed.isNotEmpty;
    final ids = retrying ? _failed.keys.toList() : _selectedIds;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.onInvite(ids);
      if (mounted) Navigator.pop(context);
    } on InviteRefused catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _failed = e.failed;
        // Whoever went through is done: they leave the picked list, so a
        // retry sends only who is left.
        for (final id in ids) {
          if (!_failed.containsKey(id)) {
            _checked.remove(id);
            _chips.remove(id);
          }
        }
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = "couldn't reach the server. try again?";
      });
    }
  }

  String get _label {
    if (_sending) return 'inviting…';
    if (_failed.isNotEmpty) return 'try again';
    return 'invite';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final matches = _matches;
    final knownIds = {for (final m in widget.people) m.id};

    InputDecoration field({required String hint, required IconData icon}) =>
        InputDecoration(
          isDense: true,
          prefixIcon: Icon(icon, size: 18, color: tokens.textMuted),
          hintText: hint,
          hintStyle: loafBody(15, 400).copyWith(color: tokens.textMuted),
          filled: true,
          fillColor: tokens.sunken,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(LoafRadius.md),
            borderSide: BorderSide(color: tokens.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(LoafRadius.md),
            borderSide: BorderSide(color: tokens.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(LoafRadius.md),
            borderSide: BorderSide(color: tokens.borderStrong, width: 1.5),
          ),
        );

    return PopScope(
      // Dismissing mid-send would lose who was refused: no cancel while busy.
      canPop: !_sending,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          LoafSpace.x4,
          LoafSpace.x2,
          LoafSpace.x4,
          LoafSpace.x4,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'invite to ${widget.roomName}',
              style: loafDisplay(20, 600).copyWith(color: tokens.textStrong),
            ),
            const SizedBox(height: LoafSpace.x3),
            TextField(
              controller: _search,
              style: loafBody(15, 400).copyWith(color: tokens.textStrong),
              decoration: field(
                hint: 'search people',
                icon: LucideIcons.search,
              ),
            ),
            const SizedBox(height: LoafSpace.x2),
            TextField(
              controller: _idField,
              style: loafBody(15, 400).copyWith(color: tokens.textStrong),
              onSubmitted: (_) => _addChip(),
              decoration: field(hint: '@name:server', icon: LucideIcons.atSign),
            ),
            if (_idNote != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _idNote!,
                  style: loafBody(12, 500).copyWith(color: tokens.accent),
                ),
              ),
            if (_chips.isNotEmpty) ...[
              const SizedBox(height: LoafSpace.x2),
              Wrap(
                spacing: LoafSpace.x2,
                runSpacing: LoafSpace.x2,
                children: [
                  for (final id in _chips)
                    InputChip(
                      label: Text(id),
                      labelStyle: loafBody(
                        13,
                        500,
                      ).copyWith(color: tokens.textStrong),
                      backgroundColor: tokens.sunken,
                      side: BorderSide(
                        color: _failed.containsKey(id)
                            ? tokens.accent
                            : tokens.border,
                      ),
                      onDeleted: () => setState(() {
                        _chips.remove(id);
                        _failed.remove(id);
                      }),
                      deleteButtonTooltipMessage: 'Remove',
                    ),
                ],
              ),
            ],
            // A failed chip's own text; a failed known person is marked on
            // their row instead, so it is not said twice.
            for (final id in _failed.keys)
              if (!knownIds.contains(id))
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    "$id didn't go through",
                    style: loafBody(12, 500).copyWith(color: tokens.accent),
                  ),
                ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: LoafSpace.x2),
                child: Text(
                  _error!,
                  style: loafBody(13, 500).copyWith(color: tokens.accent),
                ),
              ),
            const SizedBox(height: LoafSpace.x2),
            Expanded(
              child: ListView(
                children: [
                  for (final m in matches)
                    _PersonRow(
                      key: ValueKey('invite-${m.id}'),
                      person: m,
                      checked: _checked.contains(m.id),
                      failed: _failed.containsKey(m.id),
                      onToggle: () => _toggle(m),
                    ),
                ],
              ),
            ),
            const SizedBox(height: LoafSpace.x3),
            LoafButton(
              label: _label,
              leading: _sending
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                    )
                  : null,
              onTap: _sending || _selectedIds.isEmpty ? null : _send,
            ),
          ],
        ),
      ),
    );
  }
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({
    super.key,
    required this.person,
    required this.checked,
    required this.failed,
    required this.onToggle,
  });

  final Member person;
  final bool checked;
  final bool failed;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(LoafRadius.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LoafSpace.x2,
          vertical: 6,
        ),
        child: Row(
          children: [
            LoafAvatar(
              label: person.initials.characters.first,
              color: person.color,
              size: 32,
              image: person.avatar,
              textStyle: loafBody(13, 600),
            ),
            const SizedBox(width: LoafSpace.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    person.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: loafBody(15, 600).copyWith(color: tokens.textStrong),
                  ),
                  Text(
                    failed ? "didn't go through" : person.id,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: loafBody(12, 400).copyWith(
                      color: failed ? tokens.accent : tokens.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              checked ? LucideIcons.circleCheck : LucideIcons.circle,
              size: 20,
              color: checked ? tokens.accent : tokens.borderStrong,
            ),
          ],
        ),
      ),
    );
  }
}
