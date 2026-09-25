/// The one presence mark, wherever a person's presence is shown.
library;

import 'package:flutter/material.dart';

import '../theme/loaf_theme.dart';
import 'presence.dart';

class PresenceDot extends StatelessWidget {
  PresenceDot({required this.presence, required this.ring, this.size = 12})
    : super(key: ValueKey('presence-${presence.name}'));

  final Presence presence;

  /// The surface behind the dot. The ring in this colour cuts the dot out of
  /// the avatar, so it reads as a badge rather than a blob touching it.
  final Color ring;

  final double size;

  @override
  Widget build(BuildContext context) {
    // Absent means absent: no question mark on every avatar.
    if (!PresenceScope.known(context, presence)) return const SizedBox.shrink();
    final tokens = LoafTokens.of(context);
    final offline = presence == Presence.offline;
    final fill = switch (presence) {
      Presence.online => tokens.online,
      Presence.idle => tokens.idle,
      Presence.dnd => tokens.accent,
      Presence.offline || Presence.unknown => ring,
    };
    // Every state draws the same inner disc inside the same ring, so a
    // hollow offline mark is exactly as big as a filled one.
    final inner = size * 0.6;

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(shape: BoxShape.circle, color: ring),
      child: Container(
        width: inner,
        height: inner,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: fill,
          border: offline
              ? Border.all(color: tokens.textMuted, width: inner / 4)
              : null,
        ),
        // Do not disturb carries a bar, so it does not rely on red alone.
        child: presence == Presence.dnd
            ? Container(
                width: inner * 0.6,
                height: inner / 5,
                decoration: BoxDecoration(
                  color: ring,
                  borderRadius: BorderRadius.circular(inner),
                ),
              )
            : null,
      ),
    );
  }
}

/// Whether your own server shares presence at all. Presence reaches you
/// through your homeserver, so when it is off there, nobody's arrives —
/// and every dot, fade and presence choice goes with it.
class PresenceScope extends InheritedWidget {
  const PresenceScope({super.key, required this.shared, required super.child});

  final bool shared;

  /// Shared unless something above says otherwise.
  static bool sharedOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PresenceScope>()?.shared ??
      true;

  /// [presence] as this screen can know it: unknown on a server that
  /// shares none.
  static Presence effective(BuildContext context, Presence presence) =>
      sharedOf(context) ? presence : Presence.unknown;

  static bool known(BuildContext context, Presence presence) =>
      effective(context, presence) != Presence.unknown;

  @override
  bool updateShouldNotify(PresenceScope oldWidget) =>
      shared != oldWidget.shared;
}
