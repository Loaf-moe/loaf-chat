/// How the fake people behave in calls: who answers a ring, who arrives
/// muted or with their camera on. Kept apart from the plain fixtures so
/// those do not depend on the call controller.
library;

import '../call/call_controller.dart';
import 'fixtures.dart';

Member _member(String id) =>
    mockSpaces.first.members.firstWhere((m) => m.id == id);

/// Mika picks up, Sam (do not disturb) declines, everyone else lets it
/// ring out — so each outgoing ending can be seen from one of the DMs.
const mockRings = {
  '@mika': RingBehaviour.answer(Duration(seconds: 3)),
  '@sam': RingBehaviour.decline(Duration(seconds: 2)),
};

final mockCallFlags = {
  '@sam': CallParticipant(_member('@sam'), muted: true),
  '@jun': CallParticipant(_member('@jun'), camera: true),
};
