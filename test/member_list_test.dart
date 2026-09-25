import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/members/member_list.dart';
import 'package:loaf_native/ui/members/presence.dart';
import 'package:loaf_native/ui/members/presence_dot.dart';
import 'package:loaf_native/ui/members/role_colors.dart';
import 'package:loaf_native/ui/mock/fixtures.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

const _grey = Color(0xFF888888);

const _admin = Member('@a', 'zed', _grey, powerLevel: 100);
const _awayAdmin = Member(
  '@b',
  'amy',
  _grey,
  powerLevel: 100,
  presence: Presence.offline,
);
const _mod = Member('@c', 'Mo', _grey, powerLevel: 50);
const _bea = Member('@d', 'bea', _grey);
const _cal = Member('@e', 'Cal', _grey);
const _away = Member('@f', 'abe', _grey, presence: Presence.offline);
const _idle = Member('@g', 'Ida', _grey, presence: Presence.idle);
const _dnd = Member('@h', 'Dot', _grey, presence: Presence.dnd);

void main() {
  group('Member.role', () {
    test('follows Matrix power level thresholds', () {
      expect(const Member('@x', 'x', _grey, powerLevel: 100).role, Role.admin);
      expect(const Member('@x', 'x', _grey, powerLevel: 150).role, Role.admin);
      expect(
        const Member('@x', 'x', _grey, powerLevel: 50).role,
        Role.moderator,
      );
      expect(
        const Member('@x', 'x', _grey, powerLevel: 99).role,
        Role.moderator,
      );
      expect(const Member('@x', 'x', _grey, powerLevel: 49).role, Role.member);
      expect(const Member('@x', 'x', _grey).role, Role.member);
    });
  });

  group('groupMembers', () {
    test('admins get their own section; moderators stay with members', () {
      final groups = groupMembers([_bea, _mod, _admin, _cal]);
      expect(groups.admins, [_admin]);
      expect(groups.members, containsAll([_mod, _bea, _cal]));
    });

    test('online first, then case-insensitive alphabetical', () {
      final groups = groupMembers([
        _away,
        _cal,
        _mod,
        _bea,
        _awayAdmin,
        _admin,
      ]);
      expect(groups.admins, [_admin, _awayAdmin]);
      expect(groups.members, [_bea, _cal, _mod, _away]);
    });
  });

  test('idle and do-not-disturb people sort with the online ones', () {
    final groups = groupMembers([_away, _dnd, _bea, _idle]);
    expect(groups.members, [_bea, _dnd, _idle, _away]);
  });

  test('invisible shows as offline', () {
    expect(PresenceChoice.invisible.shown, Presence.offline);
    expect(PresenceChoice.dnd.shown, Presence.dnd);
  });

  group('MemberList', () {
    Future<void> pump(WidgetTester tester, List<Member> members) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: loafDarkTheme(),
          home: Scaffold(body: MemberList(members: members)),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shows a counted section for admins and one for members', (
      tester,
    ) async {
      await pump(tester, [_admin, _mod, _bea, _away]);

      expect(find.text('ADMINS — 1'), findsOneWidget);
      expect(find.text('MEMBERS — 3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('leaves out the admins section when there are none', (
      tester,
    ) async {
      await pump(tester, [_bea, _cal]);

      expect(find.textContaining('ADMINS'), findsNothing);
      expect(find.text('MEMBERS — 2'), findsOneWidget);
    });

    testWidgets('a status message sits under the name', (tester) async {
      await pump(tester, [
        const Member('@s', 'Sam', _grey, statusMessage: 'proofing'),
      ]);
      final name = tester.getRect(find.text('Sam'));
      final status = tester.getRect(find.text('proofing'));
      expect(status.top, greaterThanOrEqualTo(name.bottom));
    });

    testWidgets('names are coloured by power level', (tester) async {
      await pump(tester, [_admin, _mod, _bea]);
      final tokens = loafDarkTheme().extension<LoafTokens>()!;

      Color? colorOf(String name) =>
          tester.widget<Text>(find.text(name)).style?.color;
      expect(colorOf('zed'), tokens.nameColor(Role.admin));
      expect(colorOf('Mo'), tokens.nameColor(Role.moderator));
      expect(colorOf('bea'), tokens.nameColor(Role.member));
      // Three roles, three distinct colours.
      expect({colorOf('zed'), colorOf('Mo'), colorOf('bea')}, hasLength(3));
    });
  });

  group('unknown presence', () {
    const unknown = Member('@u', 'Una', _grey, presence: Presence.unknown);

    test('sorts between people around and people away', () {
      final groups = groupMembers([_away, unknown, _bea]);

      expect(groups.members.map((m) => m.name), ['bea', 'Una', 'abe']);
    });

    testWidgets('draws no dot', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: loafDarkTheme(),
          home: Center(
            child: PresenceDot(presence: Presence.unknown, ring: _grey),
          ),
        ),
      );

      expect(
        tester.getSize(find.byKey(const ValueKey('presence-unknown'))),
        Size.zero,
      );
    });

    testWidgets("isn't faded like someone offline", (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: loafDarkTheme(),
          home: const Scaffold(body: MemberList(members: [unknown, _away])),
        ),
      );

      double opacityOf(String id) =>
          tester.widget<Opacity>(find.byKey(ValueKey('member-$id'))).opacity;
      expect(opacityOf('@u'), 1);
      expect(opacityOf('@f'), lessThan(1));
    });

    testWidgets('a server without presence hides every dot', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: loafDarkTheme(),
          home: const Scaffold(
            body: PresenceScope(
              shared: false,
              child: MemberList(members: [_bea, _away]),
            ),
          ),
        ),
      );

      for (final dot in find.byType(PresenceDot).evaluate()) {
        expect((dot.renderObject! as RenderBox).size, Size.zero);
      }
      expect(
        tester.widget<Opacity>(find.byKey(const ValueKey('member-@f'))).opacity,
        1,
        reason: 'nobody is known to be away',
      );
    });
  });
}
