import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/matrix/call_media.dart';

import 'in_memory_call_media.dart';

final _url = Uri.parse('wss://sfu.example.com');

String _jwt(String identity) {
  final claims = base64Url.encode(
    utf8.encode(
      jsonEncode({
        'sub': identity,
        'video': {'room': '!oven'},
      }),
    ),
  );
  return 'head.$claims.signature';
}

void main() {
  late InMemoryCallServer server;
  setUp(() => server = InMemoryCallServer(_url));

  Future<CallConnection> join(String identity, {bool camera = true}) =>
      InMemoryCallMedia(server, camera: camera).connect(_url, _jwt(identity));

  test('a camera turned on is seen by everyone else', () async {
    final ada = await join('ada');
    final bea = await join('bea');

    await ada.setCamera(true);

    expect(bea.peers['ada']!.camera, isTrue);
    expect(bea.video('ada'), isNotNull);
    expect(ada.video(null), isNotNull);
  });

  test('a camera turned off is gone', () async {
    final ada = await join('ada');
    final bea = await join('bea');
    await ada.setCamera(true);

    await ada.setCamera(false);

    expect(bea.peers['ada']!.camera, isFalse);
    expect(bea.video('ada'), isNull);
  });

  test('a machine with no camera cannot turn one on', () async {
    final ada = await join('ada', camera: false);

    expect(() => ada.setCamera(true), throwsA(isA<CameraUnavailable>()));
  });

  test('a camera that opens after its connection is gone is not on', () async {
    final media = InMemoryCallMedia(server)..holdCamera = Completer();
    final ada = await media.connect(_url, _jwt('ada'));
    final opening = ada.setCamera(true);

    await ada.disconnect();
    media.holdCamera!.complete();

    await expectLater(opening, throwsA(isA<CameraUnavailable>()));
    expect(ada.video(null), isNull);
  });

  test('a screen shared is seen, apart from the camera', () async {
    final ada = await join('ada');
    final bea = await join('bea');

    shareScreen(ada, on: true);

    expect(bea.peers['ada']!.screen, isTrue);
    expect(bea.video('ada', screen: true), isNotNull);
    expect(bea.video('ada'), isNull);
  });
}
