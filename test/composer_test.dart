import 'dart:convert';

import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
      expect(sent.map((m) => m.media?.name), ['crumb.jpg', 'crust.jpg']);
      // The reply goes with the first, as it would with text.
      expect(sent.first.replyTo?.id, 'q');
      expect(sent.last.replyTo, isNull);
    });

    testWidgets(
      'a file over the upload limit is refused before it is read, and says why',
      (tester) async {
        final timeline = TimelineController(
          [question],
          you: currentUser,
          uploadLimit: 20000000,
        );
        addTearDown(timeline.dispose);
        final video = _Unreadable('/picked/IMG_0612.MOV', 174325941);
        await tester.pumpWidget(
          MaterialApp(
            theme: loafDarkTheme(),
            home: Scaffold(
              body: Composer(
                channelName: 'general',
                timeline: timeline,
                pickFiles: (_) async => [video, file('crumb.jpg')],
              ),
            ),
          ),
        );

        await tester.tap(find.byTooltip('Attach files'));
        await tester.pump();
        await tester.pump();

        expect(
          find.text("IMG_0612.MOV is 174.3 MB, over this server's 20 MB limit"),
          findsOneWidget,
        );
        expect(video.read, isFalse, reason: 'never read into memory');
        // The others still go.
        expect(timeline.messages.skip(1).map((m) => m.media?.name), [
          'crumb.jpg',
        ]);
        await tester.pumpAndSettle();
      },
    );

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

    group('pasting', () {
      Future<TimelineController> pumpPaste(
        WidgetTester tester,
        Future<List<XFile>> Function() paste,
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
                pasteFiles: paste,
              ),
            ),
          ),
        );
        await tester.tap(find.byType(TextField));
        await tester.pump();
        return timeline;
      }

      Future<void> ctrlV(WidgetTester tester) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
      }

      testWidgets('a picture on the clipboard is sent as an image', (
        tester,
      ) async {
        final timeline = await pumpPaste(
          tester,
          () async => [file('pasted.png')],
        );
        await ctrlV(tester);
        expect(timeline.messages.skip(1).map((m) => m.media?.name), [
          'pasted.png',
        ]);
      });

      testWidgets('with nothing but text on it, the field pastes the text', (
        tester,
      ) async {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => call.method == 'Clipboard.getData'
              ? <String, Object?>{'text': 'a loaf'}
              : null,
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        final timeline = await pumpPaste(tester, () async => []);
        await ctrlV(tester);
        expect(find.text('a loaf'), findsOneWidget);
        expect(timeline.messages, hasLength(1));
      });
    });

    testWidgets('there is one way to attach, not two', (tester) async {
      await pumpWith(tester, () async => []);
      expect(find.byIcon(LucideIcons.paperclip), findsNothing);
    });
  });

  group('shortcodes', () {
    final desktop = TargetPlatformVariant.only(TargetPlatform.macOS);
    final mobile = TargetPlatformVariant.only(TargetPlatform.iOS);
    final suggestions = find.byKey(const ValueKey('shortcode-suggestions'));

    Future<TimelineController> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final timeline = TimelineController(const [], you: currentUser);
      addTearDown(timeline.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: loafDarkTheme(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: Composer(channelName: 'general', timeline: timeline),
            ),
          ),
        ),
      );
      return timeline;
    }

    Future<void> type(WidgetTester tester, String text) async {
      await tester.showKeyboard(find.byType(TextField));
      await tester.enterText(find.byType(TextField), text);
      await tester.pumpAndSettle();
    }

    String field(WidgetTester tester) =>
        tester.widget<TextField>(find.byType(TextField)).controller!.text;

    /// The emoji a suggestion row offers, top to bottom.
    List<String> offered(WidgetTester tester) => tester
        .widgetList<Text>(
          find.descendant(of: suggestions, matching: find.byType(Text)),
        )
        .map((t) => t.data!)
        .where((t) => !t.startsWith(':'))
        .toList();

    testWidgets('a colon and two letters offers matching emoji', (
      tester,
    ) async {
      await pump(tester);
      await type(tester, 'hi :s');
      expect(suggestions, findsNothing);
      await type(tester, 'hi :smil');
      expect(suggestions, findsOneWidget);
      expect(offered(tester).first, '😄');
      expect(find.text(':smile:'), findsOneWidget);
    });

    testWidgets('a closed shortcode, or none at all, offers nothing', (
      tester,
    ) async {
      await pump(tester);
      await type(tester, 'hi :smile: there');
      expect(suggestions, findsNothing);
      await type(tester, 'at 12:30');
      expect(suggestions, findsNothing);
    });

    testWidgets(
      'tapping a suggestion puts its emoji in place',
      variant: mobile,
      (tester) async {
        await pump(tester);
        await type(tester, 'hi :smil');
        await tester.tap(find.text(':smile:'));
        await tester.pumpAndSettle();
        expect(field(tester), 'hi 😄');
        expect(suggestions, findsNothing);
      },
    );

    testWidgets(
      'arrows move, Enter takes, and nothing is sent',
      variant: desktop,
      (tester) async {
        final timeline = await pump(tester);
        await type(tester, 'hi :smil');
        final second = offered(tester)[1];

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();

        expect(field(tester), 'hi $second');
        expect(timeline.messages, isEmpty);
        expect(suggestions, findsNothing);

        // With nothing suggested, Enter sends again.
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(timeline.messages.single.body, 'hi $second');
      },
    );

    testWidgets('Tab takes the first', variant: desktop, (tester) async {
      await pump(tester);
      await type(tester, ':thumbsu');
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(field(tester), '👍');
    });

    testWidgets(
      'Escape puts them away until the next shortcode',
      variant: desktop,
      (tester) async {
        await pump(tester);
        await type(tester, ':smil');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(suggestions, findsNothing);

        await type(tester, ':smile');
        expect(suggestions, findsNothing, reason: 'still the same one');

        await type(tester, ':smile :hear');
        expect(suggestions, findsOneWidget);
      },
    );

    testWidgets('a complete shortcode goes as its emoji', (tester) async {
      final timeline = await pump(tester);
      await type(tester, 'fresh :bread: and `:bread:` :notathing:');
      await tester.tap(find.byIcon(LucideIcons.send));
      await tester.pumpAndSettle();
      expect(
        timeline.messages.single.body,
        'fresh 🍞 and `:bread:` :notathing:',
      );
    });
  });
}

/// A picked file that knows its size and records whether it was read.
class _Unreadable extends XFile {
  _Unreadable(super.path, this._length);

  final int _length;
  var read = false;

  @override
  Future<int> length() async => _length;

  @override
  Future<Uint8List> readAsBytes() {
    read = true;
    throw StateError('read whole');
  }

  @override
  Stream<Uint8List> openRead([int? start, int? end]) {
    read = true;
    throw StateError('read');
  }
}
