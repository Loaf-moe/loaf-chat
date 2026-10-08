/// Appearance — which theme loaf chat wears, and whether the seasons may
/// dress it up anyway.
///
/// While a season is overriding the pick, the section says so: otherwise
/// tapping a theme and seeing nothing change would look broken.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/appearance.dart';
import '../theme/loaf_theme.dart';

class AppearanceSection extends StatelessWidget {
  const AppearanceSection({super.key, required this.controller});

  final AppearanceController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final tokens = LoafTokens.of(context);
      final muted = loafBody(13, 400).copyWith(color: tokens.textMuted);
      return ListView(
        padding: const EdgeInsets.all(LoafSpace.x6),
        children: [
          _Label(tokens: tokens, label: 'theme'),
          for (final id in LoafThemeId.values) ...[
            _ThemeRow(
              id: id,
              selected: controller.chosen == id,
              onTap: () => controller.choose(id),
            ),
            const SizedBox(height: LoafSpace.x2),
          ],
          if (controller.seasonOverrides) ...[
            const SizedBox(height: LoafSpace.x1),
            Text(
              'an easter egg is dressing things up right now. '
              'turn off easter eggs to use your pick.',
              style: muted,
            ),
          ],
          const SizedBox(height: LoafSpace.x6),
          _Check(
            title: 'easter eggs',
            detail: 'the occasional surprise.',
            value: controller.easterEggs,
            onChanged: controller.setEasterEggs,
          ),
          const SizedBox(height: LoafSpace.x4),
          _Label(tokens: tokens, label: 'media'),
          _Check(
            title: 'external content',
            detail:
                'show pictures and video hosted on other sites. fetching '
                'them tells those sites your address. never used in '
                'encrypted rooms.',
            value: controller.externalMedia,
            onChanged: controller.setExternalMedia,
          ),
        ],
      );
    },
  );
}

class _Label extends StatelessWidget {
  const _Label({required this.tokens, required this.label});

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

class _ThemeRow extends StatelessWidget {
  const _ThemeRow({
    required this.id,
    required this.selected,
    required this.onTap,
  });

  final LoafThemeId id;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    // The swatch shows the theme's own page and accent, not the current one.
    final own = loafTheme(id).extension<LoafTokens>()!;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? tokens.card : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LoafRadius.lg),
          side: BorderSide(
            color: selected ? tokens.borderStrong : tokens.border,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(LoafSpace.x3),
            child: Row(
              children: [
                _Swatch(page: own.page, accent: own.accent),
                const SizedBox(width: LoafSpace.x3),
                Expanded(
                  child: Text(
                    id.label,
                    style: loafBody(15, 600).copyWith(color: tokens.textStrong),
                  ),
                ),
                if (selected)
                  Icon(LucideIcons.check, size: 18, color: tokens.accent),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.page, required this.accent});

  final Color page;
  final Color accent;

  @override
  Widget build(BuildContext context) => Container(
    width: 32,
    height: 32,
    decoration: BoxDecoration(
      color: page,
      borderRadius: BorderRadius.circular(LoafRadius.md),
      border: Border.all(color: LoafTokens.of(context).border),
    ),
    alignment: Alignment.center,
    child: Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
    ),
  );
}

class _Check extends StatelessWidget {
  const _Check({
    required this.title,
    required this.detail,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String detail;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return MergeSemantics(
      child: InkWell(
        borderRadius: BorderRadius.circular(LoafRadius.lg),
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: LoafSpace.x2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                value: value,
                activeColor: tokens.accent,
                checkColor: tokens.textOnAccent,
                onChanged: (v) => onChanged(v ?? true),
              ),
              const SizedBox(width: LoafSpace.x2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: LoafSpace.x2),
                    Text(
                      title,
                      style: loafBody(
                        15,
                        600,
                      ).copyWith(color: tokens.textStrong),
                    ),
                    Text(
                      detail,
                      style: loafBody(
                        13,
                        400,
                      ).copyWith(color: tokens.textMuted),
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
