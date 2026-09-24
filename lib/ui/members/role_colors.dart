/// Name colour means power level — everywhere a name is drawn.
///
/// Kept beside the member list rather than in the theme so the theme never
/// has to know about the mock models.
library;

import 'package:flutter/material.dart';

import '../mock/fixtures.dart';
import '../theme/loaf_theme.dart';

extension RoleColors on LoafTokens {
  /// The colour a member's name is drawn in. Intent, recorded in the design
  /// spec under "Name colour": a coloured name tells you who can act on the
  /// room, and nothing else. Identity lives in the avatar.
  Color nameColor(Role role) => switch (role) {
    Role.admin => accent,
    Role.moderator => nameModerator,
    Role.member => textStrong,
  };
}
