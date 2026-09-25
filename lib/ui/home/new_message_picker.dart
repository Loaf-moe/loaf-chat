/// Starting a conversation: pick one person or several, and reuse whatever
/// already exists with them rather than making another room. A sheet on a
/// phone, a dialog on a computer.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../members/presence_dot.dart';
import '../mock/fixtures.dart';
import '../platform.dart';
import '../theme/loaf_theme.dart';
import '../widgets/loaf_button.dart';
import 'direct_messages.dart';

/// Returns what to do — open an existing room or create one — or null if
/// the picker was dismissed.
Future<StartMessage?> showNewMessagePicker(
  BuildContext context, {
  required List<Member> people,
  required List<Channel> rooms,
}) {
  final tokens = LoafTokens.of(context);
  final picker = NewMessagePicker(people: people, rooms: rooms);
  if (isDesktop) {
    return showDialog<StartMessage>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: tokens.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LoafRadius.xl),
          side: BorderSide(color: tokens.border),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440, maxHeight: 580),
          child: picker,
        ),
      ),
    );
  }
  // Read outside the sheet: a bottom sheet strips the top inset from its
  // own MediaQuery.
  final statusBar = MediaQuery.paddingOf(context).top;
  return showModalBottomSheet<StartMessage>(
    context: context,
    backgroundColor: tokens.card,
    showDragHandle: true,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(LoafRadius.xxxl),
      ),
    ),
    // Rides up with the keyboard, and never taller than the room it
    // leaves: past that the drag handle slides under the status bar.
    builder: (context) {
      final media = MediaQuery.of(context);
      // The drag handle sits above the picker and takes its own height.
      const handle = LoafSpace.x12;
      final room =
          media.size.height -
          media.viewInsets.bottom -
          statusBar -
          handle -
          LoafSpace.x4;
      return Padding(
        padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
        child: SizedBox(
          height: room.clamp(0.0, media.size.height * 0.8),
          child: SafeArea(top: false, child: picker),
        ),
      );
    },
  );
}

class NewMessagePicker extends StatefulWidget {
  const NewMessagePicker({
    super.key,
    required this.people,
    required this.rooms,
  });

  /// Everyone you could start with: people you share a space or a DM with.
  /// A real server search (`/user_directory/search`) would widen this as
  /// you type.
  final List<Member> people;

  /// Your DMs, for finding what already exists.
  final List<Channel> rooms;

  @override
  State<NewMessagePicker> createState() => _NewMessagePickerState();
}

class _NewMessagePickerState extends State<NewMessagePicker> {
  final _query = TextEditingController();
  final _picked = <Member>[];

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  /// A full Matrix id nobody here has, such as `@someone:matrix.org`.
  static final _mxid = RegExp(r'^@[^:\s]+:[^\s]+$');

  List<Member> get _matches {
    final q = _query.text.trim().toLowerCase();
    DateTime latest(Member m) =>
        existingWith(m, widget.rooms).firstOrNull?.lastActivity ??
        DateTime.fromMillisecondsSinceEpoch(0);
    // People you already talk to first, most recent first; then everyone
    // else by name.
    final people =
        [
          for (final m in widget.people)
            if (q.isEmpty ||
                m.name.toLowerCase().contains(q) ||
                m.id.toLowerCase().contains(q))
              m,
        ]..sort((a, b) {
          final byRecent = latest(b).compareTo(latest(a));
          return byRecent != 0 ? byRecent : a.name.compareTo(b.name);
        });
    final typed = _query.text.trim();
    final unknown =
        _mxid.hasMatch(typed) && !widget.people.any((m) => m.id == typed);
    return [
      if (unknown) Member(typed, typed, const Color(0xFF64748B)),
      ...people,
    ];
  }

  void _toggle(Member m) => setState(() {
    final at = _picked.indexWhere((p) => p.id == m.id);
    if (at >= 0) {
      _picked.removeAt(at);
      return;
    }
    _picked.add(m);
    // A search did its job once someone is picked; clear it for the next.
    _query.clear();
  });

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final start = startMessage(_picked, widget.rooms);
    final matches = _matches;
    final now = DateTime.now();

