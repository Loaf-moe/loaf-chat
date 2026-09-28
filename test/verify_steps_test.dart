import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:loaf_native/ui/mock/accounts.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/verify/incoming_verification.dart';
import 'package:loaf_native/ui/verify/recovery_setup.dart';
import 'package:loaf_native/ui/verify/reset_identity.dart';
import 'package:loaf_native/ui/verify/verify_steps.dart';
import 'package:loaf_native/ui/widgets/loaf_button.dart';

/// Steps render inside a panel about 440 wide on a computer and full width on
/// a phone; both are checked. Spinners never settle, so this pumps a fixed
/// time.
Future<void> _pump(
  WidgetTester tester,
  Widget step, {
  double width = 390,
}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: loafDarkTheme(),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: step,
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

void _noop() {}

void main() {
  final key = TextEditingController();
  final password = TextEditingController();
  tearDownAll(() {
    key.dispose();
    password.dispose();
  });

  final steps = <String, Widget>{
    'choose': const ChooseStep(
      otherSessions: ["faore's MacBook", 'Element on Pixel'],
      onDevice: _noop,
      onRecoveryKey: _noop,
      onNeither: _noop,
    ),
    'waiting': const WaitingStep(
      label: 'waiting for the other device to confirm',
      onCancel: _noop,
    ),
    'compare': const CompareStep(
      emoji: mockSasEmoji,
      prompt: 'do these match?',
      onMatch: _noop,
      onMismatch: _noop,
    ),
    'cancelled': const CancelledStep(onTryAgain: _noop, onClose: _noop),
    'recovery': RecoveryStep(
      controller: key,
      checking: false,
      rejected: true,
      onSubmit: _noop,
    ),
    'restoring': const RestoringStep(restored: 1204, total: 3380),
    'done': const DoneStep(message: 'this session is verified'),
    'reset confirm': const ResetConfirmStep(onReset: _noop, onCancel: _noop),
    'reset password': ResetAuthStep(
      byPassword: true,
      password: password,
      checking: false,
      rejected: true,
      inBrowser: false,
      providerName: 'loaf.moe',
      onPassword: _noop,
      onSso: _noop,
      onReopen: _noop,
      onCancelBrowser: _noop,
    ),
    'reset browser': ResetAuthStep(
      byPassword: false,
      password: password,
      checking: false,
      rejected: false,
      inBrowser: true,
      providerName: 'loaf.moe',
      onPassword: _noop,
      onSso: _noop,
      onReopen: _noop,
      onCancelBrowser: _noop,
    ),
    'set up intro': const SetUpIntroStep(onCreate: _noop),
    'show key': const ShowKeyStep(
      recoveryKey: mockNewRecoveryKey,
      saved: false,
      onCopy: _noop,
      onSave: _noop,
      onDone: _noop,
    ),
    'incoming': const IncomingPromptStep(
      device: 'loaf on iPhone',
      onYes: _noop,
      onNotMe: _noop,
    ),
    'not me': const NotMeStep(onClose: _noop),
  };
  for (final MapEntry(key: name, value: step) in steps.entries) {
    for (final width in [390.0, 440.0]) {
      testWidgets('$name lays out at ${width.toInt()} wide', (tester) async {
        await _pump(tester, step, width: width);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
    'the device route is offered only when there is a device to ask',
    (tester) async {
      await _pump(
        tester,
        const ChooseStep(
          otherSessions: [],
          onDevice: _noop,
          onRecoveryKey: _noop,
          onNeither: _noop,
        ),
      );
      expect(find.text('use another device'), findsNothing);
      expect(find.text('use your recovery key'), findsOneWidget);
    },
  );

  testWidgets('other sessions are listed under the device route', (
    tester,
  ) async {
    await _pump(tester, steps['choose']!);
    expect(find.text("faore's MacBook · Element on Pixel"), findsOneWidget);
  });

  testWidgets("i've saved it waits for a copy or a save", (tester) async {
    await _pump(tester, steps['show key']!);
    expect(
      tester
          .widget<LoafButton>(find.widgetWithText(LoafButton, "i've saved it"))
          .onTap,
      isNull,
    );

    await _pump(
      tester,
      const ShowKeyStep(
        recoveryKey: mockNewRecoveryKey,
        saved: true,
        onCopy: _noop,
        onSave: _noop,
        onDone: _noop,
      ),
    );
    expect(
      tester
          .widget<LoafButton>(find.widgetWithText(LoafButton, "i've saved it"))
          .onTap,
      isNotNull,
    );
  });

  testWidgets(
    'on a phone the key is shared, not saved as a file',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      await _pump(tester, steps['show key']!);
      expect(find.text('save as file'), findsNothing);
      final share = tester.widget<LoafButton>(
        find.widgetWithText(LoafButton, 'share'),
      );
      expect(share.icon, LucideIcons.share);
    },
  );

  testWidgets(
    'on a computer the key is saved as a file',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      await _pump(tester, steps['show key']!);
      expect(find.text('share'), findsNothing);
      final save = tester.widget<LoafButton>(
        find.widgetWithText(LoafButton, 'save as file'),
      );
      expect(save.icon, LucideIcons.download);
    },
  );

  testWidgets('restoring counts with thousands separators', (tester) async {
    await _pump(tester, steps['restoring']!);
    expect(find.text('restored 1,204 of 3,380 keys'), findsOneWidget);
  });

  testWidgets('reset spends the accent on its destructive button', (
    tester,
  ) async {
    await _pump(tester, steps['reset confirm']!);
    final reset = tester.widget<LoafButton>(
      find.widgetWithText(LoafButton, 'reset my identity'),
    );
    expect(reset.emphasis, LoafButtonEmphasis.filled);
  });

  testWidgets('a wrong key says so', (tester) async {
    await _pump(tester, steps['recovery']!);
    expect(find.text("that didn't unlock anything"), findsOneWidget);
  });

  testWidgets('unlock does nothing on an empty key, then lights up as typed', (
    tester,
  ) async {
    final empty = TextEditingController();
    addTearDown(empty.dispose);
    await _pump(
      tester,
      RecoveryStep(
        controller: empty,
        checking: false,
        rejected: false,
        onSubmit: _noop,
      ),
    );
    expect(
      tester
          .widget<LoafButton>(find.widgetWithText(LoafButton, 'unlock'))
          .onTap,
      isNull,
    );

    await tester.enterText(find.byType(TextField), 'a recovery key');
    await tester.pump();
    expect(
      tester
          .widget<LoafButton>(find.widgetWithText(LoafButton, 'unlock'))
          .onTap,
      isNotNull,
    );
  });

  testWidgets(
    'continue does nothing on an empty password, then lights up as typed',
    (tester) async {
      final empty = TextEditingController();
      addTearDown(empty.dispose);
      await _pump(
        tester,
        ResetAuthStep(
          byPassword: true,
          password: empty,
          checking: false,
          rejected: false,
          inBrowser: false,
          providerName: 'loaf.moe',
          onPassword: _noop,
          onSso: _noop,
          onReopen: _noop,
          onCancelBrowser: _noop,
        ),
      );
      expect(
        tester
            .widget<LoafButton>(find.widgetWithText(LoafButton, 'continue'))
            .onTap,
        isNull,
      );

      await tester.enterText(find.byType(TextField), 'hunter2');
      await tester.pump();
      expect(
        tester
            .widget<LoafButton>(find.widgetWithText(LoafButton, 'continue'))
            .onTap,
        isNotNull,
      );
    },
  );

  test('thousands', () {
    expect(thousands(0), '0');
    expect(thousands(999), '999');
    expect(thousands(1204), '1,204');
    expect(thousands(1234567), '1,234,567');
  });
}
