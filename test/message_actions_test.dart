import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/channel/media_row.dart';
import 'package:loaf_native/ui/channel/message_actions.dart';
import 'package:loaf_native/ui/channel/message_group_tile.dart';
import 'package:loaf_native/ui/channel/timeline_controller.dart';
import 'package:loaf_native/ui/mock/fixtures.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

const _you = Member('@you', 'you', Colors.red);
const _them = Member('@them', 'them', Colors.blue);

Future<TimelineController> _pump(WidgetTester tester, Member author) async {
  tester.view.physicalSize = const Size(800, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final controller = TimelineController([
    Message(
      id: '1',
      author: author,
      sentAt: DateTime(2026, 9, 24, 10),
      body: 'fresh out of the oven',
    ),
  ], you: _you);
  addTearDown(controller.dispose);

  await tester.pumpWidget(
    MaterialApp(
      theme: loafDarkTheme(),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.only(top: 100),
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => controller.messages.isEmpty
                ? const SizedBox()
                : MessageGroupTile(
                    group: MessageGroup(controller.messages),
                    controller: controller,
                  ),
          ),
        ),
      ),
    ),
  );
  return controller;
}

final _body = find.text('fresh out of the oven');

// Touch idioms on mobile, pointer idioms on desktop — see "Message actions"
// in the design spec.
final _mobile = TargetPlatformVariant.only(TargetPlatform.iOS);
final _desktop = TargetPlatformVariant({
  TargetPlatform.macOS,
  TargetPlatform.linux,
  TargetPlatform.windows,
});

void _captureClipboard(WidgetTester tester, void Function(String?) onCopy) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        onCopy((call.arguments as Map)['text'] as String?);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
}

