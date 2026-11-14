/// Somewhere small settings live between runs: in memory for tests and the
/// mock, or as JSON in a file.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'files.dart';

/// A value that can be written as JSON, and read back by its type's
/// `fromJson`.
abstract interface class Jsonable {
  Object? toJson();
}

abstract interface class Store<T> {
  /// Null when nothing has been saved, or what was saved can't be read.
  Future<T?> load();

  Future<void> save(T value);
}

/// Forgets on exit: for tests and the mock backend.
class MemoryStore<T> implements Store<T> {
  MemoryStore([this.saved]);

  T? saved;

  @override
  Future<T?> load() async => saved;

  @override
  Future<void> save(T value) async => saved = value;
}

class JsonFileStore<T extends Jsonable> implements Store<T> {
  JsonFileStore(this.file, this._fromJson);

  /// [name] in the app's support folder, beside the account's database.
  static Future<JsonFileStore<T>> inSupportDirectory<T extends Jsonable>(
    String name,
    T Function(Object? json) fromJson,
  ) async => JsonFileStore(
    File(p.join((await getApplicationSupportDirectory()).path, name)),
    fromJson,
  );

  final File file;
  final T Function(Object? json) _fromJson;

  @override
  Future<T?> load() async {
    try {
      return _fromJson(jsonDecode(await file.readAsString()));
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// Atomic: a crash mid-save leaves the last settings, not an empty file.
  @override
  Future<void> save(T value) =>
      writeAtomically(file, utf8.encode(jsonEncode(value.toJson())));
}
