/// What a verification panel can be showing, as plain values. See
/// "Verifying a session" in the design spec.
library;

import 'package:flutter/foundation.dart';

/// Why the panel is open: to verify this session, to give a fresh account an
/// identity, or to vouch for another device of yours.
enum VerifyPurpose { verify, setUp, incoming }

enum VerifyStep {
  choose,

  /// `m.key.verification.request` is out; nobody has accepted yet.
  waitingForDevice,

  /// Another device asks this one to vouch for it.
  incomingPrompt,

  /// SAS: the 7 emoji both ends show.
  compareEmoji,

  /// This end said they match; the other has not yet.
  waitingForOther,

  /// A mismatch, a refusal or no answer. Nothing was trusted.
  cancelled,

  /// Incoming, refused as not you.
  notMe,

  recoveryKey,

  /// Secret storage unlocked; key backup is being pulled in.
  restoring,

  resetConfirm,

  /// User-interactive auth before new cross-signing keys go up.
  resetAuth,

  setUpIntro,
  showKey,
  done,
}

/// One SAS emoji and the name printed under it, so two people can read the
/// comparison aloud.
@immutable
class SasEmoji {
  const SasEmoji(this.emoji, this.name);

  final String emoji;
  final String name;
}

@immutable
class VerifyState {
  const VerifyState({
    required this.step,
    this.checking = false,
    this.rejected = false,
    this.restored = 0,
    this.totalKeys = 0,
    this.keySaved = false,
    this.inBrowser = false,
    this.closing = false,
  });

  final VerifyStep step;

  /// A key or password is being checked.
  final bool checking;

  /// The last key or password was wrong.
  final bool rejected;

  /// Key backup progress, while [step] is restoring.
  final int restored;
  final int totalKeys;

  /// The new recovery key was copied or saved at least once.
  final bool keySaved;

  /// Reset's SSO re-auth is in the real browser (desktop).
  final bool inBrowser;

  /// Done has lingered long enough to be read; the panel should go.
  final bool closing;
}
