import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/channel/attach.dart';
import 'package:loaf_native/ui/channel/composer.dart';
import 'package:loaf_native/ui/channel/timeline_controller.dart';
import 'package:loaf_native/ui/mock/fixtures.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

const _channel = MethodChannel('moe.loaf.chat/media');

/// Answers the plugin's clipboard calls, and records them.
List<String> _plugin(
  WidgetTester tester, {
  List<String> files = const [],
  Uint8List? image,
}) {
  final calls = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (
    call,
  ) async {
    calls.add(call.method);
    return switch (call.method) {
      'clipboard.has' => files.isNotEmpty || image != null,
      'clipboard.files' => files,
      'clipboard.image' => image,
      _ => null,
    };
  });
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _channel,
      null,
    ),
  );
  return calls;
}

void main() {
  final png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]);

  // Every platform with a plugin to read the clipboard with.
  final plugged = TargetPlatformVariant({
    TargetPlatform.linux,
    TargetPlatform.macOS,
    TargetPlatform.iOS,
  });

  testWidgets('a picture is a PNG with a name of its own', (tester) async {
    _plugin(tester, image: png);
    final pasted = await pastedAttachments();
    expect(pasted, hasLength(1));
    expect(pasted.single.name, matches(r'^pasted-\d{4}-\d\d-\d\d-\d{6}\.png$'));
    expect(pasted.single.mimeType, 'image/png');
    expect(await pasted.single.readAsBytes(), png);
  }, variant: plugged);

  testWidgets('copied files win over their icon', (tester) async {
    _plugin(tester, files: ['/home/me/crumb.jpg'], image: png);
    final pasted = await pastedAttachments();
    expect(pasted.map((f) => f.path), ['/home/me/crumb.jpg']);
  }, variant: plugged);

  testWidgets('text alone is no attachment', (tester) async {
    _plugin(tester);
    expect(await pastedAttachments(), isEmpty);
    expect(await hasPastedAttachments(), isFalse);
  }, variant: plugged);

  testWidgets('where there is no plugin, the clipboard is never asked', (
    tester,
  ) async {
    final calls = _plugin(tester, image: png);
    expect(await pastedAttachments(), isEmpty);
    expect(await hasPastedAttachments(), isFalse);
    expect(calls, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('a clipboard that cannot be read is a paste of text', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _channel,
      (_) async => throw PlatformException(code: 'boom'),
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _channel,
        null,
      ),
    );
    expect(await pastedAttachments(), isEmpty);
    expect(await hasPastedAttachments(), isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  group('the paste menu', () {
    final question = Message(
      id: 'q',
      author: mockMembers[1],
      sentAt: DateTime.utc(2026),
      body: 'got a photo of the crumb?',
    );

    Future<TimelineController> pump(
      WidgetTester tester, {
      required bool has,
    }) async {
      final timeline = TimelineController([question], you: currentUser);
      addTearDown(timeline.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: loafDarkTheme(),
          home: Scaffold(
            body: Composer(
              channelName: 'general',
              timeline: timeline,
              hasPasteFiles: () async => has,
              pasteFiles: () async => [
                XFile.fromData(
                  utf8.encode('crumb'),
                  path:
                      '${Platform.pathSeparator}pasted${Platform.pathSeparator}crumb.png',
                  mimeType: 'image/png',
                ),
              ],
            ),
          ),
        ),
      );
      // Focusing the field is when the clipboard is looked at.
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      return timeline;
    }

    testWidgets('offers Paste for files alone, and sends them', (tester) async {
      final timeline = await pump(tester, has: true);
      await tester.longPress(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(find.text('Paste'), findsOneWidget);

      await tester.tap(find.text('Paste'));
      await tester.pumpAndSettle();
      expect(timeline.messages.skip(1).map((m) => m.media?.name), [
        'crumb.png',
      ]);
    });

    testWidgets('offers none when there is nothing to paste', (tester) async {
      await pump(tester, has: false);
      await tester.longPress(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(find.text('Paste'), findsNothing);
    });
  });
}
