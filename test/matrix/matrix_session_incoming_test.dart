import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/matrix/matrix_session.dart';
import 'package:loaf_native/matrix/sso_browser.dart';
import 'package:loaf_native/ui/verify/verifier.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';

import 'crypto_harness.dart';

/// Another of your devices asking this one to verify it, as the session
/// surfaces it for the shell's "is this you?" — or someone else asking to
/// verify you.
void main() {
  late Client client;
  late MatrixSession session;

  setUp(() async {
    client = await cryptoClient();
    session = MatrixSession(
      client,
      browser: () => LoopbackSsoBrowser(open: (_) async => false),
      deviceName: 'loaf on test',
    );
  });

  KeyVerification requestFrom(String userId, String deviceId) =>
      KeyVerification(
        encryption: client.encryption!,
        userId: userId,
        deviceId: deviceId,
      )..state = KeyVerificationState.askAccept;

  Future<void> arrive(KeyVerification request) async {
    client.onKeyVerificationRequest.add(request);
    await Future<void>.delayed(Duration.zero);
  }

  test('a request from your own device asks "is this you?"', () async {
    var told = 0;
    session.addListener(() => told++);
    await arrive(requestFrom(me, 'OTHERDEVICE'));
    final incoming = session.incoming!;
    final keys = client.userDeviceKeys[me]!.deviceKeys['OTHERDEVICE']!;
    expect(incoming.device, keys.deviceDisplayName ?? 'OTHERDEVICE');
    expect(incoming.verification.phase, DevicePhase.waiting);
    expect(told, 1);
  });

  test("someone else's request asks to verify them, by name", () async {
    var told = 0;
    session.addListener(() => told++);
    await arrive(requestFrom(other, 'FOXDEVICE'));
    final incoming = session.incoming!;
    // Sent to-device, so no room names them: the localpart stands in.
    expect(incoming.person, 'othertest');
    expect(incoming.verification.phase, DevicePhase.waiting);
    expect(told, 1);
  });

  test(
    "someone else's request in a room names them as the room does",
    () async {
      final room = client.rooms.first;
      final request = KeyVerification(
        encryption: client.encryption!,
        userId: other,
        room: room,
      )..state = KeyVerificationState.askAccept;
      await arrive(request);
      expect(
        session.incoming!.person,
        room.unsafeGetUserFromMemoryOrFallback(other).calcDisplayname(),
      );
    },
  );

  test('answering it puts it away', () async {
    await arrive(requestFrom(me, 'OTHERDEVICE'));
    var told = 0;
    session.addListener(() => told++);
    session.clearIncoming();
    expect(session.incoming, isNull);
    expect(told, 1);
  });

  test('a second request while one is being answered is dropped', () async {
    await arrive(requestFrom(me, 'OTHERDEVICE'));
    final first = session.incoming;
    await arrive(requestFrom(me, 'NEWDEVICE'));
    expect(session.incoming, same(first));
    expect(first!.verification.phase, DevicePhase.waiting);
  });

  tearDown(() => session.dispose());
}