    return Padding(
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
            'new message',
            style: loafDisplay(20, 600).copyWith(color: tokens.textStrong),
          ),
          const SizedBox(height: LoafSpace.x3),
          TextField(
            controller: _query,
            autofocus: true,
            style: loafBody(15, 400).copyWith(color: tokens.textStrong),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: Icon(
                LucideIcons.search,
                size: 18,
                color: tokens.textMuted,
              ),
              hintText: 'a name, or @someone:server',
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
              // Focus is not an alarm: a firmer outline, not the accent red.
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(LoafRadius.md),
                borderSide: BorderSide(color: tokens.borderStrong, width: 1.5),
              ),
            ),
          ),
          if (_picked.isNotEmpty) ...[
            const SizedBox(height: LoafSpace.x2),
            Wrap(
              spacing: LoafSpace.x2,
              runSpacing: LoafSpace.x2,
              children: [
                for (final m in _picked)
                  InputChip(
                    label: Text(m.name),
                    labelStyle: loafBody(
                      13,
                      500,
                    ).copyWith(color: tokens.textStrong),
                    backgroundColor: tokens.sunken,
                    side: BorderSide(color: tokens.border),
                    onDeleted: () => _toggle(m),
                    deleteButtonTooltipMessage: 'Remove',
                  ),
              ],
            ),
          ],
          const SizedBox(height: LoafSpace.x2),
          Expanded(
            child: ListView(
              children: [
                for (final m in matches)
                  _PersonRow(
                    key: ValueKey('person-${m.id}'),
                    person: m,
                    picked: _picked.any((p) => p.id == m.id),
                    existing: existingWith(m, widget.rooms),
                    now: now,
                    onToggle: () => _toggle(m),
                    onOpen: (room) =>
                        Navigator.pop(context, OpenExisting(room)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: LoafSpace.x3),
          LoafButton(
            label: start?.label ?? 'message',
            onTap: start == null ? null : () => Navigator.pop(context, start),
          ),
        ],
      ),
    );
  }
}

/// A person, and right under them any 1:1 rooms you already have with
/// them — so the way to an old conversation is in plain sight, and a
/// second room never gets made by accident.
class _PersonRow extends StatelessWidget {
  const _PersonRow({
    super.key,
    required this.person,
    required this.picked,
    required this.existing,
    required this.now,
    required this.onToggle,
    required this.onOpen,
  });

  final Member person;
  final bool picked;
  final List<Channel> existing;
  final DateTime now;
  final VoidCallback onToggle;
  final ValueChanged<Channel> onOpen;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(LoafRadius.md),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: LoafSpace.x2,
              vertical: 6,
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 32,
                  height: 32,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: person.color,
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          person.initials.characters.first,
                          style: loafBody(
                            13,
                            600,
                          ).copyWith(color: Colors.white),
                        ),
                      ),
                      Positioned(
                        right: -2,
                        bottom: -2,
                        child: PresenceDot(
                          presence: person.presence,
                          ring: tokens.card,
                          size: 11,
                        ),
                      ),
                    ],
                  ),
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
                        style: loafBody(
                          15,
                          600,
                        ).copyWith(color: tokens.textStrong),
                      ),
                      if (person.name != person.id)
                        Text(
                          person.id,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: loafBody(
                            12,
                            400,
                          ).copyWith(color: tokens.textMuted),
                        ),
                    ],
                  ),
                ),
                Icon(
                  picked ? LucideIcons.circleCheck : LucideIcons.circle,
                  size: 20,
                  color: picked ? tokens.accent : tokens.borderStrong,
                ),
              ],
            ),
          ),
        ),
        for (final room in existing)
          InkWell(
            onTap: () => onOpen(room),
            borderRadius: BorderRadius.circular(LoafRadius.md),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(52, 4, LoafSpace.x2, 6),
              child: Row(
                children: [
                  Icon(
                    LucideIcons.messageCircle,
                    size: 14,
                    color: tokens.textMuted,
                  ),
                  const SizedBox(width: LoafSpace.x2),
                  Expanded(
                    child: Text(
                      'conversation · '
                      '${room.lastActivity == null ? 'active' : activeLabel(room.lastActivity!, now)}',
                      style: loafBody(13, 500).copyWith(color: tokens.textBody),
                    ),
                  ),
                  Icon(
                    LucideIcons.chevronRight,
                    size: 14,
                    color: tokens.textMuted,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
