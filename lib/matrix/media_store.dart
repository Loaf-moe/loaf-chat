import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart' show Logs;

import '../ui/model/media_source.dart';
import 'ctr_decryptor.dart';

/// What to fetch: one remote file, and how to read it. [mxc] is the
/// homeserver's own copy, or the `https` link of a file on another site.
@immutable
class MediaSpec {
  const MediaSpec({
    required this.mxc,
    required this.name,
    this.key,
    this.iv,
    this.size,
    this.limit,
  });

  final Uri mxc;
  final String name;

  /// Base64url JWK `k` and base64 `iv` from an encrypted file map; both or
  /// neither.
  final String? key;
  final String? iv;
  final int? size;

  /// The most bytes to take: a download that goes past it fails. Null takes
  /// what comes.
  final int? limit;
}

/// How much of a file on another site, with no size given, is worth taking.
const externalLimit = 25 * 1000 * 1000;

/// Files on disk under [root], one folder per mxc, downloaded once however
/// many ask, decrypted as they arrive, and trimmed to [capBytes] oldest first.
class MediaStore {
  MediaStore({
    required this.root,
    required this.client,
    required this.downloadUri,
    required this.accessToken,
    this.capBytes = 2000 * 1000 * 1000,
    this.removeFolder = _removeFolder,
  });

  final Directory root;
  final http.Client client;
  final Future<Uri> Function(Uri mxc) downloadUri;
  final String? Function() accessToken;
  final int capBytes;

  /// How an evicted file's folder goes. Here so a test can have one refuse.
  final Future<void> Function(Directory folder) removeFolder;

  static Future<void> _removeFolder(Directory folder) =>
      folder.delete(recursive: true);

  final _running = <Uri, StoredFile>{};
  final _held = <String, int>{};
  bool _disposed = false;

  StoredFile open(MediaSpec spec) {
    final shared = _running[spec.mxc];
    if (shared != null) return shared;
    final file = StoredFile._(this, spec);
    if (_disposed) {
      file._failQuietly(StateError('signed out'));
      return file;
    }
    try {
      final done = File(file._finalPath);
      if (done.existsSync()) {
        // Touched so that what was just opened outlives eviction.
        done.setLastModifiedSync(DateTime.now());
        file._finishFromDisk(done.lengthSync());
        return file;
      }
    } on FileSystemException {
      // Eviction took the folder between the checks: download it again.
    }
    _running[spec.mxc] = file;
    file._start();
    return file;
  }

  /// Deletes the least recently used files until the cache fits [capBytes],
  /// sparing held and still-arriving ones.
  Future<void> evict() => _evicting = _evicting.then((_) async {
    try {
      await _evict();
    } on PathNotFoundException {
      // Signing out removes the folder under a pass in flight; with nothing
      // left on disk there is nothing left to trim.
    } on Object catch (e, st) {
      // Logged, and the chain stays usable: one bad pass must not stop the
      // cap from ever being enforced again.
      Logs().w("[loaf] couldn't trim the media cache", e, st);
    }
  });

  /// Evictions run one after another: two scanning at once would both try to
  /// delete the same folder.
  Future<void> _evicting = Future<void>.value();

  Future<void> _evict() async {
    if (!await root.exists()) return;
    final entries = <_Entry>[];
    var total = 0;
    await for (final dir in root.list()) {
      if (dir is! Directory) continue;
      var size = 0;
      DateTime? newest;
      await for (final f in dir.list()) {
        if (f is! File) continue;
        final stat = await f.stat();
        size += stat.size;
        if (newest == null || stat.modified.isAfter(newest)) {
          newest = stat.modified;
        }
      }
      total += size;
      entries.add(
        _Entry(dir, _basename(dir.path), size, newest ?? DateTime(1970)),
      );
    }
    entries.sort((a, b) => a.modified.compareTo(b.modified));
    final busy = {
      for (final f in _running.values)
        if (!f.complete) f.id,
    };
    for (final e in entries) {
      if (total <= capBytes) break;
      if (_disposed) return;
      if ((_held[e.id] ?? 0) > 0 || busy.contains(e.id)) continue;
      if (await e.dir.exists()) await removeFolder(e.dir);
      total -= e.size;
    }
  }

