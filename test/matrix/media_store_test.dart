import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:loaf_native/matrix/media_store.dart';
import 'package:matrix/matrix.dart';

import 'crypto_harness.dart';

final _mxc = Uri.parse('mxc://loaf.moe/abc');

String _id(Uri mxc) => sha256.convert(utf8.encode(mxc.toString())).toString();

void main() {
  late Directory root;
  late List<http.BaseRequest> requests;

  setUp(() {
    root = Directory.systemTemp.createTempSync('media_store_test');
    requests = [];
    addTearDown(() => root.deleteSync(recursive: true));
  });

  MediaStore storeOver(
    http.Client client, {
    int capBytes = 2000 * 1000 * 1000,
  }) => MediaStore(
    root: root,
    client: client,
    downloadUri: (mxc) async => Uri.https(
      'loaf.moe',
      '/_matrix/client/v1/media/download/${mxc.host}${mxc.path}',
    ),
    accessToken: () => 'tok',
    capBytes: capBytes,
  );

  /// Serves [chunks] whole, at once.
  MockClient serving(List<List<int>> chunks, {int status = 200}) =>
      MockClient.streaming((request, body) async {
        requests.add(request);
        return http.StreamedResponse(
          Stream.fromIterable(chunks),
          status,
          contentLength: status == 200
              ? chunks.fold<int>(0, (n, c) => n + c.length)
              : null,
        );
      });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  test('a plain file arrives on disk under its own name', () async {
    final store = storeOver(serving([utf8.encode('hello')]));
    addTearDown(store.dispose);
    final file = store.open(MediaSpec(mxc: _mxc, name: 'recipe.pdf'));
    final path = await file.path;
    expect(path, '${root.path}/${_id(_mxc)}/recipe.pdf');
    expect(File(path).readAsStringSync(), 'hello');
    expect(File('$path.part').existsSync(), isFalse);
    expect(file.complete, isTrue);
    expect(requests.single.headers['authorization'], 'Bearer tok');
  });

  test('progress is reported as bytes land', () async {
    final gate = StreamController<List<int>>();
    final client = MockClient.streaming((request, body) async {
      return http.StreamedResponse(gate.stream, 200, contentLength: 6);
    });
    final store = storeOver(client);
    addTearDown(store.dispose);
    final file = store.open(MediaSpec(mxc: _mxc, name: 'a.bin'));
    final seen = <int>[];
    file.addListener(() => seen.add(file.received));
    await settle();
    gate.add([1, 2]);
    await settle();
    gate.add([3, 4, 5, 6]);
    await gate.close();
    await file.path;
    expect(seen.first, 2);
    expect(seen, containsAllInOrder([2, 6]));
    expect(file.received, 6);
    expect(file.total, 6);
  });

  test('an encrypted file is decrypted on the way', () async {
    await loadVodozemac();
    final plain = Uint8List.fromList(List.generate(1000, (i) => i % 251));
    final enc = await MatrixFile(bytes: plain, name: 'x').encrypt();
    final chunks = [
      for (var i = 0; i < enc.data.length; i += 37)
        enc.data.sublist(i, (i + 37).clamp(0, enc.data.length)),
    ];
    final store = storeOver(serving(chunks));
    addTearDown(store.dispose);
    final file = store.open(
      MediaSpec(mxc: _mxc, name: 'p.png', key: enc.k, iv: enc.iv),
    );
    expect(File(await file.path).readAsBytesSync(), plain);
    expect(file.received, 1000);
  });

  test('two opens share one download', () async {
    final store = storeOver(serving([utf8.encode('x')]));
    addTearDown(store.dispose);
    final a = store.open(MediaSpec(mxc: _mxc, name: 'a'));
    final b = store.open(MediaSpec(mxc: _mxc, name: 'a'));
    await a.path;
    expect(identical(a, b), isTrue);
    expect(requests, hasLength(1));
  });

  test('a finished file is reused without a request', () async {
    final first = storeOver(serving([utf8.encode('abc')]));
    addTearDown(first.dispose);
    await first.open(MediaSpec(mxc: _mxc, name: 'a.txt')).path;
    requests.clear();
    final second = storeOver(serving([]));
    addTearDown(second.dispose);
    final file = second.open(MediaSpec(mxc: _mxc, name: 'a.txt'));
    expect(file.complete, isTrue);
    expect(file.total, 3);
    expect(File(await file.path).readAsStringSync(), 'abc');
    expect(requests, isEmpty);
  });

  test('a 404 is an error, and retry starts again', () async {
    var status = 404;
    final client = MockClient.streaming((request, body) async {
      requests.add(request);
      return http.StreamedResponse(
        Stream.value(utf8.encode('ok')),
        status,
        contentLength: 2,
      );
    });
    final store = storeOver(client);
    addTearDown(store.dispose);
    final file = store.open(MediaSpec(mxc: _mxc, name: 'a.txt'));
    await expectLater(file.path, throwsA(anything));
    expect(file.error, isNotNull);
    expect(File(file.partialPath).existsSync(), isFalse);
    status = 200;
    file.retry();
    expect(file.error, isNull);
    expect(File(await file.path).readAsStringSync(), 'ok');
    expect(requests, hasLength(2));
    expect(file.complete, isTrue);
  });

  test('a broken file map fails the download, not the caller', () async {
    final store = storeOver(serving([utf8.encode('x')]));
    addTearDown(store.dispose);
    final file = store.open(
      MediaSpec(mxc: _mxc, name: 'a', key: '!!not base64!!', iv: 'AAAA'),
    );
    await expectLater(file.path, throwsA(anything));
    expect(file.error, isNotNull);
    expect(requests, isEmpty);
  });

  test('a .part left by a quit starts over', () async {
    final dir = Directory('${root.path}/${_id(_mxc)}')
      ..createSync(recursive: true);
    final stale = File('${dir.path}/a.txt.part')
      ..writeAsStringSync('stale stale stale');
    // Opening for write would truncate it anyway; what only a delete does is
    // clear it before the server has even answered.
    var staleAtRequest = true;
    final client = MockClient.streaming((request, body) async {
      staleAtRequest = stale.existsSync();
      return http.StreamedResponse(
        Stream.value(utf8.encode('fresh')),
        200,
        contentLength: 5,
      );
    });
    final store = storeOver(client);
    addTearDown(store.dispose);
    final file = store.open(MediaSpec(mxc: _mxc, name: 'a.txt'));
    expect(File(await file.path).readAsStringSync(), 'fresh');
    expect(staleAtRequest, isFalse);
    expect(stale.existsSync(), isFalse);
  });

  test('a wrong-length key fails the download cleanly', () async {
    final store = storeOver(serving([utf8.encode('x')]));
    addTearDown(store.dispose);
    final file = store.open(
      MediaSpec(
        mxc: _mxc,
        name: 'a',
        key: base64Url.encode(List.filled(16, 1)).replaceAll('=', ''),
        iv: base64.encode(List.filled(16, 1)).replaceAll('=', ''),
      ),
    );
    await expectLater(file.path, throwsA(isA<ArgumentError>()));
    expect(file.error, isA<ArgumentError>());
    expect(requests, isEmpty);
  });

  test('a failure while writing lets go of the connection', () async {
    final gate = StreamController<List<int>>();
    var cancelled = false;
    gate.onCancel = () => cancelled = true;
    final client = MockClient.streaming((request, body) async {
      return http.StreamedResponse(gate.stream, 200, contentLength: 5);
    });
    // A directory where the .part goes: opening it for writing fails after
    // the response has arrived.
    Directory('${root.path}/${_id(_mxc)}/a.txt.part')
        .createSync(recursive: true);
    final store = storeOver(client);
    addTearDown(store.dispose);
    final file = store.open(MediaSpec(mxc: _mxc, name: 'a.txt'));
    await expectLater(file.path, throwsA(isA<FileSystemException>()));
    expect(file.error, isNotNull);
    expect(cancelled, isTrue);
  });

  test('one failed eviction does not stop the next', () async {
    final uris = [for (var i = 0; i < 2; i++) Uri.parse('mxc://loaf.moe/g$i')];
    for (var i = 0; i < 2; i++) {
      final dir = Directory('${root.path}/${_id(uris[i])}')
        ..createSync(recursive: true);
      File('${dir.path}/f.bin')
        ..writeAsBytesSync(List.filled(100, 1))
        ..setLastModifiedSync(DateTime(2026, 1, 1 + i));
    }
    final store = storeOver(serving([]), capBytes: 100);
    addTearDown(store.dispose);
    // A folder that cannot be written to refuses to give up its file.
    final locked = '${root.path}/${_id(uris[0])}';
    Process.runSync('chmod', ['555', locked]);
    addTearDown(() => Process.runSync('chmod', ['755', locked]));
    await store.evict();
    expect(File('$locked/f.bin').existsSync(), isTrue);
    Process.runSync('chmod', ['755', locked]);
    await store.evict();
    expect(Directory('${root.path}/${_id(uris[0])}').existsSync(), isFalse);
    expect(Directory('${root.path}/${_id(uris[1])}').existsSync(), isTrue);
  });

  test('disposing mid-download fails it and notifies nothing', () async {
    final gate = StreamController<List<int>>();
    final client = MockClient.streaming((request, body) async {
      return http.StreamedResponse(gate.stream, 200, contentLength: 10);
    });
    final store = storeOver(client);
    final file = store.open(MediaSpec(mxc: _mxc, name: 'a.bin'));
    gate.add([1, 2, 3]);
    await settle();
    var notified = 0;
    file.addListener(() => notified++);
    store.dispose();
    gate.add([4, 5]);
    await settle();
    await expectLater(file.path, throwsA(isA<StateError>()));
    expect(file.error, isA<StateError>());
    expect(notified, 0);
    expect(file.complete, isFalse);
  });

  test(
    'eviction drops the oldest first and spares held and running files',
    () async {
      // f3 arrives only as the test feeds it: a download still running.
      final gate = StreamController<List<int>>();
      addTearDown(gate.close);
      final client = MockClient.streaming((request, body) async {
        requests.add(request);
        if (request.url.path.endsWith('/f3')) {
          return http.StreamedResponse(gate.stream, 200, contentLength: 200);
        }
        return http.StreamedResponse(
          Stream.value(List.filled(100, 1)),
          200,
          contentLength: 100,
        );
      });
      final store = storeOver(client, capBytes: 200);
      addTearDown(store.dispose);
      final uris = [
        for (var i = 0; i < 4; i++) Uri.parse('mxc://loaf.moe/f$i'),
      ];
      Directory dirOf(int i) => Directory('${root.path}/${_id(uris[i])}');
      final files = <StoredFile>[];
      for (final u in uris.take(3)) {
        files.add(store.open(MediaSpec(mxc: u, name: 'f.bin')));
      }
      for (final f in files) {
        await f.path;
      }
      // Evictions run one after another, so this one waits out the passes
      // each finished download started.
      await store.evict();
      // Start from all three on disk, oldest f0 and newest f2.
      for (var i = 0; i < 3; i++) {
        final dir = dirOf(i)..createSync(recursive: true);
        final f = File('${dir.path}/f.bin');
        if (!f.existsSync()) f.writeAsBytesSync(List.filled(100, 1));
        f.setLastModifiedSync(DateTime(2026, 1, 1 + i));
      }

      files[0].hold();
      await store.evict();
      expect(dirOf(0).existsSync(), isTrue, reason: 'held');
      expect(dirOf(1).existsSync(), isFalse);
      expect(dirOf(2).existsSync(), isTrue);

      // Over the cap again with a download half in, made the oldest of all.
      final running = store.open(MediaSpec(mxc: uris[3], name: 'f.bin'));
      final arrived = Completer<void>();
      running.addListener(() {
        if (running.received >= 100 && !arrived.isCompleted) arrived.complete();
      });
      gate.add(List.filled(100, 1));
      await arrived.future;
      File(running.partialPath).setLastModifiedSync(DateTime(2025));

      files[0].release();
      await store.evict();
      expect(dirOf(3).existsSync(), isTrue, reason: 'still arriving');
      expect(File(running.partialPath).existsSync(), isTrue);
      expect(dirOf(0).existsSync(), isFalse, reason: 'released, then oldest');
      expect(dirOf(2).existsSync(), isTrue);
    },
  );

  test('a long name is cut short, keeping its extension', () {
    final long = '${'a' * 300}.png';
    final safe = MediaStore.safeName(long);
    expect(utf8.encode(safe).length, lessThanOrEqualTo(200));
    expect(safe, endsWith('.png'));
    expect(safe, startsWith('aaaa'));

    // Cut between characters, never inside one.
    final wide = '${'🥖' * 100}.mp4';
    final cut = MediaStore.safeName(wide);
    expect(utf8.encode(cut).length, lessThanOrEqualTo(200));
    expect(cut, endsWith('.mp4'));
    expect(cut.replaceAll('🥖', ''), '.mp4');

    // No extension to keep, or one too long to be one.
    expect(utf8.encode(MediaStore.safeName('b' * 400)).length, 200);
    expect(
      utf8.encode(MediaStore.safeName('c.${'d' * 400}')).length,
      lessThanOrEqualTo(200),
    );
    expect(MediaStore.safeName('short.png'), 'short.png');
  });

  test('a file with a very long name arrives on disk', () async {
    final store = storeOver(serving([utf8.encode('hello')]));
    addTearDown(store.dispose);
    final file = store.open(MediaSpec(mxc: _mxc, name: '${'x' * 300}.pdf'));
    final path = await file.path;
    expect(File(path).readAsStringSync(), 'hello');
    expect(path, endsWith('.pdf'));
  });

  test('file names are made safe', () {
    expect(MediaStore.safeName('../../etc/passwd'), 'passwd');
    expect(MediaStore.safeName(''), 'file');
    expect(MediaStore.safeName('a/b:c.png'), 'b_c.png');
    expect(MediaStore.safeName('..'), 'file');
  });

  test('names Windows keeps for devices are not file names', () {
    expect(MediaStore.safeName('CON.mp4'), '_CON.mp4');
    expect(MediaStore.safeName('nul'), '_nul');
    expect(MediaStore.safeName('com1.tar.gz'), '_com1.tar.gz');
    expect(MediaStore.safeName('LPT9'), '_LPT9');
    expect(MediaStore.safeName('conference.mp4'), 'conference.mp4');
    expect(MediaStore.safeName('com10.txt'), 'com10.txt');
  });

  test('a name never ends in a dot or a space', () {
    expect(MediaStore.safeName('photo.jpg.'), 'photo.jpg');
    expect(MediaStore.safeName('notes. . '), 'notes');
    expect(MediaStore.safeName('...'), 'file');
  });

  test('on Windows the whole path fits in MAX_PATH', () {
    final dir = 'C:\\Users\\someone\\AppData\\Roaming\\moe.loaf\\media\\'
        'files\\${'a' * 64}';
    final budget = MediaStore.nameBudget(dir, windows: true);
    // Room for the separator and `.part` inside 240.
    expect(dir.length + 1 + budget + '.part'.length, lessThanOrEqualTo(240));
    final name = MediaStore.safeName('${'x' * 300}.pdf', maxBytes: budget);
    expect(name.length, lessThanOrEqualTo(budget));
    expect(name, endsWith('.pdf'));

    // Elsewhere only the file system's own limit applies.
    expect(MediaStore.nameBudget(dir, windows: false), 200);
    // A directory too deep for any name still gets a short one.
    expect(MediaStore.nameBudget('C:\\${'d' * 300}', windows: true), 16);
  });
}
