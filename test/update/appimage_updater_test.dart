import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/model/updater.dart';
import 'package:loaf_native/update/appimage_updater.dart';

const _old = 'the old build';
const _new = 'the new build, which is longer';

class _Server {
  _Server(this._http);
  final HttpServer _http;

  /// What `latest.json` and the download answer with. Tests change these.
  String feed = '';
  List<int> download = utf8.encode(_new);
  bool cutDownloadShort = false;

  Uri get feedUri => Uri.parse('http://localhost:${_http.port}/latest.json');
  Uri get downloadUri => Uri.parse('http://localhost:${_http.port}/app');

  static Future<_Server> start() async {
    final server = _Server(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    server._http.listen((request) async {
      final response = request.response;
      if (request.uri.path == '/latest.json') {
        response.write(server.feed);
      } else if (server.cutDownloadShort) {
        // Promises more than it sends, so the connection drops part-way.
        response.contentLength = server.download.length;
        response.add(server.download.sublist(0, 4));
        try {
          await response.close();
        } catch (_) {}
        return;
      } else {
        response.add(server.download);
      }
      await response.close();
    });
    return server;
  }

  /// A feed for [body] at [build], signed `good` unless told otherwise.
  void offer({int build = 2, String? sha, String signature = 'good'}) {
    feed = jsonEncode({
      'version': '0.1.$build',
      'build': build,
      'appimage': {
        'url': '$downloadUri',
        'sha256': sha ?? sha256.convert(download).toString(),
        'size': download.length,
        'signature': signature,
      },
    });
  }

  Future<void> close() => _http.close(force: true);
}

void main() {
  late _Server server;
  late Directory dir;
  late File appImage;
  final launched = <String>[];
  var quits = 0;

  AppImageUpdater updater({File? at}) {
    final u = AppImageUpdater(
      appImage: at ?? appImage,
      build: 1,
      feed: server.feedUri,
      verify: (message, signature) => signature == 'good',
      launch: (path) async => launched.add(path),
      quit: () => quits++,
    );
    addTearDown(u.dispose);
    return u;
  }

  setUp(() async {
    server = await _Server.start();
    dir = await Directory.systemTemp.createTemp('loaf-appimage');
    appImage = File('${dir.path}/Loaf-Chat.AppImage')..writeAsStringSync(_old);
    launched.clear();
    quits = 0;
  });

  tearDown(() async {
    await server.close();
    // A test may have made the folder read-only.
    Process.runSync('chmod', ['-R', 'u+w', dir.path]);
    dir.deleteSync(recursive: true);
  });

  bool leftovers() =>
      dir.listSync().any((entry) => entry.path.endsWith('.part'));

  test('a newer, signed build replaces the file and is ready', () async {
    server.offer();
    final u = updater();
    await u.check();
    expect(u.state, isA<UpdateReady>());
    expect((u.state as UpdateReady).version, '0.1.2');
    expect(appImage.readAsStringSync(), _new);
    expect(appImage.statSync().modeString(), contains('x'));
    expect(leftovers(), isFalse);
  });

  test('restarting launches the file and quits', () async {
    server.offer();
    final u = updater();
    await u.check();
    await u.restart();
    expect(launched, [appImage.path]);
    expect(quits, 1);
    expect(u.state, isA<UpdateApplying>());
  });

  test('restarting before anything is ready does nothing', () async {
    final u = updater();
    await u.restart();
    expect(launched, isEmpty);
    expect(quits, 0);
  });

  test('a launch that fails leaves the update ready', () async {
    server.offer();
    final u = AppImageUpdater(
      appImage: appImage,
      build: 1,
      feed: server.feedUri,
      verify: (_, signature) => signature == 'good',
      launch: (_) async => throw const FileSystemException('no'),
      quit: () => quits++,
    );
    addTearDown(u.dispose);
    await u.check();
    await u.restart();
    expect(quits, 0);
    expect(u.state, isA<UpdateReady>());
  });

  for (final (name, arrange) in <(String, void Function())>[
    ('the same build', () => server.offer(build: 1)),
    ('an older build', () => server.offer(build: 0)),
    ('a bad signature', () => server.offer(signature: 'forged')),
    ('a hash that does not match', () => server.offer(sha: 'ab' * 32)),
    ('a web page where the feed should be', () => server.feed = '<html>'),
    ('a feed with no AppImage', () {
      server.feed = '{"version":"0.1.2","build":2}';
    }),
    ('a download cut short', () {
      server
        ..offer()
        ..cutDownloadShort = true;
    }),
  ]) {
    test('$name leaves the file alone', () async {
      arrange();
      final u = updater();
      await u.check();
      expect(u.state, isA<UpdateIdle>());
      expect(appImage.readAsStringSync(), _old);
      expect(leftovers(), isFalse);
    });
  }

  test('a feed nobody answers leaves the file alone', () async {
    final u = updater();
    await server.close();
    await u.check();
    expect(u.state, isA<UpdateIdle>());
    expect(appImage.readAsStringSync(), _old);
  });

  test('a folder that cannot be written leaves the file alone', () async {
    server.offer();
    Process.runSync('chmod', ['u-w', dir.path]);
    final u = updater();
    await u.check();
    expect(u.state, isA<UpdateIdle>());
    expect(appImage.readAsStringSync(), _old);
  });

  test('a symlink is followed: the real file is replaced', () async {
    server.offer();
    final bin = await Directory('${dir.path}/bin').create();
    final link = Link('${bin.path}/loaf')..createSync(appImage.path);
    final u = updater(at: File(link.path));
    await u.check();
    expect(u.state, isA<UpdateReady>());
    expect(FileSystemEntity.isLinkSync(link.path), isTrue);
    expect(appImage.readAsStringSync(), _new);
  });

  test('a check while one is running is not a second download', () async {
    server.offer();
    final u = updater();
    await Future.wait([u.check(), u.check()]);
    expect(u.state, isA<UpdateReady>());
    expect(leftovers(), isFalse);
  });

  test('once ready, later checks leave it be', () async {
    server.offer();
    final u = updater();
    await u.check();
    server.feed = '<html>';
    await u.check();
    expect(u.state, isA<UpdateReady>());
  });
}
