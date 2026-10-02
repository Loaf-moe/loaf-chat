import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/channel/image_viewer.dart';
import 'package:loaf_native/ui/mock/fixtures.dart';
import 'package:loaf_native/ui/mock/mock_media_source.dart';
import 'package:loaf_native/ui/model/media_source.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

const _oven = Media(
  kind: MediaKind.image,
  name: 'oven.jpg',
  mimeType: 'image/jpeg',
  dimensions: Size(1600, 1200),
  ref: 'assets/mock/media/oven.jpg',
);

class _FakeSelector extends FileSelectorPlatform {
  final suggested = <String?>[];

  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async {
    suggested.add(options.suggestedName);
    return null;
  }
}

void main() {
  /// A page with a button that opens the viewer, as `openMedia` does.
  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final root = Directory.systemTemp.createTempSync('loaf-viewer-test');
    addTearDown(() => root.deleteSync(recursive: true));
    final source = MockMediaSource(root);
    await tester.pumpWidget(
      MaterialApp(
        theme: loafDarkTheme(),
        home: MediaSourceScope(
          source: source,
          child: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => MediaSourceScope.carry(
                      context,
                      child: ImageViewer(
                        provider: source.image(_oven),
                        media: _oven,
                      ),
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Matrix4 transform(WidgetTester tester) => tester
      .widget<InteractiveViewer>(find.byType(InteractiveViewer))
      .transformationController!
      .value;

  testWidgets('escape closes the viewer', (tester) async {
    await pump(tester);
    expect(find.byType(ImageViewer), findsOneWidget);
    expect(find.byTooltip('Close (Esc)'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(ImageViewer), findsNothing);
  });

  testWidgets('scrolling zooms, and the image pans when zoomed', (
    tester,
  ) async {
    await pump(tester);
    expect(transform(tester).getMaxScaleOnAxis(), 1);

    final center = tester.getCenter(find.byType(InteractiveViewer));
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(center));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -200)));
    await tester.pump();

    final zoomed = transform(tester);
    expect(zoomed.getMaxScaleOnAxis(), greaterThan(1));

    final before = zoomed.getTranslation();
    await tester.dragFrom(center, const Offset(60, 40));
    await tester.pumpAndSettle();
    final after = transform(tester).getTranslation();
    expect(after.x, isNot(before.x));
    expect(after.y, isNot(before.y));
  });

  testWidgets("save as is in the viewer's bar", (tester) async {
    final original = FileSelectorPlatform.instance;
    addTearDown(() => FileSelectorPlatform.instance = original);
    final selector = _FakeSelector();
    FileSelectorPlatform.instance = selector;
    await pump(tester);

    await tester.tap(find.text('Save as…'));
    await tester.pumpAndSettle();

    expect(selector.suggested, ['oven.jpg']);
    expect(find.byType(ImageViewer), findsOneWidget);
  });
}
