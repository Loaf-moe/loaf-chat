/// How far this device is trusted, read from the SDK's device keys. The
/// session's notice and a room's composer both read it here, so they never
/// disagree.
library;

import 'package:matrix/matrix.dart';

import '../ui/auth/loaf_session.dart';

DeviceTrust trustOf(Client client) {
  final userId = client.userID;
  final keys = userId == null ? null : client.userDeviceKeys[userId];
  // Until this account's keys are known, never claim it has no identity:
  // that notice offers to make one, and would reset a real one.
  if (keys == null || keys.outdated) return DeviceTrust.unverified;
  if (keys.masterKey == null) return DeviceTrust.noIdentity;
  return client.isUnknownSession
      ? DeviceTrust.unverified
      : DeviceTrust.verified;
}
