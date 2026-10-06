import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/model/updater.dart';
import 'package:loaf_native/update/windows_updater.dart';

final _sep = Platform.pathSeparator;

/// Serves `latest.json` and the zip. Tests change [feed] and [zip].
class _Server {
  _Server(this._http);
  final HttpServer _http;
  String feed = '';
  List<int> zip = utf8.encode('pretend this is a zip');

  Uri get feedUri => Uri.parse('http://localhost:${_http.port}/latest.json');
  Uri get zipUri => Uri.parse('http://localhost:${_http.port}/app.zip');

  static Future<_Server> start() async {
    final server = _Server(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    server._http.listen((request) async {
      final response = request.response;
      if (request.uri.path == '/latest.json') {
        response.write(server.feed);
      } else {
        response.add(server.zip);
      }
      await response.close();
    });
    return server;
  }

  void offer({int build = 2, String signature = 'good', bool windows = true}) {
    feed = jsonEncode({
      'version': '0.1.$build',
      'build': build,
      if (windows)
        'windows': {
          'url': '$zipUri',
          'sha256': sha256.convert(zip).toString(),
          'size': zip.length,
          'signature': signature,
        },
    });
  }

  Future<void> close() => _http.close(force: true);
}

String _read(Directory dir, String rel) =>
    File('${dir.path}$_sep${rel.replaceAll('/', _sep)}').readAsStringSync();

void main() {
  late _Server server;
  late Directory root;
  late Directory install;
  final launched = <String>[];
  var quits = 0;
  final signed = <String>[];

  /// Unpacks "the zip" as the build it stands for, unless told to fail.
  var unpackFails = false;
  Future<void> unpack(File zip, Directory into) async {
    if (unpackFails) throw const ProcessException('tar', [], 'corrupt', 1);
    for (final (rel, body) in [
      ('loaf-chat.exe', 'new exe'),
      ('data/app.so', 'new code'),
    ]) {
      File('${into.path}$_sep${rel.replaceAll('/', _sep)}')
        ..createSync(recursive: true)
        ..writeAsStringSync(body);
    }
  }

  WindowsUpdater updater() {
    final u = WindowsUpdater(
      install: install,
      build: 1,
      feed: server.feedUri,
      verify: (message, signature) {
        signed.add(message);
        return signature == 'good';
      },
      unpack: unpack,
      launch: (path) async => launched.add(path),
      quit: () => quits++,
    );
    addTearDown(u.dispose);
    return u;
  }

  setUp(() async {
    server = await _Server.start();
    root = Directory.systemTemp.createTempSync('windows_updater');
    install = Directory('${root.path}${_sep}Loaf Chat')..createSync();
    for (final (rel, body) in [
      ('loaf-chat.exe', 'old exe'),
      ('data/app.so', 'old code'),
      ('unins000.dat', 'uninstall log'),
    ]) {
      File('${install.path}$_sep${rel.replaceAll('/', _sep)}')
        ..createSync(recursive: true)
        ..writeAsStringSync(body);
    }
    launched.clear();
    signed.clear();
    quits = 0;
    unpackFails = false;
  });

  tearDown(() async {
    await server.close();
    root.deleteSync(recursive: true);
  });

  test('a newer, signed build is swapped in and ready', () async {
    server.offer();
    final u = updater();
    expect(await u.check(), UpdateCheck.ready);
    expect(u.state, isA<UpdateReady>());
    expect((u.state as UpdateReady).version, '0.1.2');
    expect(_read(install, 'loaf-chat.exe'), 'new exe');
    expect(_read(install, 'data/app.so'), 'new code');
    expect(_read(install, 'unins000.dat'), 'uninstall log');
    // What was checked is the Windows build's text, not the AppImage's.
    expect(signed.single, startsWith('loaf-chat-windows\n0.1.2\n2\n'));
    // Nothing of the download is left but the set-aside old files.
    expect(Directory('${install.path}${_sep}update').existsSync(), isFalse);
  });

  test('restarting starts the new build and quits', () async {
    server.offer();
    final u = updater();
    await u.check();
    await u.restart();
    expect(launched, ['${install.path}${_sep}loaf-chat.exe']);
    expect(quits, 1);
    expect(u.state, isA<UpdateApplying>());
  });

  test('the same build is up to date', () async {
    server.offer(build: 1);
    expect(await updater().check(), UpdateCheck.upToDate);
    expect(_read(install, 'loaf-chat.exe'), 'old exe');
  });

  test('a release with no Windows build is up to date', () async {
    server.offer(windows: false);
    expect(await updater().check(), UpdateCheck.upToDate);
  });

  test('a bad signature leaves the install alone', () async {
    server.offer(signature: 'forged');
    final u = updater();
    expect(await u.check(), UpdateCheck.failed);
    expect(u.state, isA<UpdateIdle>());
    expect(_read(install, 'loaf-chat.exe'), 'old exe');
  });

  test('a zip that does not unpack leaves the install alone', () async {
    server.offer();
    unpackFails = true;
    final u = updater();
    expect(await u.check(), UpdateCheck.failed);
    expect(u.state, isA<UpdateIdle>());
    expect(_read(install, 'loaf-chat.exe'), 'old exe');
    expect(Directory('${install.path}${_sep}update').existsSync(), isFalse);
  });

  test('launch clears what the last update set aside', () async {
    File('${install.path}${_sep}loaf-chat.exe.old').writeAsStringSync('x');
    await updater().start(checkAfter: const Duration(hours: 1));
    expect(
      File('${install.path}${_sep}loaf-chat.exe.old').existsSync(),
      isFalse,
    );
  });
}
