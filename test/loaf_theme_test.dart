import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

/// Lora and Outfit are variable fonts whose default instance is the lightest
/// weight. Flutter does not drive the `wght` axis from [TextStyle.fontWeight],
/// so a style missing its `fontVariations` renders hairline-thin and nothing
/// else catches it. These assertions are that catch.
void main() {
  test('variable-font styles carry a wght variation matching their weight', () {
    for (final weight in [300, 400, 500, 600, 700]) {
      for (final style in [loafBody(15, weight), loafDisplay(17, weight)]) {
        expect(style.fontWeight?.value, weight);
        expect(
          style.fontVariations,
          contains(FontVariation('wght', weight.toDouble())),
          reason: '$style is missing its wght axis and will render as Thin',
        );
      }
    }
  });

  test('every themed text style sets its weight axis', () {
    for (final theme in [loafLightTheme(), loafDarkTheme()]) {
      final styles = <TextStyle?>[
        theme.textTheme.displaySmall,
        theme.textTheme.headlineMedium,
        theme.textTheme.headlineSmall,
        theme.textTheme.titleLarge,
        theme.textTheme.titleMedium,
        theme.textTheme.titleSmall,
        theme.textTheme.bodyLarge,
        theme.textTheme.bodyMedium,
        theme.textTheme.bodySmall,
        theme.textTheme.labelLarge,
        theme.textTheme.labelMedium,
        theme.textTheme.labelSmall,
      ];
      for (final style in styles) {
        expect(style, isNotNull);
        expect(
          style!.fontVariations,
          contains(FontVariation('wght', style.fontWeight!.value.toDouble())),
          reason: 'copyWith dropped the wght axis for $style',
        );
      }
    }
  });

  test('both themes expose LoafTokens', () {
    expect(loafLightTheme().extension<LoafTokens>(), isNotNull);
    expect(loafDarkTheme().extension<LoafTokens>(), isNotNull);
  });
}
