/// The controls every settings section is built from: a small caps label
/// over a group, a titled checkbox row with a line of detail, and a row
/// for one choice among several.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/loaf_theme.dart';

class SettingsLabel extends StatelessWidget {
  const SettingsLabel({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Padding(
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
}

class SettingsCheck extends StatelessWidget {
  const SettingsCheck({
    super.key,
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

/// One of several: a bordered row, checked when it is the one chosen.
class SettingsChoice extends StatelessWidget {
  const SettingsChoice({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.busy = false,
  });

  final String title;
  final bool selected;
  final VoidCallback onTap;

  /// Chosen, and not yet in place: a spinner stands in for the check.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
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
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: loafBody(15, 500).copyWith(color: tokens.textStrong),
                  ),
                ),
                if (busy)
                  SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: tokens.accent,
                    ),
                  )
                else if (selected)
                  Icon(LucideIcons.check, size: 18, color: tokens.accent),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
