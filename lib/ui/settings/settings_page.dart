/// User-level settings, as an overlay rather than a destination.
///
/// On a big screen it is a centred modal over a scrim: settings is a detour,
/// and keeping the app visible behind it says so. On a phone there is no room
/// for that, so the same card takes the whole screen.
///
/// Inside the card, wide shows the nav beside the detail; narrow shows the
/// nav and swaps to the detail in place. The detail never pushes an app-level
/// route, because a route would escape the card it belongs to.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/loaf_theme.dart';
import '../widgets/loaf_button.dart';
import 'profile_section.dart';

enum SettingsSection {
  profile('profile', LucideIcons.user, SettingsGroup.you),
  account('account', LucideIcons.keyRound, SettingsGroup.you),
  sessions('sessions', LucideIcons.monitorSmartphone, SettingsGroup.you),
  notifications('notifications', LucideIcons.bell, SettingsGroup.app),
  appearance('appearance', LucideIcons.palette, SettingsGroup.app),
  about('about', LucideIcons.info, SettingsGroup.app);

  const SettingsSection(this.label, this.icon, this.group);

  final String label;
  final IconData icon;
  final SettingsGroup group;
}

/// Nav grouping: your identity, then the app itself.
enum SettingsGroup {
  you('you'),
  app('app');

  const SettingsGroup(this.label);
  final String label;
}

/// Below this the nav and the detail are separate screens.
const _twoPaneFrom = 900.0;

/// Opens settings over the current screen.
Future<void> showSettings(BuildContext context) => showDialog<void>(
  context: context,
  barrierColor: const Color(0x99000016),
  builder: (_) => const SettingsModal(),
);

class SettingsModal extends StatefulWidget {
  const SettingsModal({super.key, this.initial = SettingsSection.profile});

  /// Settings opens on the profile: it is the one people come here for.
  final SettingsSection initial;

  @override
  State<SettingsModal> createState() => _SettingsModalState();
}

class _SettingsModalState extends State<SettingsModal> {
  late var _section = widget.initial;

  /// Narrow only: null means the nav is showing.
  SettingsSection? _pushed;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final screen = MediaQuery.sizeOf(context);
    final wide = screen.width >= _twoPaneFrom;

    return Dialog(
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
        child: SafeArea(child: wide ? _twoPane() : _onePane(tokens)),
      ),
    );
  }

  Widget _twoPane() => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SizedBox(
        width: 260,
        child: _Nav(
          selected: _section,
          onSelect: (s) => setState(() => _section = s),
          onClose: () => Navigator.of(context).pop(),
        ),
      ),
      Expanded(child: _Detail(section: _section)),
    ],
  );

  Widget _onePane(LoafTokens tokens) {
    final pushed = _pushed;
    if (pushed == null) {
      return _Nav(
        selected: null,
        onSelect: (s) => setState(() => _pushed = s),
        onClose: () => Navigator.of(context).pop(),
      );
    }

    return Column(
      children: [
        _DetailBar(
          title: pushed.label,
          onBack: () => setState(() => _pushed = null),
        ),
        Expanded(child: _Detail(section: pushed)),
      ],
    );
  }
}

class _Nav extends StatelessWidget {
  const _Nav({
    required this.selected,
    required this.onSelect,
    required this.onClose,
  });

  /// Null on the narrow layout, where nothing is selected in place.
  final SettingsSection? selected;
  final ValueChanged<SettingsSection> onSelect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);

    return Container(
      color: tokens.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              LoafSpace.x4,
              LoafSpace.x4,
              LoafSpace.x2,
              LoafSpace.x3,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'settings',
                    style: loafDisplay(
                      20,
                      600,
                    ).copyWith(color: tokens.textStrong),
                  ),
                ),
                IconButton(
                  onPressed: onClose,
                  iconSize: 18,
                  color: tokens.textMuted,
                  icon: const Icon(LucideIcons.x),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x2),
              children: [
                for (final group in SettingsGroup.values) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      LoafSpace.x2,
                      LoafSpace.x3,
                      LoafSpace.x2,
                      LoafSpace.x1,
                    ),
                    child: Text(
                      group.label.toUpperCase(),
                      style: loafBody(11, 600).copyWith(
                        color: tokens.textMuted,
                        letterSpacing: 0.04 * 11,
                      ),
                    ),
                  ),
                  for (final section in SettingsSection.values.where(
                    (s) => s.group == group,
                  ))
                    _NavItem(
                      section: section,
                      active: section == selected,
                      onTap: () => onSelect(section),
                    ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          _SignOut(tokens: tokens),
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
  const _SignOut({required this.tokens});

  final LoafTokens tokens;

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
        onTap: () {},
      ),
    ),
  );
}

/// The narrow layout's header over a pushed section.
class _DetailBar extends StatelessWidget {
  const _DetailBar({required this.title, required this.onBack});

  final String title;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);

    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x2),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.border)),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: onBack,
            iconSize: 20,
            color: tokens.textBody,
            icon: const Icon(LucideIcons.arrowLeft),
          ),
          Text(
            title,
            style: loafDisplay(17, 600).copyWith(color: tokens.textStrong),
          ),
        ],
      ),
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({required this.section});

  final SettingsSection section;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);

    if (section == SettingsSection.profile) return const ProfileSection();

    // Honest placeholder: the IA is decided, these screens are not designed.
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(LoafSpace.x6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(section.icon, size: 28, color: tokens.textMuted),
            const SizedBox(height: LoafSpace.x3),
            Text(
              '${section.label} is not designed yet',
              style: loafBody(13, 400).copyWith(color: tokens.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}
