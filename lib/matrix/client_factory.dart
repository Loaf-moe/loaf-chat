/// Opens the app's one [Client]. Everything that touches `package:matrix`
/// lives under `lib/matrix/`, so an SDK upgrade stays in one directory.
library;

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:loaf_native/matrix/loaf_http_client.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The `dart:io` client behind the app's requests. Without a connect limit a
/// dead network waits on the OS's own, which is minutes.
HttpClient ioHttpClient() =>
    HttpClient()..connectionTimeout = const Duration(seconds: 10);

/// What [openClient] sends through when a test supplies none.
http.Client defaultHttpClient() => IOClient(ioHttpClient());

/// [databasePath] defaults to a file in the app's support directory; tests
/// pass `inMemoryDatabasePath`. [httpClient] is for tests too, as are
/// [sendTimeout] and [wrap], which let one shorten the limits that are 30 s
/// for real.
///
/// [mediaPath] is where downloaded pictures are kept between launches. The
/// SDK stores none without it, so it defaults beside the database and, when
/// a test names only a database, to nowhere.
Future<Client> openClient({
  http.Client? httpClient,
  String? databasePath,
  String? mediaPath,
  Duration? sendTimeout,
  LoafHttpClient Function(http.Client inner)? wrap,
}) async {
  // The sqlite3 package bundles sqlite through build hooks on every
  // platform, so one ffi factory serves iOS, macOS and Linux alike.
  sqfliteFfiInit();
  final path =
      databasePath ??
      '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}loaf.sqlite';
  final media =
      mediaPath ??
      (databasePath == null
          ? '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}media'
          : null);
  if (media != null) await Directory(media).create(recursive: true);
  final database = await MatrixSdkDatabase.init(
    'loaf',
    database: await databaseFactoryFfi.openDatabase(
      path,
      // Each in-memory open must be its own database, or tests share one.
      options: OpenDatabaseOptions(singleInstance: false),
    ),
    sqfliteFactory: databaseFactoryFfi,
    fileStorageLocation: media == null ? null : Directory(media).uri,
    // Avatars come back from the server if they are wanted again.
    deleteFilesAfterDuration: const Duration(days: 30),
  );
  return Client(
    'loaf',
    database: database,
    httpClient: (wrap ?? LoafHttpClient.new)(httpClient ?? defaultHttpClient()),
    // The SDK keeps retrying a failed send until this runs out, and marks
    // an echo older than it failed on load; its default is a minute. 30 s
    // is how long a dead network takes to read "didn't send".
    sendTimelineEventTimeout: sendTimeout ?? const Duration(seconds: 30),
    // The SDK keeps only a room list's state in memory for rooms not open.
    // These are what the channel list and member list read on top of that:
    // a channel's topic and lock, and who is an admin or moderator.
    importantStateEvents: {
      EventTypes.RoomTopic,
      EventTypes.RoomJoinRules,
      EventTypes.RoomPowerLevels,
    },
    // The 7 emoji only: the spec draws no QR, and a client that names no
    // method can take part in no verification at all.
    verificationMethods: {KeyVerificationMethod.emoji},
  );
}
