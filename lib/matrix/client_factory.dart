/// Opens the app's one [Client]. Everything that touches `package:matrix`
/// lives under `lib/matrix/`, so an SDK upgrade stays in one directory.
library;

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// [databasePath] defaults to a file in the app's support directory; tests
/// pass `inMemoryDatabasePath`. [httpClient] is for tests too.
Future<Client> openClient({
  http.Client? httpClient,
  String? databasePath,
}) async {
  // The sqlite3 package bundles sqlite through build hooks on every
  // platform, so one ffi factory serves iOS, macOS and Linux alike.
  sqfliteFfiInit();
  final path =
      databasePath ??
      '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}loaf.sqlite';
  final database = await MatrixSdkDatabase.init(
    'loaf',
    database: await databaseFactoryFfi.openDatabase(
      path,
      // Each in-memory open must be its own database, or tests share one.
      options: OpenDatabaseOptions(singleInstance: false),
    ),
    sqfliteFactory: databaseFactoryFfi,
  );
  return Client('loaf', database: database, httpClient: httpClient);
}
