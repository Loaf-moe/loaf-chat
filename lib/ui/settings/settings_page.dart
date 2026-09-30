/// User-level settings, as an overlay rather than a destination.
///
/// On a big screen it is a centred modal over a scrim: settings is a detour,
/// and keeping the app visible behind it says so. On a phone there is no room
/// for that, so the same card takes the whole screen.
///
/// Inside the card, wide shows the nav beside the detail; narrow shows the
/// nav and swaps to the detail in place. The detail never pushes an app-level
/// route, because a route would escape the card it belongs to.
///
/// Only sections that do something are listed: a section with nothing behind
/// it yet is left out rather than shown as a placeholder.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../model/models.dart';

import '../shell/profile_controller.dart';
import '../theme/loaf_theme.dart';
import '../widgets/avatar_images.dart';
import '../widgets/loaf_button.dart';
import 'account_section.dart';
import 'devices.dart';
import 'devices_section.dart';

enum SettingsSection {
  account('account', LucideIcons.circleUser),
  devices('devices', LucideIcons.monitorSmartphone);

  const SettingsSection(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// Below this the nav and the detail are separate screens.
const _twoPaneFrom = 900.0;

/// Opens settings over the current screen. [profile] is shared with the
/// account panel's status picker, so both edit the same presence. [me] is
/// who the account section shows, and [editable] whether it offers to
/// change anything; [onSignOut] is what the sign-out button does, and left
/// null there is no sign-out button. [devices] left null leaves the devices
/// section out.
Future<void> showSettings(
  BuildContext context, {
  ProfileController? profile,
  Member? me,
  bool editable = true,
  VoidCallback? onSignOut,
  SettingsSection initial = SettingsSection.account,
  Devices? devices,
}) => showDialog<void>(
  context: context,
  barrierColor: const Color(0x99000016),
  // The dialog is a root-navigator route, above the shell's avatar scope.
  builder: (_) => AvatarImagesScope.carry(
    context,
    child: SettingsModal(
      initial: initial,
      devices: devices,
      profile: profile,
      me: me,
      editable: editable,
      onSignOut: onSignOut,
    ),
  ),
);

class SettingsModal extends StatefulWidget {
  const SettingsModal({
    super.key,
    this.initial = SettingsSection.account,
    this.profile,
    this.me,
    this.editable = true,
    this.onSignOut,
    this.devices,
  });

  final ProfileController? profile;

  /// Left null, there is no devices section: a backend that can't list
  /// sessions has none to show.
  final Devices? devices;

  /// Left null (in isolation, as in tests), the mock's account.
  final Member? me;
  final bool editable;

  /// Left null, there is no sign-out button: one that did nothing would be a
  /// lie.
  final VoidCallback? onSignOut;

  /// Settings opens on the account, which carries the profile — the thing
  /// people actually come here to change. A section that isn't offered falls
  /// back to the account.
  final SettingsSection initial;

  @override
  State<SettingsModal> createState() => _SettingsModalState();
}

class _SettingsModalState extends State<SettingsModal> {
  /// What this backend can back. The account always; devices only with
  /// something that lists them.
  List<SettingsSection> get _sections => [
    SettingsSection.account,
    if (widget.devices != null) SettingsSection.devices,
  ];

  late var _section = _sections.contains(widget.initial)
      ? widget.initial
      : SettingsSection.account;

  /// Narrow only: null means the nav is showing.
  SettingsSection? _pushed;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final screen = MediaQuery.sizeOf(context);
    final wide = screen.width >= _twoPaneFrom;
    final inDetail = !wide && _pushed != null;

    return PopScope(
      // Back steps out of a section before it closes the card. Without this
      // the system back gesture skips a level and dismisses everything.
      canPop: !inDetail,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _pushed = null);
      },
      child: Dialog(
        backgroundColor: tokens.page,
        clipBehavior: Clip.antiAlias,
        elevation: 0,
        // Full-bleed on a phone, a floating card on anything larger.
        insetPadding: wide
            ? const EdgeInsets.all(LoafSpace.x10)
            : EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(wide ? LoafRadius.xxl : 0),
          side: wide ? BorderSide(color: tokens.border) : BorderSide.none,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960, maxHeight: 680),
          child: SafeArea(
            child: Column(
              children: [
                // One header for every state. Close belongs to the card, so
                // it never disappears; back appears only when there is a
                // level to go back to.
                _CardHeader(
                  title: inDetail ? _pushed!.label : 'settings',
                  onBack: inDetail
                      ? () => setState(() => _pushed = null)
                      : null,
                  onClose: () => Navigator.of(context).pop(),
                ),
                Expanded(child: wide ? _twoPane() : _onePane()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _twoPane() => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SizedBox(
        width: 260,
        child: _Nav(
          sections: _sections,
          selected: _section,
          onSelect: (s) => setState(() => _section = s),
          onSignOut: _signOut,
        ),
      ),
      Expanded(child: _detail(_section)),
    ],
  );

  Widget _onePane() {
    final pushed = _pushed;
    if (pushed == null) {
      return _Nav(
        sections: _sections,
        selected: null,
        onSelect: (s) => setState(() => _pushed = s),
        onSignOut: _signOut,
      );
    }
    return _detail(pushed);
  }

  /// Closes the card, then signs out. Signing out swaps the shell for the
  /// sign-in screen underneath, and a card left open would sit over it
  /// showing the account just signed out of.
  VoidCallback? get _signOut {
    final signOut = widget.onSignOut;
    if (signOut == null) return null;
    return () {
      Navigator.of(context).pop();
      signOut();
    };
  }

  Widget _detail(SettingsSection section) => _Detail(
    section: section,
    profile: widget.profile,
    me: widget.me,
    editable: widget.editable,
    devices: widget.devices,
  );
}

/// The card's header. Same height, same type, same close button in every
/// state — only the title and the presence of a back arrow change.
class _CardHeader extends StatelessWidget {
  const _CardHeader({required this.title, required this.onClose, this.onBack});

  final String title;
  final VoidCallback onClose;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);

    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x2),
      decoration: BoxDecoration(
        color: tokens.sidebar,
        border: Border(bottom: BorderSide(color: tokens.border)),
      ),
      child: Row(
        children: [
          if (onBack != null)
            IconButton(
              onPressed: onBack,
              iconSize: 20,
              color: tokens.textBody,
              tooltip: 'Back',
              icon: const Icon(LucideIcons.arrowLeft),
            )
          else
            const SizedBox(width: LoafSpace.x2),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: loafDisplay(17, 600).copyWith(color: tokens.textStrong),
            ),
          ),
          IconButton(
            onPressed: onClose,
            iconSize: 18,
            color: tokens.textMuted,
            tooltip: 'Close',
            icon: const Icon(LucideIcons.x),
          ),
        ],
      ),
    );
  }
}

