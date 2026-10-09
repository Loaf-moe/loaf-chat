/// The one shape a mention pill has, in the timeline and in the composer, so
/// a name looks the same before it is sent as after.
library;

import '../theme/loaf_theme.dart';

/// The pill's height, as a multiple of its font size: a little taller than
/// the glyphs, and short enough to sit inside any line the app sets text in.
const mentionPillHeight = 1.3;

/// Room between the name and the pill's ends.
const mentionPillPadX = 6.0;

const mentionPillRadius = LoafRadius.md;
