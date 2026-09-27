import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/mock/mock_verifier.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/verify/verification_controller.dart';
import 'package:loaf_native/ui/verify/verify_panel.dart';
import 'package:loaf_native/ui/verify/verify_state.dart';
import 'package:loaf_native/ui/widgets/loaf_button.dart';

/// The panel's faces for what the real server does: not answer, take its
/// time, ask again, stop part way.
Future<VerificationController> _show(
  WidgetTester tester,
  VerifyState state, {
  VerifyPurpose purpose = VerifyPurpose.verify,
}) async {
  final c = VerificationController.at(
    state,
    purpose: purpose,
    verifier: MockVerifier(),
    server: 'loaf.moe',
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: loafDarkTheme(),
      home: Scaffold(body: VerifyPanel(controller: c)),
    ),
  );
  return c;
}

LoafButton _button(WidgetTester tester, String label) =>
    tester.widget<LoafButton>(find.widgetWithText(LoafButton, label));

void main() {
  testWidgets('a key the server never saw is not called wrong', (tester) async {
    await _show(
      tester,
      const VerifyState(step: VerifyStep.recoveryKey, failed: true),
    );
    expect(find.text("couldn't reach loaf.moe · try again"), findsOneWidget);
    expect(find.text("that didn't unlock anything"), findsNothing);
  });

  testWidgets('creating a key is busy, and cannot be pressed twice', (
    tester,
  ) async {
    await _show(
      tester,
      const VerifyState(step: VerifyStep.setUpIntro, checking: true),
      purpose: VerifyPurpose.setUp,
    );
    expect(_button(tester, 'creating…').onTap, isNull);
  });

  testWidgets('a failed set up says nothing changed and offers it again', (
    tester,
  ) async {
    await _show(
      tester,
      const VerifyState(step: VerifyStep.setUpIntro, failed: true),
      purpose: VerifyPurpose.setUp,
    );
    expect(find.text("couldn't reach loaf.moe · try again"), findsOneWidget);
    expect(_button(tester, 'create my recovery key').onTap, isNotNull);
  });

  testWidgets('a reset waiting for the server offers no cancel', (
    tester,
  ) async {
    await _show(
      tester,
      const VerifyState(step: VerifyStep.resetConfirm, checking: true),
    );
    expect(_button(tester, 'starting…').onTap, isNull);
    expect(_button(tester, 'cancel').onTap, isNull);
  });

  testWidgets('a browser visit that did not finish says so', (tester) async {
    await _show(
      tester,
      const VerifyState(step: VerifyStep.resetAuth, rejected: true),
    );
    expect(find.text("that didn't finish · try again"), findsOneWidget);
    expect(find.text('continue with loaf.moe'), findsOneWidget);
  });

  testWidgets('setting up asks who you are in its own words', (tester) async {
    await _show(
      tester,
      const VerifyState(step: VerifyStep.resetAuth),
      purpose: VerifyPurpose.setUp,
    );
    expect(find.text('set up recovery'), findsOneWidget);
    expect(
      find.text("confirm it's you before your new identity goes up."),
      findsOneWidget,
    );
  });

  testWidgets('vouching asks for the key as the new sign-in', (tester) async {
    await _show(
      tester,
      const VerifyState(step: VerifyStep.recoveryKey),
      purpose: VerifyPurpose.incoming,
    );
    expect(find.text('new sign-in'), findsOneWidget);
    expect(find.textContaining('to vouch for it'), findsOneWidget);
    expect(find.byTooltip('back'), findsNothing);
  });

  testWidgets('history cut short says the rest are on their way', (
    tester,
  ) async {
    await _show(
      tester,
      const VerifyState(
        step: VerifyStep.done,
        failed: true,
        restored: 1204,
        totalKeys: 3380,
      ),
    );
    expect(find.text('this session is verified'), findsOneWidget);
    expect(
      find.text('restored 1,204 of 3,380 · the rest arrive as you open rooms'),
      findsOneWidget,
    );
  });
}
