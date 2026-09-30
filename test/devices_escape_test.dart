import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/mock/mock_devices.dart';
import 'package:loaf_native/ui/settings/devices.dart';
import 'package:loaf_native/ui/settings/devices_section.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

class _Recording extends MockDevices {
  final renames = <String>[];
  Completer<void>? hold;

  @override
  Future<void> rename(String id, String name) async {
    renames.add(name);
    await hold?.future;
    await super.rename(id, name);
  }
}

Future<void> _openRename(WidgetTester tester, Devices devices) async {
  tester.view.physicalSize = const Size(1000, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  // A whole MaterialApp, so the default text-editing shortcuts are present
  // as they are in the app.
  await tester.pumpWidget(
    MaterialApp(
      theme: loafLightTheme(),
      home: Scaffold(body: DevicesSection(devices: devices)),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('element on phone'));
  await tester.pumpAndSettle();
  expect(find.byType(TextField), findsOneWidget);
  await tester.enterText(find.byType(TextField), 'kitchen tablet');
}

/// macOS also delivers Escape to the focused field as the selector
/// `cancelOperation:`, which EditableText turns into a DismissIntent.
void _cancelOperation(WidgetTester tester) => tester
    .state<EditableTextState>(
      find.descendant(
        of: find.byType(TextField),
        matching: find.byType(EditableText),
      ),
    )
    .performSelector('cancelOperation:');

void main() {
  final macOS = TargetPlatformVariant.only(TargetPlatform.macOS);

  testWidgets('Escape key leaves the inline rename unsaved', variant: macOS, (
    tester,
  ) async {
    final devices = _Recording();
    await _openRename(tester, devices);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('element on phone'), findsOneWidget);
    expect(devices.renames, isEmpty);
  });

  testWidgets(
    'the field\'s cancelOperation: leaves it unsaved too',
    variant: macOS,
    (tester) async {
      final devices = _Recording();
      await _openRename(tester, devices);
      _cancelOperation(tester);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.text('element on phone'), findsOneWidget);
      expect(devices.renames, isEmpty);
    },
  );

  testWidgets(
    'Escape does nothing while the save is on its way',
    variant: macOS,
    (tester) async {
      final devices = _Recording()..hold = Completer<void>();
      await _openRename(tester, devices);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(devices.renames, ['kitchen tablet']);

      _cancelOperation(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget);

      devices.hold!.complete();
      await tester.pump(MockDevices.answerDelay);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.text('kitchen tablet'), findsOneWidget);
    },
  );
}