void main() {
  testWidgets('tapping a reaction joins it, and tapping again takes it back', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final controller = TimelineController([
      Message(
        id: '1',
        author: _them,
        sentAt: DateTime(2026, 9, 24, 10),
        body: 'look at this crumb',
        reactions: const [Reaction('🔥', 3)],
      ),
    ], you: _you);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: loafDarkTheme(),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => MessageGroupTile(
              group: MessageGroup(controller.messages),
              controller: controller,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('🔥 3'));
    await tester.pumpAndSettle();
    expect(find.text('🔥 4'), findsOneWidget);
    expect(controller.messages.single.reactions.single.mine, isTrue);

    await tester.tap(find.text('🔥 4'));
    await tester.pumpAndSettle();
    expect(find.text('🔥 3'), findsOneWidget);
  });

  group('touch', () {
    testWidgets('a long press opens the action sheet', variant: _mobile, (
      tester,
    ) async {
      await _pump(tester, _them);

      await tester.longPress(_body);
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Reply'), findsOneWidget);
      expect(find.text('Copy text'), findsOneWidget);
      expect(find.text('Edit'), findsNothing);
      expect(find.text('🥖'), findsOneWidget, reason: 'quick reactions row');
    });

    testWidgets(
      'a quick reaction from the sheet lands on the message',
      variant: _mobile,
      (tester) async {
        final controller = await _pump(tester, _them);

        await tester.longPress(_body);
        await tester.pumpAndSettle();
        await tester.tap(find.text('🥖'));
        await tester.pumpAndSettle();

        expect(find.byType(BottomSheet), findsNothing);
        final reaction = controller.messages.single.reactions.single;
        expect(
          (reaction.emoji, reaction.count, reaction.mine),
          ('🥖', 1, true),
        );
      },
    );

    testWidgets('copy puts the body on the clipboard', variant: _mobile, (
      tester,
    ) async {
      String? copied;
      _captureClipboard(tester, (text) => copied = text);
      await _pump(tester, _them);

      await tester.longPress(_body);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy text'));
      await tester.pumpAndSettle();

      expect(copied, 'fresh out of the oven');
      expect(find.text('copied'), findsOneWidget);
    });

    testWidgets(
      'delete asks first, and only then removes the message',
      variant: _mobile,
      (tester) async {
        final controller = await _pump(tester, _you);

        await tester.longPress(_body);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.tap(find.text('cancel'));
        await tester.pumpAndSettle();
        expect(controller.messages, hasLength(1), reason: 'cancel keeps it');

        await tester.longPress(_body);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('delete'));
        await tester.pumpAndSettle();
        expect(controller.messages, isEmpty);
      },
    );
  });

  group('pointer', () {
    testWidgets('hovering with a mouse shows the toolbar', variant: _desktop, (
      tester,
    ) async {
      await _pump(tester, _them);
      expect(find.byTooltip('Reply'), findsNothing);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(_body));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Reply'), findsOneWidget);
      expect(find.byTooltip('More'), findsOneWidget);

      await mouse.moveTo(const Offset(790, 890));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Reply'), findsNothing);
    });

    testWidgets(
      'after reacting from the toolbar\'s menu, leaving the message hides it',
      variant: _desktop,
      (tester) async {
        await _pump(tester, _them);

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(mouse.removePointer);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(tester.getCenter(_body));
        await tester.pumpAndSettle();
        // One mouse throughout, clicking where it points, as in the app.
        Future<void> click(Finder target) async {
          await mouse.moveTo(tester.getCenter(target));
          await tester.pump();
          await mouse.down(tester.getCenter(target));
          await mouse.up();
          await tester.pumpAndSettle();
        }

        await click(find.byTooltip('More'));
        await click(find.byTooltip('More reactions'));
        await click(find.byTooltip('grinning face'));
        expect(find.text('😀 1'), findsOneWidget);

        await mouse.moveTo(const Offset(790, 890));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Reply'), findsNothing);
        // And hovering it again shows one toolbar, not a stale one as well.
        await mouse.moveTo(tester.getCenter(_body));
        await tester.pumpAndSettle();
        await mouse.moveTo(const Offset(790, 890));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Reply'), findsNothing);
      },
    );

    testWidgets(
      'the toolbar sits on the message, not off the edge of the window',
      variant: _desktop,
      (tester) async {
        await _pump(tester, _them);

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(mouse.removePointer);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(tester.getCenter(_body));
        await tester.pumpAndSettle();

        final window = Offset.zero & const Size(800, 900);
        final message = tester.getRect(_body);
        final row = tester.getRect(find.byType(MessageGroupTile));
        final more = tester.getRect(find.byTooltip('More'));
        expect(window.contains(more.topLeft), isTrue);
        expect(window.contains(more.bottomRight), isTrue);
        // Straddles the message's top edge, at the row's right end, clear of
        // a short message's text.
        expect(more.top, lessThan(message.top));
        expect(more.bottom, greaterThan(message.top));
        expect(more.right, greaterThan(row.right - LoafSpace.x6));
        expect(more.right, lessThanOrEqualTo(row.right));
        expect(more.left, greaterThan(message.right));
      },
    );

    testWidgets(
      'right-click opens the same actions as a menu',
      variant: _desktop,
      (tester) async {
        await _pump(tester, _you);

        await tester.tap(_body, buttons: kSecondaryButton);
        await tester.pumpAndSettle();

        expect(find.byType(BottomSheet), findsNothing);
        for (final label in ['Reply', 'Copy text', 'Edit', 'Delete']) {
          expect(find.text(label), findsOneWidget, reason: label);
        }
        expect(find.text('🥖'), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('Copy text'), findsNothing);
      },
    );

    testWidgets('long press does nothing on a computer', variant: _desktop, (
      tester,
    ) async {
      await _pump(tester, _them);

      await tester.longPress(_body);
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('Reply'), findsNothing);
    });

    testWidgets('message text is selectable on a computer', variant: _desktop, (
      tester,
    ) async {
      await _pump(tester, _them);
      expect(find.byType(SelectionArea), findsOneWidget);
    });

    testWidgets(
      'right-clicking a selection offers to copy just that',
      variant: _desktop,
      (tester) async {
        String? copied;
        _captureClipboard(tester, (text) => copied = text);
        await _pump(tester, _them);

        // Drag across the start of the body with the mouse to select it.
        final box = tester.getRect(_body);
        final drag = await tester.startGesture(
          box.centerLeft + const Offset(1, 0),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        await drag.moveTo(box.center);
        await drag.up();
        await tester.pumpAndSettle();

        await tester.tap(_body, buttons: kSecondaryButton);
        await tester.pumpAndSettle();
        expect(find.text('Copy selection'), findsOneWidget);

        await tester.tap(find.text('Copy selection'));
        await tester.pumpAndSettle();
        expect(copied, isNotEmpty);
        expect('fresh out of the oven'.startsWith(copied!), isTrue);
        expect(copied!.length, lessThan('fresh out of the oven'.length));
      },
    );

    testWidgets(
      'without a selection there is no copy-selection item',
      variant: _desktop,
      (tester) async {
        await _pump(tester, _them);

        await tester.tap(_body, buttons: kSecondaryButton);
        await tester.pumpAndSettle();

        expect(find.text('Copy text'), findsOneWidget);
        expect(find.text('Copy selection'), findsNothing);
      },
    );
  });

  testWidgets(
    'phones never show the hover toolbar or selectable text',
    variant: _mobile,
    (tester) async {
      await _pump(tester, _them);
      expect(find.byType(SelectionArea), findsNothing);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(_body));
      await tester.pumpAndSettle();
      expect(find.byTooltip('More'), findsNothing);
    },
  );

  group('on media', () {
    Message captionless(MessageStatus status) => Message(
      id: 'q',
      author: _you,
      sentAt: DateTime(2026, 9, 24, 10),
      body: '',
      status: status,
      media: const Media(kind: MediaKind.image, name: 'oven.jpg', ref: 'x'),
    );

    test('a failed caption-less media message offers nothing to copy', () {
      expect(actionsFor(captionless(MessageStatus.failed), _you), isEmpty);
      expect(actionsFor(captionless(MessageStatus.sending), _you), isEmpty);
    });

    test('a media message in a read-only room still opens and saves', () {
      final actions = actionsFor(
        captionless(MessageStatus.sent),
        _you,
        writable: false,
      );
      expect(actions, contains(MessageAction.open));
      expect(
        actions,
        isNot(
          anyOf(contains(MessageAction.reply), contains(MessageAction.delete)),
        ),
      );
    });

    testWidgets(
      'in a read-only room, a phone opens and shares a picture',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        expect(
          actionsFor(captionless(MessageStatus.sent), _you, writable: false),
          [MessageAction.open, MessageAction.share],
        );
      },
    );

    testWidgets(
      'in a read-only room, a Mac opens and saves a picture',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        expect(
          actionsFor(captionless(MessageStatus.sent), _you, writable: false),
          [MessageAction.open, MessageAction.openWith, MessageAction.saveAs],
        );
      },
    );

    testWidgets(
      'on Windows a picture also names the app it would open in; a file, '
      'which Open already opens there, does not',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        expect(
          actionsFor(captionless(MessageStatus.sent), _you, writable: false),
          [MessageAction.open, MessageAction.openWith, MessageAction.saveAs],
        );
        final pdf = Message(
          id: 'p',
          author: _you,
          sentAt: DateTime(2026, 9, 24, 10),
          body: '',
          status: MessageStatus.sent,
          media: const Media(
            kind: MediaKind.file,
            name: 'recipe.pdf',
            ref: 'x',
          ),
        );
        expect(actionsFor(pdf, _you, writable: false), [
          MessageAction.open,
          MessageAction.saveAs,
        ]);
      },
    );

    test('a failed captioned one can still be copied', () {
      final m = Message(
        id: 'c',
        author: _you,
        sentAt: DateTime(2026, 9, 24, 10),
        body: 'first bake',
        status: MessageStatus.failed,
        media: captionless(MessageStatus.failed).media,
      );
      expect(actionsFor(m, _you), [MessageAction.copy]);
    });

    testWidgets('long-pressing a sending caption-less picture opens no sheet', (
      tester,
    ) async {
      final controller = TimelineController([
        captionless(MessageStatus.sending),
      ], you: _you);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: loafDarkTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showMessageActionsSheet(
                  context,
                  controller,
                  controller.messages.first,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('the pointer menu does not open with nothing in it', (
      tester,
    ) async {
      final controller = TimelineController([
        captionless(MessageStatus.sending),
      ], you: _you);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: loafDarkTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showMessageContextMenu(
                  context,
                  controller,
                  controller.messages.first,
                  const Offset(100, 100),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      final before = find.byType(ModalBarrier).evaluate().length;
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(ModalBarrier).evaluate().length, before);
    });

    final photo = Message(
      id: 'p',
      author: _you,
      sentAt: DateTime(2026, 9, 24, 10),
      body: '',
      media: const Media(kind: MediaKind.image, name: 'oven.jpg', ref: 'x'),
    );

    test('edit is not offered on media', () {
      expect(actionsFor(photo, _you), isNot(contains(MessageAction.edit)));
      expect(actionsFor(photo, _you), contains(MessageAction.delete));
    });

    test('copy is offered only when there are words', () {
      expect(actionsFor(photo, _you), isNot(contains(MessageAction.copy)));
      final captioned = Message(
        id: 'c',
        author: _you,
        sentAt: photo.sentAt,
        body: 'first bake',
        media: photo.media,
      );
      expect(actionsFor(captioned, _you), contains(MessageAction.copy));
    });
    final recipe = Message(
      id: 'r',
      author: _them,
      sentAt: DateTime(2026, 9, 24, 10),
      body: '',
      media: const Media(
        kind: MediaKind.file,
        name: 'recipe.pdf',
        mimeType: 'application/pdf',
        ref: 'x',
      ),
    );

    testWidgets(
      'media on a computer offers open and save as',
      variant: _desktop,
      (tester) async {
        expect(actionsFor(recipe, _you), [
          MessageAction.open,
          if (defaultTargetPlatform == TargetPlatform.macOS)
            MessageAction.openWith,
          MessageAction.saveAs,
          MessageAction.reply,
        ]);
      },
    );

    testWidgets('media on a phone offers open and share', variant: _mobile, (
      tester,
    ) async {
      expect(actionsFor(recipe, _you), [
        MessageAction.open,
        MessageAction.share,
        MessageAction.reply,
      ]);
    });

    testWidgets('open with names the default app on macOS', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final asked = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('moe.loaf.chat/media'),
        (call) async {
          asked.add(call.arguments);
          return call.method == 'defaultAppName' ? 'Preview' : null;
        },
      );
      try {
        tester.view.physicalSize = const Size(800, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final controller = TimelineController([recipe], you: _you);
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: loafDarkTheme(),
            home: Scaffold(
              body: MessageGroupTile(
                group: MessageGroup(controller.messages),
                controller: controller,
              ),
            ),
          ),
        );

        await tester.tap(find.byType(MediaRow), buttons: kSecondaryButton);
        await tester.pumpAndSettle();

        // Asked when the row appeared, and again for the next menu.
        expect(asked, isNotEmpty);
        expect(asked, everyElement({'extension': 'pdf'}));
        for (final label in ['Open', 'Open with Preview', 'Save as…']) {
          expect(find.text(label), findsOneWidget, reason: label);
        }
        expect(find.text('Share'), findsNothing);
      } finally {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('moe.loaf.chat/media'),
          null,
        );
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