class _Nav extends StatelessWidget {
  const _Nav({
    required this.sections,
    required this.selected,
    required this.onSelect,
    this.onSignOut,
  });

  final List<SettingsSection> sections;
  final VoidCallback? onSignOut;

  /// Null on the narrow layout, where nothing is selected in place.
  final SettingsSection? selected;
  final ValueChanged<SettingsSection> onSelect;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);

    return Container(
      color: tokens.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                LoafSpace.x2,
                LoafSpace.x3,
                LoafSpace.x2,
                LoafSpace.x2,
              ),
              children: [
                for (final section in sections)
                  _NavItem(
                    section: section,
                    active: section == selected,
                    onTap: () => onSelect(section),
                  ),
              ],
            ),
          ),
          if (onSignOut case final signOut?) ...[
            const Divider(height: 1),
            _SignOut(onTap: signOut),
          ],
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.section,
    required this.active,
    required this.onTap,
  });

  final SettingsSection section;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: active ? tokens.card : Colors.transparent,
        borderRadius: BorderRadius.circular(LoafRadius.md),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(LoafRadius.md),
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x2),
            child: Row(
              children: [
                Icon(
                  section.icon,
                  size: 17,
                  color: active ? tokens.accent : tokens.textMuted,
                ),
                const SizedBox(width: LoafSpace.x3),
                Expanded(
                  child: Text(
                    section.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: loafBody(
                      13,
                      active ? 600 : 400,
                    ).copyWith(color: active ? tokens.accent : tokens.textBody),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SignOut extends StatelessWidget {
  const _SignOut({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(LoafSpace.x3),
    child: Align(
      alignment: Alignment.centerLeft,
      child: LoafButton(
        label: 'sign out',
        icon: LucideIcons.logOut,
        emphasis: LoafButtonEmphasis.quiet,
        size: LoafButtonSize.small,
        onTap: onTap,
      ),
    ),
  );
}

class _Detail extends StatelessWidget {
  const _Detail({
    required this.section,
    required this.profile,
    required this.me,
    required this.editable,
    this.devices,
  });

  final Devices? devices;
  final SettingsSection section;
  final ProfileController? profile;
  final Member? me;
  final bool editable;

  @override
  Widget build(BuildContext context) => switch (section) {
    SettingsSection.account => AccountSection(
      profile: profile,
      me: me,
      editable: editable,
    ),
    // Only offered with devices to show; the null check is the backstop.
    SettingsSection.devices => switch (devices) {
      final devices? => DevicesSection(devices: devices),
      null => AccountSection(profile: profile, me: me, editable: editable),
    },
  };
}
