import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_media/loaf_media.dart';

/// Stands in for xdg-desktop-portal: records what OpenFile was given.
class _FakePortal extends DBusObject {
  _FakePortal({this.error})
    : super(DBusObjectPath('/org/freedesktop/portal/desktop'));

  /// When set, OpenFile answers with this error instead.
  final DBusMethodErrorResponse? error;

  DBusMethodCall? call;

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != 'org.freedesktop.portal.OpenURI' ||
        methodCall.name != 'OpenFile') {
      return DBusMethodErrorResponse.unknownMethod();
    }
    call = methodCall;
    return error ??
        DBusMethodSuccessResponse([
          DBusObjectPath('/org/freedesktop/portal/desktop/request/1_1/t'),
        ]);
  }
}

void main() {
  late Directory dir;
  late DBusServer server;
  late DBusClient portalSide;
  late DBusClient appSide;

  Future<_FakePortal> serve(_FakePortal portal) async {
    await portalSide.requestName('org.freedesktop.portal.Desktop');
    await portalSide.registerObject(portal);
    return portal;
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('loaf-portal-test');
    server = DBusServer();
    final address = await server.listenAddress(DBusAddress.unix(dir: dir));
    // The private bus does not check who connects; naming a uid lets the
    // client authenticate on a Mac too, where it cannot look its own up.
    portalSide = DBusClient(address, authClient: DBusAuthClient(uid: '0'));
    appSide = DBusClient(address, authClient: DBusAuthClient(uid: '0'));
  });

  tearDown(() async {
    await appSide.close();
    await portalSide.close();
    await server.close();
    dir.deleteSync(recursive: true);
  });

  test(
    'open file passes the file as a descriptor and an empty window',
    () async {
      final portal = await serve(_FakePortal());
      final file = File('${dir.path}/recipe.pdf')..writeAsStringSync('flour');

      await OpenUriPortal(appSide).openFile(file.path);

      final call = portal.call;
      expect(call, isNotNull);
      expect(call!.signature, DBusSignature('sha{sv}'));
      expect(call.values[0], const DBusString(''));
      final fd = call.values[1].asUnixFd();
      final received = fd.toFile();
      try {
        expect(await received.read(5), 'flour'.codeUnits);
      } finally {
        await received.close();
      }
      expect(call.values[2].asStringVariantDict(), isEmpty);
    },
  );

  test('an error reply is a PortalError', () async {
    await serve(
      _FakePortal(
        error: DBusMethodErrorResponse(
          'org.freedesktop.portal.Error.NotFound',
          [const DBusString('no app for this')],
        ),
      ),
    );
    final file = File('${dir.path}/mystery.bin')..writeAsStringSync('?');

    await expectLater(
      OpenUriPortal(appSide).openFile(file.path),
      throwsA(
        isA<PortalError>()
            .having(
              (e) => e.name,
              'name',
              'org.freedesktop.portal.Error.NotFound',
            )
            .having((e) => e.message, 'message', 'no app for this'),
      ),
    );
  });
}
