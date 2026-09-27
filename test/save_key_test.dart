import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/mock/mock_verifier.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/verify/verification_controller.dart';
import 'package:loaf_native/ui/verify/verify_panel.dart';
import 'package:loaf_native/ui/verify/verify_state.dart';
import 'package:loaf_native/ui/widgets/loaf_button.dart';

/// "save as file" counts the key as kept only once it went somewhere. On a
/// computer, where the button says so; a phone's "share" runs the same way.
Future<VerificationController> _showKey(
  WidgetTester tester,
  Future<bool> Function(String key) save,
) async {
  final c = VerificationController(
    purpose: VerifyPurpose.setUp,
    verifier: MockVerifier(identityExists: () => false),
    onTrusted: () {},
  )..createKey();
  addTearDown(c.dispose);
  await tester.pump(MockVerifier.keyCheckDelay);
  await tester.pumpWidget(
    MaterialApp(
      theme: loafDarkTheme(),
      home: Scaffold(
        body: VerifyPanel(
          controller: c,
          saveKey: (key, {Rect? origin}) => save(key),
        ),
      ),
    ),
  );
  return c;
}

bool _canFinish(WidgetTester tester) =>
    tester
        .widget<LoafButton>(find.widgetWithText(LoafButton, "i've saved it"))
        .onTap !=
    null;

final _desktop = TargetPlatformVariant.only(TargetPlatform.macOS);

void main() {
  testWidgets('a save put away keeps nothing', variant: _desktop, (
    tester,
  ) async {
    final c = await _showKey(tester, (_) async => false);
    await tester.tap(find.text('save as file'));
    await tester.pump();
    expect(c.state.keySaved, isFalse);
    expect(_canFinish(tester), isFalse);
  });

  testWidgets('a save that went somewhere keeps the key', variant: _desktop, (
    tester,
  ) async {
    String? saved;
    final c = await _showKey(tester, (key) async {
      saved = key;
      return true;
    });
    await tester.tap(find.text('save as file'));
    await tester.pump();
    expect(saved, c.newRecoveryKey);
    expect(c.state.keySaved, isTrue);
    expect(_canFinish(tester), isTrue);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets(
    'a save that failed says so and keeps nothing',
    variant: _desktop,
    (tester) async {
      final c = await _showKey(
        tester,
        (_) async => throw Exception('disk full'),
      );
      await tester.tap(find.text('save as file'));
      await tester.pump();
      expect(find.text("couldn't save it · copy it instead"), findsOneWidget);
      expect(c.state.keySaved, isFalse);
      await tester.pump(const Duration(seconds: 3));
    },
  );
}
