import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_media/loaf_media.dart';
import 'package:loaf_media/src/linux_video.dart' show LinuxVideo;

/// A download that has fully arrived.
class _FakeFile extends ChangeNotifier implements GrowingFile {
  @override
  String get id => 'proof.mp4';
  @override
  String get partialPath => '/media/proof.mp4.part';
  @override
  int get received => 1000;
  @override
  int? get total => 1000;
  @override
  bool get complete => true;
  @override
  Object? get error => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('moe.loaf.chat/media');
  late List<MethodCall> calls;
  late Map<String, Object?> state;

  setUp(() {
    calls = [];
    state = {'position': 0, 'duration': 4000, 'playing': true, 'error': false};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'video.create' => {'texture': 7, 'view': 1},
            'video.state' => state,
            _ => null,
          };
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  List<String> methods() => [for (final c in calls) c.method];
  Iterable<MethodCall> named(String method) =>
      calls.where((c) => c.method == method);

  Future<void> pumpVideo(WidgetTester tester, {VoidCallback? onOpen}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            child: LoafVideo(
              file: _FakeFile(),
              mimeType: 'video/mp4',
              aspect: 16 / 9,
              onOpen: onOpen,
            ),
          ),
        ),
      ),
    );
    // The view is created, then the first poll of its state lands.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Lets the player go, so its poll stops before the test ends.
  Future<void> leave(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  Future<TestGesture> hover(WidgetTester tester) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byType(Texture)));
    await tester.pump();
    return mouse;
  }

  final controls = find.byKey(LinuxVideo.controlsKey);
  final linux = TargetPlatformVariant.only(TargetPlatform.linux);

  testWidgets('it plays once created, and lets the player go with the row', (
    tester,
  ) async {
    await pumpVideo(tester);
    expect(methods().take(3), ['stream.begin', 'video.create', 'video.play']);
    expect(named('video.create').single.arguments, {'id': 'proof.mp4'});
    expect(named('video.play').single.arguments, {'view': 1});
    expect(videoFocus.value, 1, reason: 'one video plays at a time');
    final texture = tester.widget<Texture>(find.byType(Texture));
    expect(texture.textureId, 7);

    await leave(tester);
    expect(named('video.dispose').single.arguments, {'view': 1});
    expect(methods().last, 'stream.end');
    expect(videoFocus.value, isNull);
  }, variant: linux);

  testWidgets('the controls show on hover and hide after two seconds', (
    tester,
  ) async {
    await pumpVideo(tester);
    expect(controls, findsNothing);

    final mouse = await hover(tester);
    expect(controls, findsOneWidget);
    expect(find.text('0:00 / 0:04'), findsOneWidget);

    // Still moving: they stay.
    await tester.pump(const Duration(milliseconds: 1500));
    await mouse.moveBy(const Offset(4, 0));
    await tester.pump(const Duration(milliseconds: 1500));
    expect(controls, findsOneWidget);

    // Stopped for two seconds: they go.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 300));
    expect(controls, findsNothing);
    await leave(tester);
  }, variant: linux);

  testWidgets('dragging the scrubber seeks once, on release', (tester) async {
    await pumpVideo(tester);
    await hover(tester);

    final slider = find.byType(Slider);
    final drag = await tester.startGesture(tester.getCenter(slider));
    for (var i = 0; i < 5; i++) {
      await drag.moveBy(const Offset(10, 0));
      await tester.pump();
    }
    expect(named('video.seek'), isEmpty, reason: 'not while dragging');

    await drag.up();
    await tester.pump();
    final seeks = named('video.seek').toList();
    expect(seeks, hasLength(1));
    final ms = (seeks.single.arguments as Map)['ms'] as int;
    expect(ms, greaterThan(2000), reason: 'past the middle of 4 s');
    expect(ms, lessThanOrEqualTo(4000));
    await leave(tester);
  }, variant: linux);

  testWidgets('an error offers open instead', (tester) async {
    var opened = 0;
    state = {...state, 'playing': false, 'error': true};
    await pumpVideo(tester, onOpen: () => opened++);

    expect(find.textContaining("couldn't play this"), findsOneWidget);
    await tester.tap(find.text('open it instead'));
    expect(opened, 1);
    await leave(tester);
  }, variant: linux);

  testWidgets('space toggles play when the video has focus', (tester) async {
    await pumpVideo(tester);
    await tester.tap(find.byType(Texture));
    await tester.pump();
    final before = named('video.pause').length;

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(named('video.pause').length, before + 1);
    await leave(tester);
  }, variant: linux);

  testWidgets('the full window keeps time, and escape leaves it', (
    tester,
  ) async {
    await pumpVideo(tester);
    await hover(tester);
    await tester.tap(find.byIcon(Icons.fullscreen));
    await tester.pump();
    expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);

    // The row under the full window is offstage, but the time still moves.
    state = {...state, 'position': 2000};
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.text('0:02 / 0:04'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byIcon(Icons.fullscreen_exit), findsNothing);
    await leave(tester);
  }, variant: linux);
}
