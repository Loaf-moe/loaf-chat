import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_media/loaf_media.dart';
import 'package:loaf_native/ui/channel/image_viewer.dart';
import 'package:loaf_native/ui/channel/media_open.dart';
import 'package:loaf_native/ui/channel/media_row.dart';
import 'package:loaf_native/ui/mock/fixtures.dart';
import 'package:loaf_native/ui/mock/mock_media_source.dart';
import 'package:loaf_native/ui/model/media_source.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

const _oven = Media(
  kind: MediaKind.image,
  name: 'oven.jpg',
  mimeType: 'image/jpeg',
  dimensions: Size(1600, 1200),
  hasPreview: true,
  ref: 'assets/mock/media/oven.jpg',
);
const _pdf = Media(
  kind: MediaKind.file,
  name: 'recipe.pdf',
  mimeType: 'application/pdf',
  size: 612,
  ref: 'assets/mock/media/recipe.pdf',
);

const _channel = MethodChannel('moe.loaf.chat/media');

/// A file that arrives only when the test says so.
class _ManualFile extends ChangeNotifier implements MediaFile {
  final _done = Completer<String>();
  var held = 0;
  var _received = 0;

  void arrive(int bytes) {
    _received = bytes;
    notifyListeners();
  }

  void finish(String path) {
    _received = 612;
    _done.complete(path);
    notifyListeners();
  }

  @override
  String get id => 'manual';
  @override
  String get partialPath => '/nowhere.part';
  @override
  int get received => _received;
  @override
  int? get total => 612;
  @override
  bool get complete => _done.isCompleted;
  @override
  Object? get error => null;
  @override
  Future<String> get path => _done.future;
  @override
  void retry() {}
  @override
  void hold() => held++;
  @override
  void release() => held--;
}

class _ManualSource implements MediaSource {
  final file = _ManualFile();
  var opens = 0;

  @override
  MediaFile open(Media media) {
    opens++;
    return file;
  }

  @override
  ImageProvider? preview(Media media, double physicalWidth) => null;
  @override
  ImageProvider image(Media media) => throw UnimplementedError();
  @override
  void retryPreview(Media media) {}
}

class _FakeSelector extends FileSelectorPlatform {
  _FakeSelector(this.answer);

  /// Where the panel "chose"; null is Cancel.
  final String? answer;
  final suggested = <String?>[];

  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async {
    suggested.add(options.suggestedName);
    final answer = this.answer;
    return answer == null ? null : FileSaveLocation(answer);
  }
}

/// Stands in for xdg-desktop-portal; keeps what the descriptor read.
class _FakePortal extends DBusObject {
  _FakePortal() : super(DBusObjectPath('/org/freedesktop/portal/desktop'));

  final opened = <List<int>>[];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.name != 'OpenFile') {
      return DBusMethodErrorResponse.unknownMethod();
    }
    final file = methodCall.values[1].asUnixFd().toFile();
    try {
      opened.add(await file.read(4));
    } finally {
      await file.close();
    }
    return DBusMethodSuccessResponse([
      DBusObjectPath('/org/freedesktop/portal/desktop/request/1_1/t'),
    ]);
  }
}

