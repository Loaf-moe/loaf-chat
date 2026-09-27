import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/matrix/matrix_device_verification.dart';
import 'package:loaf_native/ui/verify/verifier.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';

import 'crypto_harness.dart';

/// Two clients, @test and @othertest, verify each other in their direct
/// chat, the way the SDK's own tests do: the fake server delivers nothing,
/// so each event is relayed by hand. The handle neither knows nor cares
/// whether its verification travels in a room or to a device.
void main() {
  late Client mine;
  late Client theirs;

  setUp(() async {
    mine = await cryptoClient();
    theirs = await cryptoClient(api: FakeMatrixApi.currentApi, asOther: true);
    await mine.updateUserDeviceKeys(additionalUsers: {other});
    await theirs.updateUserDeviceKeys(additionalUsers: {me});
    // An unverified master key asks for nothing before the request goes out.
    mine.userDeviceKeys[me]!.masterKey!.setDirectVerified(false);
  });

  const room = '/client/v3/rooms/!1234%3AfakeServer.notExisting/send/';

  /// Delivers [from]'s first event since the record was cleared to [to],
  /// and waits for [to] to answer with [answer], if given.
  Future<void> relay(KeyVerification from, Client to, {String? answer}) async {
    final event = sentVerification(
      from.client,
      from.transactionId!,
      from.room!,
    );
    FakeMatrixApi.calledEndpoints.clear();
    await to.encryption!.keyVerificationManager.handleEventUpdate(event);
    if (answer != null) await sentTo('$room$answer');
  }

  /// Runs a request from [mine] until both ends show emoji.
  Future<(KeyVerification, KeyVerification)> toEmoji() async {
    FakeMatrixApi.calledEndpoints.clear();
    final req1 = await mine.userDeviceKeys[other]!.startVerification(
      newDirectChatEnableEncryption: false,
    );
    await sentTo('${room}m.room.message');
    final arrived = theirs.onKeyVerificationRequest.stream.first;
    await relay(req1, theirs);
    final req2 = await arrived;
    FakeMatrixApi.calledEndpoints.clear();
    await req2.acceptVerification();
    await sentTo('${room}m.key.verification.ready');
    await relay(req2, mine, answer: 'm.key.verification.start');
    await relay(req1, theirs, answer: 'm.key.verification.accept');
    await relay(req2, mine, answer: 'm.key.verification.key');
    await relay(req1, theirs, answer: 'm.key.verification.key');
    await relay(req2, mine);
    return (req1, req2);
  }

  test('the emoji run reads as the panel\'s phases, to done', () async {
    final (req1, req2) = await toEmoji();
    final a = MatrixDeviceVerification(req1);
    final b = MatrixDeviceVerification(req2);
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    expect(a.phase, DevicePhase.emoji);
    expect(b.phase, DevicePhase.emoji);
    expect(a.emoji, hasLength(7));
    expect(
      [for (final e in a.emoji) e.name],
      [for (final e in b.emoji) e.name],
    );

    var told = 0;
    a.addListener(() => told++);
    FakeMatrixApi.calledEndpoints.clear();
    a.match();
    await sentTo('${room}m.key.verification.mac');
    expect(a.phase, DevicePhase.waitingForOther);
    expect(told, greaterThan(0));

    await relay(req1, theirs);
    FakeMatrixApi.calledEndpoints.clear();
    b.match();
    await sentTo('${room}m.key.verification.done');
    await relay(req2, mine, answer: 'm.key.verification.done');
    expect(a.phase, DevicePhase.done);
    expect(b.phase, DevicePhase.done);
    expect(a.emoji, isEmpty);
  });

  test('a mismatch ends it at both ends', () async {
    final (req1, req2) = await toEmoji();
    final a = MatrixDeviceVerification(req1);
    final b = MatrixDeviceVerification(req2);
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    FakeMatrixApi.calledEndpoints.clear();
    a.mismatch();
    await sentTo('${room}m.key.verification.cancel');
    expect(a.phase, DevicePhase.cancelled);
    await relay(req1, theirs);
    expect(b.phase, DevicePhase.cancelled);
  });

  test('an incoming request waits for yes', () async {
    FakeMatrixApi.calledEndpoints.clear();
    final req1 = await mine.userDeviceKeys[other]!.startVerification(
      newDirectChatEnableEncryption: false,
    );
    await sentTo('${room}m.room.message');
    final arrived = theirs.onKeyVerificationRequest.stream.first;
    await relay(req1, theirs);
    final b = MatrixDeviceVerification(await arrived);
    addTearDown(b.dispose);
    expect(b.phase, DevicePhase.waiting);
    FakeMatrixApi.calledEndpoints.clear();
    b.accept();
    await sentTo('${room}m.key.verification.ready');
  });

  test('vouching asks for the key when this device lacks its own', () async {
    // A verified identity whose secrets aren't on this device.
    mine.userDeviceKeys[me]!.masterKey!.setDirectVerified(true);
    await mine.encryption!.ssss.clearCache();
    final req = await mine.userDeviceKeys[other]!.startVerification(
      newDirectChatEnableEncryption: false,
    );
    final a = MatrixDeviceVerification(req);
    addTearDown(a.dispose);
    expect(a.phase, DevicePhase.needsKey);
    expect(await a.unlock('EsT9 not the key'), UnlockResult.wrongKey);
    expect(await a.unlock('not the passphrase'), UnlockResult.wrongKey);
    expect(a.phase, DevicePhase.needsKey);
    FakeMatrixApi.calledEndpoints.clear();
    expect(await a.unlock(fixtureRecoveryKey), UnlockResult.unlocked);
    await sentTo('${room}m.room.message');
    expect(a.phase, DevicePhase.waiting);
    a.cancel();
  });

  group('asking your other devices', () {
    test('goes out to every device, and waits', () async {
      FakeMatrixApi.calledEndpoints.clear();
      final a = MatrixDeviceVerification.request(mine);
      addTearDown(a.dispose);
      expect(a.phase, DevicePhase.waiting);
      // To your own devices it goes olm-encrypted.
      await sentTo('/client/v3/sendToDevice/m.room.encrypted');
      expect(a.phase, DevicePhase.waiting);
    });

    test('put away while going out, it is withdrawn', () async {
      FakeMatrixApi.calledEndpoints.clear();
      MatrixDeviceVerification.request(mine).dispose();
      // The request, then the cancel, both olm-encrypted.
      await sentTo('/client/v3/sendToDevice/m.room.encrypted');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        FakeMatrixApi.calledEndpoints.keys.where(
          (e) => e.startsWith('/client/v3/sendToDevice/m.room.encrypted'),
        ),
        hasLength(2),
      );
    });

    test('an account without keys cannot ask, and says so', () async {
      mine.userDeviceKeys.remove(me);
      final a = MatrixDeviceVerification.request(mine);
      addTearDown(a.dispose);
      await Future<void>.delayed(Duration.zero);
      expect(a.phase, DevicePhase.cancelled);
    });
  });
}
