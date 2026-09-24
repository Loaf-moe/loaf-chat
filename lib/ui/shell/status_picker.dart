/// Tap your avatar to set how you appear: presence and a status message. A
/// bottom sheet on a phone, a popover above the account panel on a computer.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../members/presence.dart';
import '../members/presence_dot.dart';
import '../platform.dart';
import '../theme/loaf_theme.dart';
import 'profile_controller.dart';

/// Opens the picker from the avatar at [anchor] (global coordinates).
/// Picking a presence applies it and closes; the status message is saved on
/// enter or whenever the picker closes.
Future<void> showStatusPicker(
  BuildContext context,
  ProfileController profile, {
  required Rect anchor,
}) async {
  // The field reports every edit here, so the status can be saved after the
  // picker has closed rather than while its widgets are being torn down.
  final draft = _Draft(profile.status);
  final content = _PickerContent(profile: profile, draft: draft);

  if (isDesktop) {
    final tokens = LoafTokens.of(context);
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    await showMenu<void>(
      context: context,
      color: tokens.card,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LoafRadius.lg),
        side: BorderSide(color: tokens.border),
      ),
      // Anchored on the avatar; showMenu lifts it to stay on screen, which
      // near the panel means rising above it.
      position: RelativeRect.fromLTRB(
        anchor.left,
        anchor.top,
        overlay.size.width - anchor.left,
        overlay.size.height - anchor.top,
      ),
      items: [_PickerMenuEntry(child: content)],
    );
  } else {
    final tokens = LoafTokens.of(context);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: tokens.card,
      showDragHandle: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(LoafRadius.xxxl),
        ),
      ),
      // Rides up with the keyboard while you type a status.
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SafeArea(top: false, child: content),
      ),
    );
  }

  profile.setStatus(draft.text);
}

class _Draft {
  _Draft(this.text);
  String text;
}

class _PickerMenuEntry extends PopupMenuEntry<void> {
  const _PickerMenuEntry({required this.child});

  final Widget child;

  @override
  double get height => 300;

  @override
  bool represents(void value) => false;

  @override
  State<_PickerMenuEntry> createState() => _PickerMenuEntryState();
}

class _PickerMenuEntryState extends State<_PickerMenuEntry> {
  @override
  Widget build(BuildContext context) =>
      SizedBox(width: 300, child: widget.child);
}

class _PickerContent extends StatefulWidget {
  const _PickerContent({required this.profile, required this.draft});

  final ProfileController profile;
  final _Draft draft;

  @override
  State<_PickerContent> createState() => _PickerContentState();
}

class _PickerContentState extends State<_PickerContent> {
  late final _status = TextEditingController(text: widget.draft.text);

  @override
  void dispose() {
    _status.dispose();
    super.dispose();
  }

  void _choose(PresenceChoice choice) {
    widget.profile.choose(choice);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final current = widget.profile.choice;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LoafSpace.x4,
        LoafSpace.x2,
        LoafSpace.x4,
        LoafSpace.x3,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            decoration: BoxDecoration(
              color: tokens.sunken,
              borderRadius: BorderRadius.circular(LoafRadius.md),
              border: Border.all(color: tokens.border),
            ),
            padding: const EdgeInsets.only(left: LoafSpace.x3),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _status,
                    onChanged: (text) => widget.draft.text = text,
                    onSubmitted: (text) {
                      widget.draft.text = text;
                      Navigator.pop(context);
                    },
                    textInputAction: TextInputAction.done,
                    style: loafBody(14, 400).copyWith(color: tokens.textStrong),
                    decoration: InputDecoration(
                      isCollapsed: true,
                      border: InputBorder.none,
                      hintText: "what's cooking?",
                      hintStyle: loafBody(
                        14,
                        400,
                      ).copyWith(color: tokens.textMuted),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Clear status',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() {
                    _status.clear();
                    widget.draft.text = '';
                  }),
                  icon: Icon(LucideIcons.x, size: 16, color: tokens.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(height: LoafSpace.x2),
          for (final choice in PresenceChoice.values)
            InkWell(
              borderRadius: BorderRadius.circular(LoafRadius.md),
              onTap: () => _choose(choice),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: LoafSpace.x2,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    PresenceDot(
                      presence: choice.shown,
                      ring: tokens.card,
                      size: 14,
                    ),
                    const SizedBox(width: LoafSpace.x3),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            choice.label,
                            style: loafBody(
                              14,
                              600,
                            ).copyWith(color: tokens.textStrong),
                          ),
                          Text(
                            choice.description,
                            style: loafBody(
                              12,
                              400,
                            ).copyWith(color: tokens.textMuted),
                          ),
                        ],
                      ),
                    ),
                    if (choice == current)
                      Icon(LucideIcons.check, size: 16, color: tokens.accent),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