void main() {
  // The test pins its own platform; it has to be undone before the test
  // ends, so a tearDown is too late.
  Future<void> on(TargetPlatform p, Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = p;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  List<MethodCall> mockChannel(
    WidgetTester tester, {
    Object? Function(MethodCall call)? answer,
  }) {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (
      call,
    ) async {
      calls.add(call);
      return answer?.call(call);
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _channel,
        null,
      ),
    );
    return calls;
  }

  Directory tempRoot() {
    final root = Directory.systemTemp.createTempSync('loaf-media-open-test');
    addTearDown(() => root.deleteSync(recursive: true));
    return root;
  }

  /// A row that opens its media, as the timeline's does. Returns a context
  /// under the source, for calling the open functions directly.
  Future<BuildContext> pump(
    WidgetTester tester,
    MediaSource source,
    Media media,
  ) async {
    late BuildContext inside;
    await tester.pumpWidget(
      MaterialApp(
        theme: loafDarkTheme(),
        home: MediaSourceScope(
          source: source,
          child: Scaffold(
            body: Builder(
              builder: (context) {
                inside = context;
                return Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 400,
                    child: MediaRow(
                      media: media,
                      onOpen: () => openMedia(context, media),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    return inside;
  }

  testWidgets('opening waits for the file, then quick looks it on iOS', (
    tester,
  ) async {
    await on(TargetPlatform.iOS, () async {
      final calls = mockChannel(tester);
      final source = _ManualSource();
      await pump(tester, source, _pdf);

      await tester.tap(find.byType(MediaRow));
      await tester.pump();
      source.file.arrive(300);
      await tester.pump();

      expect(calls, isEmpty);
      expect(source.file.held, 1);
      final ring = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(ring.value, closeTo(300 / 612, 0.001));

      source.file.finish('/files/recipe.pdf');
      await tester.pumpAndSettle();

      expect(calls, [
        isMethodCall('quickLook', arguments: {'path': '/files/recipe.pdf'}),
      ]);
      expect(source.file.held, 0);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  testWidgets('on Linux an image opens in the viewer, and a pdf through the '
      'portal', (tester) async {
    await on(TargetPlatform.linux, () async {
      final calls = mockChannel(tester);
      final context = await pump(tester, MockMediaSource(tempRoot()), _oven);

      await tester.runAsync(() => openMedia(context, _oven));
      await tester.pumpAndSettle();
      expect(find.byType(ImageViewer), findsOneWidget);
      expect(find.text('oven.jpg'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(ImageViewer), findsNothing);

      final portal = _FakePortal();
      await tester.runAsync(() async {
        final dir = tempRoot();
        final server = DBusServer();
        final address = await server.listenAddress(DBusAddress.unix(dir: dir));
        // The private bus does not check who connects; naming a uid lets
        // the client authenticate on a Mac too.
        DBusClient client() =>
            DBusClient(address, authClient: DBusAuthClient(uid: '0'));
        final portalSide = client();
        try {
          await portalSide.requestName('org.freedesktop.portal.Desktop');
          await portalSide.registerObject(portal);
          LoafMedia.sessionBus = client;
          await openMedia(context, _pdf);
        } finally {
          LoafMedia.sessionBus = DBusClient.session;
          await portalSide.close();
          await server.close();
        }
      });
      await tester.pumpAndSettle();

      expect(portal.opened, ['%PDF'.codeUnits]);
      expect(calls, isEmpty);
      expect(find.byType(ImageViewer), findsNothing);
    });
  });

  group('save as', () {
    late FileSelectorPlatform original;
    setUp(() => original = FileSelectorPlatform.instance);
    tearDown(() => FileSelectorPlatform.instance = original);

    testWidgets('save as copies the file where the panel said', (tester) async {
      final out = tempRoot();
      final selector = _FakeSelector('${out.path}/our recipe.pdf');
      FileSelectorPlatform.instance = selector;
      final context = await pump(tester, MockMediaSource(tempRoot()), _pdf);

      await tester.runAsync(() => saveMediaAs(context, _pdf));
      await tester.pump();

      expect(selector.suggested, ['recipe.pdf']);
      expect(
        File('${out.path}/our recipe.pdf').readAsBytesSync(),
        File('assets/mock/media/recipe.pdf').readAsBytesSync(),
      );
      expect(find.text('saved'), findsOneWidget);
    });

    testWidgets('a cancelled save panel does nothing', (tester) async {
      final selector = _FakeSelector(null);
      FileSelectorPlatform.instance = selector;
      final source = _ManualSource();
      final context = await pump(tester, source, _pdf);

      await saveMediaAs(context, _pdf);
      await tester.pump();

      expect(selector.suggested, ['recipe.pdf']);
      expect(source.opens, 0, reason: 'nothing to download for');
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  testWidgets('a failed open says so and leaves the row as it was', (
    tester,
  ) async {
    await on(TargetPlatform.macOS, () async {
      final calls = mockChannel(
        tester,
        answer: (call) => throw PlatformException(
          code: 'open-failed',
          message: 'the panel refused',
        ),
      );
      final context = await pump(tester, MockMediaSource(tempRoot()), _pdf);

      await tester.runAsync(() => openMedia(context, _pdf));
      await tester.pump();

      expect(calls.single.method, 'quickLook');
      expect(find.text("couldn't open recipe.pdf"), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('recipe.pdf'), findsOneWidget, reason: 'the row');

      // And it can be asked again.
      await tester.runAsync(() => openMedia(context, _pdf));
      expect(calls, hasLength(2));
    });
  });
}
