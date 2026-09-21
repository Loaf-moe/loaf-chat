/// The loaf.moe design system, ported to Flutter.
///
/// Source of truth is the design system's `tokens/*.css`. Colours, type and
/// form all come from there; the dark palette is derived from the navy scale,
/// since the brand defines no dark tokens of its own but already uses
/// navy-900 for the spaces rail.
library;

import 'package:flutter/material.dart';

// ── Brand constants ────────────────────────────────────────────────────────
// Straight from tokens/colors.css. Do not use these directly in widgets —
// read them off [LoafTokens] so light and dark both work.

const _primary900 = Color(0xFF000016);
const _primary700 = Color(0xFF003049);
const _primary500 = Color(0xFF33596D);
const _primary300 = Color(0xFF8098A4);
const _primary100 = Color(0xFFD9E0E4);

const _accent900 = Color(0xFFA30000);
const _accent700 = Color(0xFFD62828);
const _accent500 = Color(0xFFDE5353);
const _accent100 = Color(0xFFF9DFDF);

const _cream = Color(0xFFFFF7ED);
const _white = Color(0xFFFFFFFF);
const _subtle = Color(0xFFF9FAFB);
const _muted = Color(0xFF6B7280);
const _border = Color(0xFFE5E7EB);

const _success = Color(0xFF4E9E76);
const _warning = Color(0xFFD97B2A);
const _destructive = Color(0xFFEF4444);

// Dark palette, derived from the navy scale. The rail keeps navy-900 in both
// themes, so the brand's darkest surface is the anchor and everything else
// steps up from it. Surfaces get *darker* as they get more peripheral, the
// way the cream sidebar sits behind the white page in the light theme.
const _darkRail = _primary900;
const _darkSidebar = Color(0xFF001322);
const _darkPage = Color(0xFF001E2F);
const _darkCard = Color(0xFF01283C);
const _darkBorder = Color(0xFF093147);

// ── Form ───────────────────────────────────────────────────────────────────
// Radius and spacing do not vary by theme, so they are plain constants.

/// Corner radii. This brand is rounded: pills for actions, rounded-xl cards.
abstract final class LoafRadius {
  static const sm = 4.0;
  static const md = 8.0;
  static const lg = 12.0;
  static const xl = 16.0;
  static const xxl = 22.0;
  static const xxxl = 28.0;
  static const full = 9999.0;
}

/// 4px base grid.
abstract final class LoafSpace {
  static const x1 = 4.0;
  static const x2 = 8.0;
  static const x3 = 12.0;
  static const x4 = 16.0;
  static const x5 = 20.0;
  static const x6 = 24.0;
  static const x8 = 32.0;
  static const x10 = 40.0;
  static const x12 = 48.0;
  static const x16 = 64.0;
}

/// Shell metrics, from the design system's `ui_kits/app` desktop shell.
abstract final class LoafShell {
  static const railWidth = 76.0;
  static const sidebarWidth = 268.0;
}

/// Press animation: buttons shrink slightly and drop their shadow.
abstract final class LoafMotion {
  static const fast = Duration(milliseconds: 120);
  static const normal = Duration(milliseconds: 200);
  static const pressScale = 0.985;
  static const iconPressScale = 0.9;
  static const ease = Curves.easeOut;
}

// ── Typography ─────────────────────────────────────────────────────────────

/// Lora and Outfit are variable fonts. Flutter does **not** drive a variable
/// weight axis from [TextStyle.fontWeight] alone — without an explicit
/// `wght` variation the renderer uses the file's default instance, which for
/// Outfit is Thin. Every text style in the app is built here so no call site
/// has to remember that.
TextStyle _variable(
  String family,
  double size,
  int weight, {
  double? height,
  double? letterSpacing,
  FontStyle? style,
}) => TextStyle(
  fontFamily: family,
  fontSize: size,
  fontWeight: FontWeight.values.firstWhere((w) => w.value == weight),
  fontVariations: [FontVariation('wght', weight.toDouble())],
  height: height,
  letterSpacing: letterSpacing,
  fontStyle: style,
);

/// Outfit — the UI face. Everything that is not a heading or code.
TextStyle loafBody(double size, int weight, {double? height}) =>
    _variable('Outfit', size, weight, height: height);

/// Lora — warm display serif, for headings and space names.
TextStyle loafDisplay(
  double size,
  int weight, {
  double? height,
  FontStyle? style,
}) => _variable(
  'Lora',
  size,
  weight,
  height: height,
  letterSpacing: -0.02 * size,
  style: style,
);

/// IBM Plex Mono — code and other tool surfaces. Static weights, so no
/// variation axis is needed.
TextStyle loafMono(double size, {FontWeight weight = FontWeight.w400}) =>
    TextStyle(fontFamily: 'IBM Plex Mono', fontSize: size, fontWeight: weight);

