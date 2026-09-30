import 'dart:convert';

import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:loaf_native/ui/channel/composer.dart';
import 'package:loaf_native/ui/channel/timeline_controller.dart';
import 'package:loaf_native/ui/mock/fixtures.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

Future<void> _pump(WidgetTester tester, double textScale) async {
  tester.view.physicalSize = const Size(800, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: loafDarkTheme(),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: const Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: Composer(channelName: 'general'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // iOS Text Size shrinks or grows everything; the typed line has to stay on
  // the buttons' centreline either way, not just at the default size.
  for (final scale in [0.82, 1.0, 1.3]) {
    testWidgets('a single line sits on the controls\' centreline at '
        'text scale $scale', (tester) async {
      await _pump(tester, scale);

      final field = tester.getCenter(find.byType(EditableText));
      final plus = tester.getCenter(find.byIcon(LucideIcons.plus));
      expect(field.dy, moreOrLessEquals(plus.dy, epsilon: 0.5));
    });
  }

  testWidgets('a DM\'s placeholder names the person, not a channel', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: loafDarkTheme(),
        home: const Scaffold(
          body: Composer(channelName: 'Mika Rye', prefix: '@'),
        ),
      ),
    );

    expect(find.text('Message @Mika Rye'), findsOneWidget);
  });

  group('attaching', () {
    final question = Message(
      id: 'q',
      author: mockMembers[1],
      sentAt: DateTime.utc(2026),
      body: 'got a photo of the crumb?',
    );

    Future<TimelineController> pumpWith(
      WidgetTester tester,
      Future<List<XFile>> Function() pick,
    ) async {
      final timeline = TimelineController([question], you: currentUser);
      addTearDown(timeline.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: loafDarkTheme(),
          home: Scaffold(
            body: Composer(
              channelName: 'general',
              timeline: timeline,
              pickFiles: (_) => pick(),
            ),
          ),
        ),
      );
      return timeline;
    }

    // Off the web a picked file's name is the last part of its path.
    XFile file(String name) => XFile.fromData(
      utf8.encode('crumb'),
      path: '/picked/$name',
      mimeType: 'image/jpeg',
    );

    testWidgets('the plus sends each picked file as its own message', (
      tester,
    ) async {
      final timeline = await pumpWith(
        tester,
        () async => [file('crumb.jpg'), file('crust.jpg')],
      );
      timeline.startReply(question);
      await tester.pump();

      await tester.tap(find.byTooltip('Attach files'));
      await tester.pumpAndSettle();

      final sent = timeline.messages.skip(1).toList();
      expect(sent.map((m) => m.body), ['📎 crumb.jpg', '📎 crust.jpg']);
      // The reply goes with the first, as it would with text.
      expect(sent.first.replyTo?.id, 'q');
      expect(sent.last.replyTo, isNull);
    });

    testWidgets('picking nothing sends nothing', (tester) async {
      final timeline = await pumpWith(tester, () async => []);
      await tester.tap(find.byTooltip('Attach files'));
      await tester.pumpAndSettle();
      expect(timeline.messages, hasLength(1));
    });

    testWidgets('an edit has nothing to attach to', (tester) async {
      final timeline = await pumpWith(tester, () async => []);
      final mine = Message(
        id: 'm',
        author: currentUser,
        sentAt: DateTime.utc(2026),
        body: 'my loaf',
      );
      timeline.startEdit(mine);
      await tester.pump();
      expect(find.byTooltip('Attach files'), findsNothing);
      timeline.clearTarget();
      await tester.pump();
      expect(find.byTooltip('Attach files'), findsOneWidget);
    });

    testWidgets('there is one way to attach, not two', (tester) async {
      await pumpWith(tester, () async => []);
      expect(find.byIcon(LucideIcons.paperclip), findsNothing);
    });
  });
}