  /// Fails every running download and stops notifying.
  void dispose() {
    _disposed = true;
    for (final file in _running.values.toList()) {
      file._abandon(StateError('signed out'));
    }
    _running.clear();
  }

  static String _basename(String path) =>
      path.substring(path.lastIndexOf(Platform.pathSeparator) + 1);

  /// The sender's name made safe as one path segment: no directories, no
  /// characters a filesystem refuses, never empty.
  @visibleForTesting
  static String safeName(String name) {
    var s = name.split(RegExp(r'[/\\]')).last;
    s = s.replaceAll(RegExp(r'[:*?"<>|\x00-\x1f]'), '_').trim();
    if (s.isEmpty || s == '.' || s == '..') return 'file';
    return _capped(s);
  }

  /// Most filesystems refuse a name over 255 bytes, and the download adds
  /// `.part`: a name past this would fail every retry.
  static const _maxNameBytes = 200;

  /// [name] cut to [_maxNameBytes] of UTF-8 between characters, keeping a
  /// short extension so the file still opens in the right app.
  static String _capped(String name) {
    if (utf8.encode(name).length <= _maxNameBytes) return name;
    final dot = name.lastIndexOf('.');
    final extension = dot > 0 ? name.substring(dot) : '';
    final keep = utf8.encode(extension).length <= 16 ? extension : '';
    final stem = keep.isEmpty ? name : name.substring(0, dot);
    final budget = _maxNameBytes - utf8.encode(keep).length;
    final out = StringBuffer();
    var used = 0;
    for (final rune in stem.runes) {
      final char = String.fromCharCode(rune);
      final bytes = utf8.encode(char).length;
      if (used + bytes > budget) break;
      out.write(char);
      used += bytes;
    }
    return '$out$keep';
  }
}

class _Entry {
  _Entry(this.dir, this.id, this.size, this.modified);
  final Directory dir;
  final String id;
  final int size;
  final DateTime modified;
}

class StoredFile extends ChangeNotifier implements MediaFile {
  StoredFile._(this._store, this._spec)
    : id = sha256.convert(utf8.encode(_spec.mxc.toString())).toString() {
    final name = MediaStore.safeName(_spec.name);
    _finalPath = '${_store.root.path}/$id/$name';
    partialPath = '$_finalPath.part';
    _path.future.ignore(); // Failures reach callers through [error] as well.
  }

  final MediaStore _store;
  final MediaSpec _spec;
  late final String _finalPath;

  @override
  final String id;
  @override
  late final String partialPath;

  var _path = Completer<String>();
  int _received = 0;
  int? _total;
  bool _complete = false;
  Object? _error;
  bool _dead = false;
  bool _notifyOff = false;
  int _generation = 0;
  StreamIterator<List<int>>? _iterator;

  @override
  int get received => _received;
  @override
  int? get total => _total;
  @override
  bool get complete => _complete;
  @override
  Object? get error => _error;
  @override
  Future<String> get path => _path.future;

  @override
  void hold() => _store._held.update(id, (n) => n + 1, ifAbsent: () => 1);

  @override
  void release() {
    final n = _store._held[id];
    if (n == null) return;
    if (n <= 1) {
      _store._held.remove(id);
    } else {
      _store._held[id] = n - 1;
    }
  }

  @override
  void retry() {
    if (_error == null || _store._disposed) return;
    _error = null;
    _received = 0;
    _total = null;
    _path = Completer<String>()..future.ignore();
    _notify();
    _start();
  }

  @override
  void notifyListeners() {
    if (_notifyOff || _store._disposed) return;
    super.notifyListeners();
  }

  void _notify() => notifyListeners();

  @override
  void dispose() {
    _notifyOff = true;
    super.dispose();
  }

  void _finishFromDisk(int length) {
    _received = length;
    _total = length;
    _complete = true;
    _path.complete(_finalPath);
  }

  void _failQuietly(Object e) {
    _error = e;
    _path.completeError(e);
  }

  /// Sign-out: the download stops, nobody is told by notification.
  void _abandon(Object e) {
    if (_complete || _error != null) return;
    _dead = true;
    _failQuietly(e);
    unawaited(_iterator?.cancel());
  }

