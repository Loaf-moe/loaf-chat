/// The two controls every settings section is built from: a small caps
/// label over a group, and a titled checkbox row with a line of detail.
library;

import 'package:flutter/material.dart';

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
