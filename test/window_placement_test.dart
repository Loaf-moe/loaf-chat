import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:loaf_native/ui/auth/login_page.dart';
import 'package:loaf_native/ui/auth/sign_in_controller.dart';
import 'package:loaf_native/ui/auth/sign_in_state.dart';
import 'package:loaf_native/ui/call/call_controller.dart';
import 'package:loaf_native/ui/call/call_view.dart';
import 'package:loaf_native/ui/mock/accounts.dart';
import 'package:loaf_native/ui/shell/app_shell.dart';
import 'package:loaf_native/ui/shell/channel_list.dart';
import 'package:loaf_native/ui/shell/spaces_rail.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/window/window_chrome.dart';

const _channel = MethodChannel('loaf/window');
const _close = ValueKey('window-close');

Future<void> _pump(
  WidgetTester tester,
  Size size,
  Widget home, [
  Map<String, Object?> state = const {},
]) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    _channel,
    (call) async => call.method == 'state' ? state : null,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _channel,
      null,
    ),
  );
  final controller = WindowChromeController();
  addTearDown(controller.dispose);
  await controller.start();
  await tester.pumpWidget(
    MaterialApp(
      theme: loafLightTheme(),
      darkTheme: loafDarkTheme(),
      themeMode: ThemeMode.dark,
      builder: (context, app) =>
          WindowChrome(controller: controller, child: app!),
      home: home,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'wide, members open: one close, at the top right of the member list',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      await _pump(tester, const Size(1440, 900), const AppShell());
      expect(find.byKey(_close), findsOneWidget);
      final close = tester.getRect(find.byKey(_close));
      expect(close.right, greaterThan(1440 - LoafShell.memberListWidth));
      expect(close.top, lessThan(WindowMetrics.band));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'wide, members closed: the close moves into the channel header',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      await _pump(tester, const Size(1440, 900), const AppShell());
      await tester.tap(find.byIcon(LucideIcons.users));
      await tester.pumpAndSettle();
      expect(find.byKey(_close), findsOneWidget);
      final close = tester.getRect(find.byKey(_close));
      final members = tester.getRect(find.byIcon(LucideIcons.users));
      // Past the members toggle, at the window's right edge.
      expect(close.left, greaterThan(members.right));
      expect(close.right, greaterThan(1440 - 60));
    },
  );

  testWidgets(
    'macOS wide: the dots sit in the rail',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      await _pump(tester, const Size(1440, 900), const AppShell());
      expect(find.byKey(_close), findsOneWidget);
      final close = tester.getRect(find.byKey(_close));
      expect(close.right, lessThan(LoafShell.railWidth));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow: one set of buttons, in the channel header',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      await _pump(tester, const Size(600, 800), const AppShell());
      expect(find.byKey(_close), findsOneWidget);
      final close = tester.getRect(find.byKey(_close));
      final menu = tester.getRect(find.byIcon(LucideIcons.menu));
      expect(close.right, lessThan(menu.left));

      // The drawer slides over the header; it brings no buttons of its own.
      await tester.tap(find.byIcon(LucideIcons.menu));
      await tester.pumpAndSettle();
      expect(find.byKey(_close), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'sign-in has the buttons too',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      await _pump(
        tester,
        const Size(1000, 800),
        LoginPage(
          controller: SignInController.at(
            SignInState(
              server: 'loaf.moe',
              check: mockServers['loaf.moe']!,
              provider: loafMoeProvider,
            ),
          ),
        ),
        {'decorationLayout': ':minimize,close'},
      );
      expect(find.byKey(_close), findsOneWidget);
      expect(find.byKey(const ValueKey('window-maximize')), findsNothing);
    },
  );

  testWidgets(
    'a tiling WM: no buttons anywhere, and the layout still fits',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      await _pump(tester, const Size(1440, 900), const AppShell(), {
        'decorationLayout': ':close',
        'env': {'SWAYSOCK': '/run/sway'},
      });
      expect(find.byKey(_close), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'call fullscreen: the call bar holds the corner, once',
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.macOS,
    }),
    (tester) async {
      await _pump(tester, const Size(1440, 900), const AppShell());
      await tester.tap(find.text('the hangout'));
      // Not pumpAndSettle: a live call keeps animating.
      await tester.pump(CallController.connectDelay);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byTooltip('Fullscreen'));
      await tester.pump(const Duration(milliseconds: 300));
      // Fullscreen is really on: the shell's own columns are gone...
      expect(find.byType(SpacesRail), findsNothing);
      expect(find.byType(ChannelList), findsNothing);
      // ...so the call's bar, not the shell, holds the corner.
      expect(
        find.descendant(
          of: find.byType(CallTopBar),
          matching: find.byKey(_close),
        ),
        findsOneWidget,
      );
      expect(find.byKey(_close), findsOneWidget);
      final close = tester.getRect(find.byKey(_close));
      expect(close.top, lessThan(WindowMetrics.band));
      if (defaultTargetPlatform == TargetPlatform.macOS) {
        expect(close.left, lessThan(60));
      } else {
        expect(close.right, greaterThan(1440 - 60));
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Linux with its buttons on the left: they sit in the rail, fitted',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      await _pump(tester, const Size(1440, 900), const AppShell(), {
        'decorationLayout': 'close,minimize:',
      });
      expect(find.byKey(_close), findsOneWidget);
      final close = tester.getRect(find.byKey(_close));
      expect(close.right, lessThan(LoafShell.railWidth));
      expect(tester.takeException(), isNull);
    },
  );
}
