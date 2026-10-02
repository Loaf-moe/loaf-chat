import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_media/loaf_media.dart';

/// A download the test drives by hand.
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

  void arrive(int bytes) {
    received = bytes;
    notifyListeners();
  }

  void finish() {
    received = 1000;
    complete = true;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('moe.loaf.chat/media');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  List<String> methods() => [for (final c in calls) c.method];

  testWidgets('begin, throttled progress, end', (tester) async {
    final file = _FakeFile('a')..received = 10;
    VideoStreams.attach(file);
    await tester.pump();
    expect(methods(), ['stream.begin']);
    expect(calls.single.arguments, {
      'id': 'a',
      'path': '/media/a/proof.mp4.part',
      'received': 10,
      'total': 1000,
      'complete': false,
      'failed': false,
    });

    for (var i = 1; i <= 20; i++) {
      file.arrive(10 + i * 10);
      await tester.pump(const Duration(milliseconds: 4));
    }
    await tester.pump(const Duration(milliseconds: 100));
    expect(methods(), ['stream.begin', 'stream.progress']);
    expect(calls.last.arguments, {
      'id': 'a',
      'received': 210,
      'total': 1000,
      'complete': false,
      'failed': false,
    });

    // Completion never waits for the throttle.
    file.arrive(500);
    file.finish();
    await tester.pump();
    expect(methods().last, 'stream.progress');
    expect((calls.last.arguments as Map)['complete'], isTrue);
    final sent = calls.length;
    await tester.pump(const Duration(milliseconds: 200));
    expect(calls, hasLength(sent), reason: 'nothing left to report');

    VideoStreams.detach(file);
    await tester.pump();
    expect(methods().last, 'stream.end');
    expect(calls.last.arguments, {'id': 'a'});

    // Detached: the file's news goes nowhere.
    file.arrive(1000);
    await tester.pump(const Duration(milliseconds: 200));
    expect(methods().last, 'stream.end');
  });

  testWidgets('a failure is sent at once', (tester) async {
    final file = _FakeFile('b');
    VideoStreams.attach(file);
    file.arrive(100);
    file
      ..error = StateError('offline')
      ..notifyListeners();
    await tester.pump();
    expect(methods(), ['stream.begin', 'stream.progress']);
    expect((calls.last.arguments as Map)['failed'], isTrue);

    // A retry writes the file afresh, so the native side begins again.
    file
      ..error = null
      ..received = 0
      ..notifyListeners();
    await tester.pump();
    expect(methods().last, 'stream.begin');
    VideoStreams.detach(file);
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('two players of one file share one stream', (tester) async {
    final file = _FakeFile('c');
    VideoStreams.attach(file);
    VideoStreams.attach(file);
    await tester.pump();
    expect(methods(), ['stream.begin']);

    VideoStreams.detach(file);
    await tester.pump();
    expect(methods(), ['stream.begin'], reason: 'one player still reads it');

    file.arrive(300);
    await tester.pump(const Duration(milliseconds: 150));
    expect(methods(), ['stream.begin', 'stream.progress']);

    VideoStreams.detach(file);
    await tester.pump();
    expect(methods(), ['stream.begin', 'stream.progress', 'stream.end']);
  });
}
