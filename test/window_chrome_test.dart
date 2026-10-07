import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/window/window_chrome.dart';

const _channel = MethodChannel('loaf/window');

/// Fakes the runner: answers `state` with [state] and records every call.
List<MethodCall> _fakeRunner(
  WidgetTester tester, [
  Map<String, Object?> state = const {},
]) {
  final calls = <MethodCall>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (
    call,
  ) async {
    calls.add(call);
    return call.method == 'state' ? state : null;
  });
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _channel,
      null,
    ),
  );
  return calls;
}

/// Sends `stateChanged` as the runner would.
Future<void> _runnerSays(
  WidgetTester tester,
  Map<String, Object?> state,
) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    _channel.name,
    const StandardMethodCodec().encodeMethodCall(
      MethodCall('stateChanged', state),
    ),
    (_) {},
  );
  await tester.pump();
}

Future<WindowChromeController> _pump(WidgetTester tester, Widget child) async {
  final controller = WindowChromeController();
  addTearDown(controller.dispose);
  await controller.start();
  await tester.pumpWidget(
    MaterialApp(
      theme: loafDarkTheme(),
      builder: (context, app) =>
          WindowChrome(controller: controller, child: app!),
      home: Scaffold(body: child),
    ),
  );
  return controller;
}

/// A header the way the app's headers use the chrome.
Widget _header({VoidCallback? onButton}) => WindowDragArea(
  child: SizedBox(
    height: WindowMetrics.band,
    child: Row(
      children: [
        const WindowControls(WindowEdge.leading),
        const Expanded(child: Text('general')),
        IconButton(
          key: const ValueKey('header-button'),
          onPressed: onButton,
          icon: const Icon(Icons.people),
        ),
        const WindowControls(WindowEdge.trailing),
      ],
    ),
  ),
);

void main() {
  testWidgets(
    'each button sends its own call',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      final calls = _fakeRunner(tester);
      await _pump(tester, _header());
      await tester.pump();

      for (final name in ['minimize', 'maximize', 'close']) {
        await tester.tap(find.byKey(ValueKey('window-$name')));
        await tester.pump();
      }
      expect(
        calls.map((c) => c.method),
        containsAllInOrder(['minimize', 'toggleMaximize', 'close']),
      );
    },
  );

  testWidgets(
    'macOS draws its dots on the left',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      _fakeRunner(tester);
      await _pump(tester, _header());
      await tester.pump();

      final close = tester.getCenter(
        find.byKey(const ValueKey('window-close')),
      );
      final title = tester.getCenter(find.text('general'));
      expect(close.dx, lessThan(title.dx));
    },
  );

  testWidgets(
    'dragging the bar moves the window, double-clicking it zooms',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      final calls = _fakeRunner(tester, {'decorationLayout': ':close'});
      await _pump(tester, _header());
      await tester.pump();

      await tester.drag(
        find.text('general'),
        const Offset(80, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(calls.map((c) => c.method), contains('startDrag'));

      calls.clear();
      final title = find.text('general');
      await tester.tap(title, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(title, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(calls.map((c) => c.method), contains('titlebarDoubleClick'));
    },
  );

  testWidgets(
    'a button inside a drag area takes its tap at once',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      final calls = _fakeRunner(tester, {'decorationLayout': ':close'});
      var pressed = 0;
      await _pump(tester, _header(onButton: () => pressed++));
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey('header-button')),
        kind: PointerDeviceKind.mouse,
      );
      // No waiting out a double-tap timeout: one frame is enough.
      await tester.pump();
      expect(pressed, 1);
      expect(
        calls.map((c) => c.method),
        isNot(anyOf(contains('startDrag'), contains('titlebarDoubleClick'))),
      );
    },
  );

  testWidgets(
    'the GTK layout decides the side, and a tiling WM shows nothing',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      _fakeRunner(tester, {'decorationLayout': 'close:'});
      await _pump(tester, _header());
      await tester.pump();

      final close = tester.getCenter(
        find.byKey(const ValueKey('window-close')),
      );
      expect(close.dx, lessThan(tester.getCenter(find.text('general')).dx));
      expect(find.byKey(const ValueKey('window-minimize')), findsNothing);

      await _runnerSays(tester, {
        'decorationLayout': 'close:',
        'env': {'SWAYSOCK': '/run/sway'},
      });
      expect(find.byKey(const ValueKey('window-close')), findsNothing);
    },
  );

  testWidgets(
    'maximized swaps the maximize icon for restore',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      _fakeRunner(tester);
      final controller = await _pump(tester, _header());
      await tester.pump();
      expect(controller.state.maximized, isFalse);
      final before = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const ValueKey('window-maximize')),
          matching: find.byType(Icon),
        ),
      );

      await _runnerSays(tester, {'maximized': true});
      final after = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const ValueKey('window-maximize')),
          matching: find.byType(Icon),
        ),
      );
      expect(after.icon, isNot(before.icon));
    },
  );

  testWidgets(
    'WindowEdges.none keeps a covered surface from drawing buttons',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      _fakeRunner(tester);
      await _pump(tester, WindowEdges.none(child: _header()));
      await tester.pump();
      expect(find.byKey(const ValueKey('window-close')), findsNothing);
    },
  );

  testWidgets(
    'WindowBand takes no room where its corner has no buttons',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      _fakeRunner(tester, {'decorationLayout': ':close'});
      await _pump(
        tester,
        const Column(
          children: [
            WindowEdges(leading: true, trailing: false, child: WindowBand()),
            WindowEdges(leading: false, trailing: true, child: WindowBand()),
          ],
        ),
      );
      await tester.pump();
      final bands = tester.renderObjectList<RenderBox>(find.byType(WindowBand));
      expect([for (final b in bands) b.size.height], [0, WindowMetrics.band]);
    },
  );

  testWidgets(
    'Windows reports the maximize button to the runner',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      final calls = _fakeRunner(tester);
      await _pump(tester, _header());
      await tester.pump();
      await tester.pump();
      final rect = calls.lastWhere((c) => c.method == 'setMaxButtonRect');
      final box = tester.getRect(find.byKey(const ValueKey('window-maximize')));
      expect((rect.arguments as Map)['x'], box.left);
      expect((rect.arguments as Map)['w'], box.width);
    },
  );

  testWidgets(
    'a missing runner is quietly no buttons',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      // The test messenger never answers a channel with no handler at all, so
      // stand in for a runner that lacks the channel: a handler that reports
      // it missing, which is what invoking then throws.
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _channel,
        (_) async => throw MissingPluginException(),
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          _channel,
          null,
        ),
      );
      final controller = await _pump(tester, _header());
      await tester.pump();
      expect(controller.state, WindowState.hidden);
      expect(find.byKey(const ValueKey('window-close')), findsNothing);
      await controller.close(); // must not throw
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('nothing on a phone', (tester) async {
    // The default test platform is Android.
    final calls = _fakeRunner(tester, {'decorationLayout': ':close'});
    await _pump(tester, _header());
    await tester.pump();
    expect(calls, isEmpty);
    expect(find.byKey(const ValueKey('window-close')), findsNothing);
  });
}
