import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/channel/message_group_tile.dart';
import 'package:loaf_native/ui/members/role_colors.dart';
import 'package:loaf_native/ui/mock/fixtures.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

void main() {
  // Name colour means power level everywhere — see "Name colour" in the
  // design spec. The per-member colour is only an avatar fallback.
  for (final (label, powerLevel, role) in [
    ('admin', 100, Role.admin),
    ('moderator', 50, Role.moderator),
    ('member', 0, Role.member),
  ]) {
    testWidgets('a $label\'s name in the timeline wears the $label colour', (
      tester,
    ) async {
      final author = Member(
        '@x',
        'Pat Rye',
        const Color(0xFF00FF00),
        powerLevel: powerLevel,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: loafDarkTheme(),
          home: Scaffold(
            body: MessageGroupTile(
              group: MessageGroup([
                Message(
                  id: '1',
                  author: author,
                  sentAt: DateTime(2026, 9, 24, 10),
                  body: 'hello',
                ),
              ]),
            ),
          ),
        ),
      );

      final tokens = loafDarkTheme().extension<LoafTokens>()!;
      final name = tester.widget<Text>(find.text('Pat Rye'));
      expect(name.style?.color, tokens.nameColor(role));
      expect(
        name.style?.color,
        isNot(author.color),
        reason: 'the avatar colour must not leak into the name',
      );
    });
  }
}
