import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_media/loaf_media.dart';

class _FakeFile extends ChangeNotifier implements GrowingFile {
  _FakeFile(this.id);

  @override
  final String id;
  @override
  String get partialPath => '/media/$id/proof.mp4.part';
  @override
  int received = 0;
  @override
  int? total = 1000;
  @override
  bool complete = false;
  @override
  Object? error;
}

void main() {
  const channel = MethodChannel('moe.loaf.chat/media');
  final calls = <MethodCall>[];
  final created = <int>[];

  void mockNative(WidgetTester tester) {
    calls.clear();
    created.clear();
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'video.floating' ? true : null;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
      call,
    ) async {
      if (call.method == 'create') {
        created.add((call.arguments as Map)['id'] as int);
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    });
  }

  Future<void> nativeSays(
    WidgetTester tester,
    String method,
    Map<String, Object?> arguments,
  ) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall(method, arguments),
      ),
      (_) {},
    );
    await tester.pump();
  }

  List<String> methods() => [for (final c in calls) c.method];

  testWidgets(
    'signing out stops a video floating in picture in picture',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      mockNative(tester);
      final file = _FakeFile('v');
      var held = 0;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 320,
              child: LoafVideo(
                file: file,
                mimeType: 'video/mp4',
                aspect: 16 / 9,
                onHold: () => held++,
                onRelease: () => held--,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final view = created.single;
      await nativeSays(tester, 'video.playing', {'view': view});
      await nativeSays(tester, 'video.pip', {'view': view, 'active': true});

      // The row goes; the video floats on, reading its file.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(methods(), isNot(contains('stream.end')));
      expect(held, 1);

      calls.clear();
      LoafVideo.endAll();
      await tester.pump();
      expect(methods(), containsAll(['video.stopAll', 'stream.end']));
      expect(held, 0, reason: 'the file is let go');
      expect(videoFocus.value, isNull);

      // The window closing afterwards finds nothing left to let go.
      calls.clear();
      await nativeSays(tester, 'video.pip', {'view': view, 'active': false});
      expect(methods(), isEmpty);
      expect(held, 0);
    },
  );

  testWidgets(
    'with nothing playing, ending them all asks nothing of the native side',
    (tester) async {
      mockNative(tester);
      LoafVideo.endAll();
      await tester.pump();
      expect(calls, isEmpty);
    },
  );
}
