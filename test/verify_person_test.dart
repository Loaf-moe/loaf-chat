import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/members/member_list.dart';
import 'package:loaf_native/ui/members/person_card.dart';
import 'package:loaf_native/ui/mock/mock_session.dart';
import 'package:loaf_native/ui/mock/mock_verifier.dart';
import 'package:loaf_native/ui/model/models.dart';
import 'package:loaf_native/ui/shell/app_shell.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/verify/verification_controller.dart';
import 'package:loaf_native/ui/verify/verifier.dart';
import 'package:loaf_native/ui/verify/verify_panel.dart';

/// Someone's card from the member list, and verifying them from it — or
/// answering when they ask.
void main() {
  final desktop = TargetPlatformVariant.only(TargetPlatform.macOS);

  Future<MockSession> pumpShell(
    WidgetTester tester, {
    DeviceTrust trust = DeviceTrust.verified,
  }) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final session = MockSession(trust: trust);
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: loafDarkTheme(),
        home: AppShell(session: session),
      ),
    );
    await tester.pumpAndSettle();
    return session;
  }

  Finder row(String id) => find.descendant(
    of: find.byType(MemberList),
    matching: find.byKey(ValueKey('member-$id')),
  );

  Future<void> openCard(WidgetTester tester, String id) async {
    await tester.tap(row(id));
    await tester.pumpAndSettle();
  }

  testWidgets('a card names them and offers to verify', variant: desktop, (
    tester,
  ) async {
    await pumpShell(tester);
    await openCard(tester, '@mika');

    expect(find.byType(PersonCard), findsOneWidget);
    expect(find.text('@mika'), findsOneWidget);
    expect(find.byKey(const ValueKey('trust-unverified')), findsOneWidget);
    expect(find.text('verify'), findsOneWidget);
  });

  testWidgets(
    'an unverified session cannot vouch, and says why',
    variant: desktop,
    (tester) async {
      await pumpShell(tester, trust: DeviceTrust.unverified);
      await openCard(tester, '@mika');

      expect(find.textContaining('verify this session first'), findsOneWidget);
      await tester.tap(find.text('verify'));
      await tester.pumpAndSettle();
      expect(find.byType(VerifyPanel), findsNothing);
      expect(find.byType(PersonCard), findsOneWidget);
    },
  );

  testWidgets('your own card has nothing to verify', variant: desktop, (
    tester,
  ) async {
    await pumpShell(tester);
    await openCard(tester, '@faore');

    expect(find.byType(PersonCard), findsOneWidget);
    expect(find.text('verify'), findsNothing);
    expect(find.textContaining('verified'), findsNothing);
  });

  testWidgets('someone already verified says so', variant: desktop, (
    tester,
  ) async {
    await pumpShell(tester);
    await openCard(tester, '@sam');

    expect(find.byKey(const ValueKey('trust-verified')), findsOneWidget);
    expect(find.text('verify'), findsNothing);
  });

  testWidgets(
    'verify runs the emoji, then their card reads verified',
    variant: desktop,
    (tester) async {
      await pumpShell(tester);
      await openCard(tester, '@mika');
      await tester.tap(find.text('verify'));
      // Not settled: the wait's spinner would run the clock past the answer.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(PersonCard), findsNothing);
      expect(find.text('verify Mika Rye'), findsOneWidget);
      expect(
        find.textContaining('waiting for Mika Rye to accept'),
        findsOneWidget,
      );

      await tester.pump(MockVerifier.acceptDelay);
      await tester.pump();
      expect(
        find.text("do these match what's on Mika Rye's screen?"),
        findsOneWidget,
      );
      await tester.tap(find.text('they match'));
      await tester.pump(MockVerifier.confirmDelay);
      await tester.pump();
      expect(find.text('Mika Rye is verified'), findsOneWidget);

      // Done lingers to be read, then the panel goes and a toast says it.
      await tester.pump(VerificationController.doneLinger);
      await tester.pumpAndSettle();
      expect(find.byType(VerifyPanel), findsNothing);
      expect(find.text('Mika Rye is verified'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      await openCard(tester, '@mika');
      expect(find.byKey(const ValueKey('trust-verified')), findsOneWidget);
    },
  );

  testWidgets(
    'their request pops up, and "not now" just puts it away',
    variant: desktop,
    (tester) async {
      final session = await pumpShell(tester);
      session.receivePersonRequest();
      await tester.pumpAndSettle();

      expect(find.text('Mika Rye wants to verify you'), findsOneWidget);
      await tester.tap(find.text('not now'));
      await tester.pumpAndSettle();

      expect(find.byType(VerifyPanel), findsNothing);
      expect(
        find.textContaining('someone may be signed in as you'),
        findsNothing,
      );
      expect(session.incoming, isNull);
    },
  );

  testWidgets('their request, answered, verifies them', variant: desktop, (
    tester,
  ) async {
    final session = await pumpShell(tester);
    session.receivePersonRequest();
    await tester.pumpAndSettle();

    await tester.tap(find.text('verify'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('they match'));
    await tester.pump(MockVerifier.confirmDelay);
    await tester.pump();
    expect(find.text('Mika Rye is verified'), findsOneWidget);

    await tester.pump(VerificationController.doneLinger);
    await tester.pumpAndSettle();
    expect(find.byType(VerifyPanel), findsNothing);
    expect(session.incoming, isNull);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    await openCard(tester, '@mika');
    expect(find.byKey(const ValueKey('trust-verified')), findsOneWidget);
  });

  testWidgets('someone with no identity has nothing to verify', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: loafDarkTheme(),
        home: const Scaffold(
          body: PersonCard(
            member: Member('@tuwunel', 'tuwunel', Color(0xFF64748B)),
            trust: PersonTrust.noIdentity,
            isYou: false,
            canVerify: true,
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('trust-noIdentity')), findsOneWidget);
    expect(find.text('verify'), findsNothing);
  });

  testWidgets('rows stay plain where there is no card to open', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: loafDarkTheme(),
        home: const Scaffold(
          body: MemberList(
            members: [Member('@mika', 'Mika Rye', Color(0xFF4E9E76))],
          ),
        ),
      ),
    );
    expect(find.byType(InkWell), findsNothing);
  });
}