// ── Theme extension ────────────────────────────────────────────────────────

/// The brand colours Material's [ColorScheme] has no slot for: the rail, the
/// sidebar, the three text weights, and the navy-tinted shadows.
@immutable
class LoafTokens extends ThemeExtension<LoafTokens> {
  const LoafTokens({
    required this.rail,
    required this.sidebar,
    required this.page,
    required this.sunken,
    required this.card,
    required this.border,
    required this.borderStrong,
    required this.textStrong,
    required this.textBody,
    required this.textMuted,
    required this.textOnAccent,
    required this.accent,
    required this.accentHover,
    required this.accentSoft,
    required this.online,
    required this.shadowSm,
    required this.shadowMd,
    required this.shadowLg,
    required this.shadowAccent,
  });

  /// Spaces rail. Navy-900 in both themes — the brand's anchor surface.
  final Color rail;

  /// Channel list. Cream in the light theme, the darkest step above the rail
  /// in the dark one.
  final Color sidebar;

  /// The channel you are reading.
  final Color page;

  /// Recessed fills: search fields, empty states.
  final Color sunken;

  /// Raised fills: cards, the active list item, menus.
  final Color card;

  final Color border;
  final Color borderStrong;

  final Color textStrong;
  final Color textBody;
  final Color textMuted;
  final Color textOnAccent;

  /// Warm red. Reserved and precious: send button, unread badges, the active
  /// channel accent, the logo dot. One red moment per zone.
  final Color accent;
  final Color accentHover;
  final Color accentSoft;

  final Color online;

  final List<BoxShadow> shadowSm;
  final List<BoxShadow> shadowMd;
  final List<BoxShadow> shadowLg;
  final List<BoxShadow> shadowAccent;

  static LoafTokens of(BuildContext context) =>
      Theme.of(context).extension<LoafTokens>()!;

  @override
  LoafTokens copyWith({
    Color? rail,
    Color? sidebar,
    Color? page,
    Color? sunken,
    Color? card,
    Color? border,
    Color? borderStrong,
    Color? textStrong,
    Color? textBody,
    Color? textMuted,
    Color? textOnAccent,
    Color? accent,
    Color? accentHover,
    Color? accentSoft,
    Color? online,
    List<BoxShadow>? shadowSm,
    List<BoxShadow>? shadowMd,
    List<BoxShadow>? shadowLg,
    List<BoxShadow>? shadowAccent,
  }) => LoafTokens(
    rail: rail ?? this.rail,
    sidebar: sidebar ?? this.sidebar,
    page: page ?? this.page,
    sunken: sunken ?? this.sunken,
    card: card ?? this.card,
    border: border ?? this.border,
    borderStrong: borderStrong ?? this.borderStrong,
    textStrong: textStrong ?? this.textStrong,
    textBody: textBody ?? this.textBody,
    textMuted: textMuted ?? this.textMuted,
    textOnAccent: textOnAccent ?? this.textOnAccent,
    accent: accent ?? this.accent,
    accentHover: accentHover ?? this.accentHover,
    accentSoft: accentSoft ?? this.accentSoft,
    online: online ?? this.online,
    shadowSm: shadowSm ?? this.shadowSm,
    shadowMd: shadowMd ?? this.shadowMd,
    shadowLg: shadowLg ?? this.shadowLg,
    shadowAccent: shadowAccent ?? this.shadowAccent,
  );

  @override
  LoafTokens lerp(LoafTokens? other, double t) {
    if (other == null) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    List<BoxShadow> s(List<BoxShadow> a, List<BoxShadow> b) =>
        BoxShadow.lerpList(a, b, t)!;
    return LoafTokens(
      rail: c(rail, other.rail),
      sidebar: c(sidebar, other.sidebar),
      page: c(page, other.page),
      sunken: c(sunken, other.sunken),
      card: c(card, other.card),
      border: c(border, other.border),
      borderStrong: c(borderStrong, other.borderStrong),
      textStrong: c(textStrong, other.textStrong),
      textBody: c(textBody, other.textBody),
      textMuted: c(textMuted, other.textMuted),
      textOnAccent: c(textOnAccent, other.textOnAccent),
      accent: c(accent, other.accent),
      accentHover: c(accentHover, other.accentHover),
      accentSoft: c(accentSoft, other.accentSoft),
      online: c(online, other.online),
      shadowSm: s(shadowSm, other.shadowSm),
      shadowMd: s(shadowMd, other.shadowMd),
      shadowLg: s(shadowLg, other.shadowLg),
      shadowAccent: s(shadowAccent, other.shadowAccent),
    );
  }
}

// ── Themes ─────────────────────────────────────────────────────────────────

