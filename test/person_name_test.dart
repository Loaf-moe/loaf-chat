import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/members/person_name.dart';
import 'package:loaf_native/ui/members/role_colors.dart';
import 'package:loaf_native/ui/model/models.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

const _avatar = Color(0xFF00FF00);

Future<void> _pump(WidgetTester tester, Member member) => tester.pumpWidget(
  MaterialApp(
    theme: loafDarkTheme(),
    home: Scaffold(body: PersonName(member, size: 15, weight: 600)),
  ),
);

void main() {
  for (final (label, powerLevel, role) in [
    ('admin', 100, Role.admin),
    ('moderator', 50, Role.moderator),
    ('member', 0, Role.member),
  ]) {
    testWidgets('a $label\'s name wears the $label colour', (tester) async {
      await _pump(tester, Member('@x', 'Pat', _avatar, powerLevel: powerLevel));
      final tokens = loafDarkTheme().extension<LoafTokens>()!;
      final name = tester.widget<Text>(find.text('Pat'));
      expect(name.style?.color, tokens.nameColor(role));
      expect(name.style?.color, isNot(_avatar));
    });
  }

  testWidgets('a Discord puppet wears the badge', (tester) async {
    await _pump(
      tester,
      const Member('@x', 'lou', _avatar, bridge: Bridge.discord),
    );
    final badge = tester.widget<Image>(find.byType(Image));
    expect(badge.semanticLabel, 'from Discord');
    expect(badge.width, 14);
    final name = tester.getRect(find.text('lou'));
    expect(tester.getRect(find.byType(Image)).left, greaterThan(name.right));
  });

  testWidgets(
    'on a computer the badge says where from on hover',
    variant: TargetPlatformVariant.desktop(),
    (tester) async {
      await _pump(
        tester,
        const Member('@x', 'lou', _avatar, bridge: Bridge.discord),
      );
      expect(find.byTooltip('from Discord'), findsOneWidget);
    },
  );

  testWidgets(
    'on a phone the badge has no tooltip to answer a long press',
    variant: TargetPlatformVariant.mobile(),
    (tester) async {
      await _pump(
        tester,
        const Member('@x', 'lou', _avatar, bridge: Bridge.discord),
      );
      expect(find.byType(Tooltip), findsNothing);
    },
  );

  testWidgets('everyone else wears none', (tester) async {
    await _pump(tester, const Member('@x', 'Pat', _avatar));
    expect(find.byType(Image), findsNothing);
  });

  test('copyWith keeps the bridge', () {
    const lou = Member('@x', 'lou', _avatar, bridge: Bridge.discord);
    expect(lou.copyWith(name: 'louis').bridge, Bridge.discord);
    expect(lou.copyWith(statusMessage: 'afk').bridge, Bridge.discord);
  });
}