  void _start() {
    final gen = ++_generation;
    unawaited(_download(gen));
  }

  Future<void> _download(int gen) async {
    RandomAccessFile? raf;
    http.StreamedResponse? response;
    try {
      final key = _spec.key, iv = _spec.iv;
      CtrDecryptor? decryptor;
      if (key != null || iv != null) {
        if (key == null || iv == null) {
          throw const FormatException('file map has a key or an iv, not both');
        }
        decryptor = CtrDecryptor(key: _b64(key), iv: _b64(iv));
      }

      final dir = Directory('${_store.root.path}/$id');
      await dir.create(recursive: true);
      // A .part left by a quit is never resumed.
      final part = File(partialPath);
      if (await part.exists()) await part.delete();

      // Another site's file is fetched as it stands. The access token is the
      // homeserver's, and goes nowhere else.
      final homeserver = _spec.mxc.isScheme('mxc');
      final uri = homeserver ? await _store.downloadUri(_spec.mxc) : _spec.mxc;
      if (_dead) return;
      final request = http.Request('GET', uri);
      final token = homeserver ? _store.accessToken() : null;
      if (token != null) request.headers['authorization'] = 'Bearer $token';
      response = await _store.client.send(request);
      if (_dead) return;
      if (response.statusCode != 200) {
        throw http.ClientException(
          'the server answered ${response.statusCode}',
          uri,
        );
      }
      final limit = _spec.limit;
      final declared = response.contentLength;
      if (limit != null && declared != null && declared > limit) {
        throw StateError('too big: $declared bytes');
      }
      _total = declared ?? _spec.size;

      raf = await part.open(mode: FileMode.write);
      if (_dead) return;
      final it = _iterator = StreamIterator(response.stream);
      while (await it.moveNext()) {
        if (_dead) return;
        final bytes = decryptor == null
            ? Uint8List.fromList(it.current)
            : decryptor.add(it.current);
        await raf.writeFrom(bytes);
        if (_dead) return;
        _received += bytes.length;
        if (limit != null && _received > limit) {
          throw StateError('too big: over $limit bytes');
        }
        _notify();
      }
      if (_dead) return;
      if (decryptor != null) {
        final tail = decryptor.close();
        await raf.writeFrom(tail);
        _received += tail.length;
      }
      await raf.close();
      raf = null;
      await part.rename(_finalPath);
      response = null;
      _total ??= _received;
      _complete = true;
      _store._running.remove(_spec.mxc);
      _path.complete(_finalPath);
      _notify();
      if (!_store._disposed) unawaited(_store.evict());
    } on Object catch (e) {
      if (_dead || gen != _generation) return;
      await _cleanUp(raf, response);
      raf = null;
      response = null;
      // Signing out during the cleanup has already failed the file.
      if (_dead) return;
      // Whatever cleanup managed, the file ends failed and says so.
      _error = e;
      _path.completeError(e);
      _notify();
    } finally {
      // Every other exit (success, sign-out) still lets go of the connection
      // and the file; a no-op when the catch above already did.
      if (raf != null || response != null) await _cleanUp(raf, response);
    }
  }

  /// Stops the response, closes the file and removes the .part, whichever
  /// of them exist; a failure here is logged, never allowed to hide the
  /// download's own outcome. A finished file has no .part to remove.
  Future<void> _cleanUp(
    RandomAccessFile? raf,
    http.StreamedResponse? response,
  ) async {
    try {
      final it = _iterator;
      _iterator = null;
      if (it != null) {
        await it.cancel();
      } else if (response != null) {
        await response.stream.listen(null).cancel();
      }
      await raf?.close();
      await _deleteQuietly(File(partialPath));
    } on Object catch (e, st) {
      Logs().w("[loaf] couldn't clean up a media download", e, st);
    }
  }

  /// Matrix writes `k` unpadded base64url and `iv` unpadded base64.
  static Uint8List _b64(String s) => base64.decode(
    base64.normalize(s.replaceAll('-', '+').replaceAll('_', '/')),
  );

  /// A .part that is already gone is the goal, not a failure.
  static Future<void> _deleteQuietly(File f) async {
    try {
      await f.delete();
    } on PathNotFoundException {
      return;
    }
  }
}