const _lightTokens = LoafTokens(
  rail: _primary900,
  sidebar: _cream,
  page: _white,
  sunken: _subtle,
  card: _white,
  border: _border,
  borderStrong: _primary100,
  textStrong: _primary700,
  textBody: _primary500,
  textMuted: _muted,
  textOnAccent: _white,
  accent: _accent700,
  accentHover: _accent900,
  accentSoft: _accent100,
  online: _success,
  shadowSm: [
    BoxShadow(color: Color(0x14003049), blurRadius: 3, offset: Offset(0, 1)),
  ],
  shadowMd: [
    BoxShadow(color: Color(0x1A003049), blurRadius: 12, offset: Offset(0, 4)),
  ],
  shadowLg: [
    BoxShadow(color: Color(0x1F003049), blurRadius: 24, offset: Offset(0, 8)),
  ],
  shadowAccent: [
    BoxShadow(color: Color(0x59D62828), blurRadius: 16, offset: Offset(0, 4)),
  ],
);

// Shadows barely read on dark surfaces, so the dark theme leans on the
// surface ramp for depth and keeps only a soft black lift.
const _darkTokens = LoafTokens(
  rail: _darkRail,
  sidebar: _darkSidebar,
  page: _darkPage,
  sunken: Color(0xFF00121F),
  card: _darkCard,
  border: _darkBorder,
  borderStrong: Color(0xFF0E4058),
  textStrong: _cream,
  textBody: _primary100,
  textMuted: _primary300,
  textOnAccent: _white,
  accent: _accent500,
  accentHover: _accent700,
  accentSoft: Color(0xFF3A1414),
  online: _success,
  shadowSm: [
    BoxShadow(color: Color(0x40000000), blurRadius: 3, offset: Offset(0, 1)),
  ],
  shadowMd: [
    BoxShadow(color: Color(0x4D000000), blurRadius: 12, offset: Offset(0, 4)),
  ],
  shadowLg: [
    BoxShadow(color: Color(0x59000000), blurRadius: 24, offset: Offset(0, 8)),
  ],
  shadowAccent: [
    BoxShadow(color: Color(0x59D62828), blurRadius: 16, offset: Offset(0, 4)),
  ],
);

TextTheme _textTheme(LoafTokens t) => TextTheme(
  // Lora, for headings and space names.
  displaySmall: loafDisplay(30, 600, height: 1.1).copyWith(color: t.textStrong),
  headlineMedium: loafDisplay(
    24,
    600,
    height: 1.1,
  ).copyWith(color: t.textStrong),
  headlineSmall: loafDisplay(
    20,
    600,
    height: 1.3,
  ).copyWith(color: t.textStrong),
  titleLarge: loafDisplay(17, 600, height: 1.3).copyWith(color: t.textStrong),
  // Outfit, for everything else.
  titleMedium: loafBody(15, 600, height: 1.3).copyWith(color: t.textStrong),
  titleSmall: loafBody(13, 600, height: 1.3).copyWith(color: t.textStrong),
  bodyLarge: loafBody(15, 400, height: 1.5).copyWith(color: t.textBody),
  bodyMedium: loafBody(15, 400, height: 1.5).copyWith(color: t.textBody),
  bodySmall: loafBody(13, 400, height: 1.5).copyWith(color: t.textMuted),
  labelLarge: loafBody(15, 500, height: 1.3).copyWith(color: t.textStrong),
  labelMedium: loafBody(13, 500, height: 1.3).copyWith(color: t.textBody),
  labelSmall: loafBody(11, 500, height: 1.3).copyWith(color: t.textMuted),
);

ThemeData _theme(LoafTokens t, Brightness brightness) {
  final text = _textTheme(t);
  return ThemeData(
    brightness: brightness,
    fontFamily: 'Outfit',
    scaffoldBackgroundColor: t.page,
    canvasColor: t.page,
    dividerColor: t.border,
    extensions: [t],
    textTheme: text,
    colorScheme: ColorScheme(
      brightness: brightness,
      primary: t.accent,
      onPrimary: t.textOnAccent,
      secondary: _primary700,
      onSecondary: _cream,
      error: _destructive,
      onError: _white,
      surface: t.page,
      onSurface: t.textStrong,
      surfaceContainerLow: t.sidebar,
      surfaceContainerHighest: t.card,
      outline: t.border,
      tertiary: _warning,
      onTertiary: _white,
    ),
    iconTheme: IconThemeData(color: t.textBody, size: 20),
    dividerTheme: DividerThemeData(color: t.border, thickness: 1, space: 1),
    splashFactory: InkSparkle.splashFactory,
  );
}

ThemeData loafLightTheme() => _theme(_lightTokens, Brightness.light);
ThemeData loafDarkTheme() => _theme(_darkTokens, Brightness.dark);
