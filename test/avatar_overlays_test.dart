import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/mock/mock_profile.dart';
import 'package:loaf_native/ui/model/models.dart';
import 'package:loaf_native/ui/settings/settings_page.dart';
import 'package:loaf_native/ui/shell/profile_controller.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/widgets/action_menu.dart';
import 'package:loaf_native/ui/widgets/adaptive_panel.dart';
import 'package:loaf_native/ui/widgets/anchored_popover.dart';
import 'package:loaf_native/ui/widgets/avatar_images.dart';
import 'package:loaf_native/ui/widgets/loaf_avatar.dart';

/// A 1x1 transparent PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

class _Fixed implements AvatarImages {
  @override
  ImageProvider? resolve(AvatarRef ref, double physicalSize) =>
      MemoryImage(_png);
}

const _ref = AvatarRef('mxc://x/y');

Widget _avatar() => LoafAvatar(
  label: 'AB',
  color: Colors.red,
  size: 36,
  textStyle: loafBody(13, 600),
  image: _ref,
);

/// The scope sits inside the home route, where the shell puts it: every
/// overlay below is pushed on the navigator above it.
Future<BuildContext> _host(WidgetTester tester) async {
  late BuildContext inScope;
  await tester.pumpWidget(
    MaterialApp(
      theme: loafLightTheme(),
      home: AvatarImagesScope(
        images: _Fixed(),
        child: Builder(
          builder: (context) {
            inScope = context;
            return const Scaffold(body: SizedBox());
          },
        ),
      ),
    ),
  );
  return inScope;
}

/// Lets the picture decode (real async work) and the fade-in finish.
Future<void> _decode(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
}

Finder _painted(Finder avatar) =>
    find.descendant(of: avatar, matching: find.byType(RawImage));

void main() {
  testWidgets('settings draws your picture, not initials', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // The editable account draws what the profile has, as the shell's does.
    final mock = MockProfile();
    await mock.setAvatar(Uint8List(3));
    final profile = ProfileController(profile: mock);
    addTearDown(profile.dispose);
    final context = await _host(tester);
    unawaited(showSettings(context, profile: profile));
    await tester.pumpAndSettle();
    await _decode(tester);
    final avatar = find.descendant(
      of: find.byType(SettingsModal),
      matching: find.byType(LoafAvatar),
    );
    expect(avatar, findsWidgets);
    expect(_painted(avatar.first), findsOneWidget);
  });

  testWidgets('an adaptive panel draws pictures', (tester) async {
    final context = await _host(tester);
    unawaited(showAdaptivePanel<void>(context, child: _avatar()));
    await tester.pumpAndSettle();
    await _decode(tester);
    expect(_painted(find.byType(LoafAvatar)), findsOneWidget);
  });

  testWidgets('an anchored popover draws pictures', (tester) async {
    final context = await _host(tester);
    unawaited(
      showAnchoredPopover<void>(
        context,
        anchor: const Rect.fromLTWH(100, 100, 10, 10),
        builder: (_) => _avatar(),
      ),
    );
    await tester.pumpAndSettle();
    await _decode(tester);
    expect(_painted(find.byType(LoafAvatar)), findsOneWidget);
  });

  testWidgets('an action sheet header draws pictures', (tester) async {
    final context = await _host(tester);
    unawaited(
      showActionSheet<void>(context, header: (_) => _avatar(), items: const []),
    );
    await tester.pumpAndSettle();
    await _decode(tester);
    expect(_painted(find.byType(LoafAvatar)), findsOneWidget);
  });
}
