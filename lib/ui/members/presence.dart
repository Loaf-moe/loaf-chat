/// Matrix presence, in the words people use. See "Presence and status" in
/// the design spec for how each maps onto the protocol.
library;

/// How someone appears to others.
enum Presence {
  online,

  /// Matrix `unavailable`: set automatically after a stretch of inactivity,
  /// or pinned by choosing it.
  idle,

  /// MSC3026's `busy` where the server has it. Choosing it also turns on the
  /// account's master push rule, silencing every device.
  dnd,
  offline,

  /// Nothing known. Presence is optional for a server: when theirs, or
  /// yours, does not share it, no presence ever arrives — which is not the
  /// same as being offline, so it is not drawn as offline.
  unknown;

  /// Online, idle and do-not-disturb people are all around; lists sort them
  /// ahead of offline ones.
  bool get around => this == online || this == idle || this == dnd;
}

/// What you can choose for yourself. Invisible is a choice, not a state
/// others see: it syncs with `set_presence=offline`, so you appear offline
/// while still connected.
enum PresenceChoice {
  online('online', 'around and chatting'),
  idle('idle', 'shows you as away'),
  dnd('do not disturb', 'silences notifications on all your devices'),
  invisible('invisible', "you'll appear offline, but can still chat");

  const PresenceChoice(this.label, this.description);

  final String label;
  final String description;

  Presence get shown => switch (this) {
    PresenceChoice.online => Presence.online,
    PresenceChoice.idle => Presence.idle,
    PresenceChoice.dnd => Presence.dnd,
    PresenceChoice.invisible => Presence.offline,
  };
}
