import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/mock/mock_session.dart';

void main() {
  test('opens signed in on an unverified device', () {
    final s = MockSession();
    expect(s.account, AccountState.signedIn);
    expect(s.trust, DeviceTrust.unverified);
    expect(s.userId, '@faore:loaf.moe');
    expect(s.softLogout, isNull);
  });

  test('signing out loses the device, so the next one starts unverified', () {
    final s = MockSession(trust: DeviceTrust.verified)..signOut();
    expect(s.account, AccountState.signedOut);
    s.signedIn();
    expect(s.trust, DeviceTrust.unverified);
  });

  test('a soft logout keeps the keys, so trust survives it', () {
    final s = MockSession(trust: DeviceTrust.verified)..expireSession();
    expect(s.account, AccountState.softLoggedOut);
    expect(s.softLogout!.userId, '@faore:loaf.moe');
    s.signedIn();
    expect(s.trust, DeviceTrust.verified);
  });

  test('only a signed-in session can expire', () {
    final s = MockSession()
      ..signOut()
      ..expireSession();
    expect(s.account, AccountState.signedOut);
  });

  test('the failure lever is spent once', () {
    final s = MockSession()..failNext();
    expect(s.consumeFailure(), isTrue);
    expect(s.consumeFailure(), isFalse);
  });

  test('verifying marks the device trusted', () {
    final s = MockSession()..markVerified();
    expect(s.trust, DeviceTrust.verified);
  });

  test('a fresh account has no identity to verify against', () {
    final s = MockSession()..useFreshAccount();
    expect(s.trust, DeviceTrust.noIdentity);
  });

  test('a request arrives on a trusted device and can be cleared', () {
    final s = MockSession()..receiveRequest();
    // Only a verified device is asked to vouch for another.
    expect(s.trust, DeviceTrust.verified);
    expect(s.incoming, isNotNull);
    s.clearIncoming();
    expect(s.incoming, isNull);
  });
}
