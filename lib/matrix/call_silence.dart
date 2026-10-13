/// What a room's moderators have put on people in its call: a state event
/// each client reads about its own user and obeys. Loaf Chat's own; the
/// media server knows nothing of it.
library;

import 'package:matrix/matrix.dart';

import '../ui/model/models.dart';

const callSilenceType = 'moe.loaf.call.moderation';

/// The state key of the entry about [userId]. Not the bare id: a state key
/// that begins with `@` may only be written by that user.
String callSilenceKey(String userId) => '_$userId';

/// What is written to put [silence] on someone, or with null to lift it.
Map<String, Object?> callSilenceContent(CallSilence? silence) =>
    switch (silence) {
      null => const {},
      CallSilence.muted => const {'muted': true, 'deafened': false},
      CallSilence.deafened => const {'muted': true, 'deafened': true},
    };

/// Who is silenced, by user id, as [events] of [callSilenceType] say.
Map<String, CallSilence> callSilences(Iterable<MatrixEvent> events) => {
  for (final event in events)
    if (event.type == callSilenceType)
      if (event.stateKey case final key? when key.startsWith('_@'))
        if (event.content['deafened'] == true)
          key.substring(1): CallSilence.deafened
        else if (event.content['muted'] == true)
          key.substring(1): CallSilence.muted,
};
