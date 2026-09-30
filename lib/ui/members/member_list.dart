/// Who is in the space: admins in their own section up top, everyone else
/// below, each with a presence dot and a name coloured by power level.
library;

import 'package:flutter/material.dart';

import '../mock/fixtures.dart';
import '../theme/loaf_theme.dart';
import '../widgets/loaf_avatar.dart';
import 'presence.dart';
import 'presence_dot.dart';
import 'role_colors.dart';

/// Splits [members] into the two sections the list shows. Moderators stay
/// with members: their name colour already sets them apart, and a third
/// section would start to become the roles UI the spec defers.
///
/// Within each section online people come first, then alphabetical — the
/// people you could talk to right now are the ones you are looking for.
///
/// Someone whose presence is unknown sorts between the two: they may well
/// be around, but nothing says so.
({List<Member> admins, List<Member> members}) groupMembers(
  Iterable<Member> members,
) {
  int rank(Member m) => switch (m.presence) {
    Presence.unknown => 1,
    Presence.offline => 2,
    _ => 0,
  };
  int byPresenceThenName(Member a, Member b) {
    final byRank = rank(a).compareTo(rank(b));
    if (byRank != 0) return byRank;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  final admins = members.where((m) => m.role == Role.admin).toList()
    ..sort(byPresenceThenName);
  final rest = members.where((m) => m.role != Role.admin).toList()
    ..sort(byPresenceThenName);
  return (admins: admins, members: rest);
}

class MemberList extends StatelessWidget {
  const MemberList({super.key, required this.members});

  final List<Member> members;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    // On a server without presence, everyone is unknown: one list by role
    // and name, nobody faded.
    final groups = groupMembers([
      for (final m in members)
        m.copyWith(presence: PresenceScope.effective(context, m.presence)),
    ]);

    return ColoredBox(
      color: tokens.sidebar,
      // Background runs edge to edge; only the list keeps clear of the
      // status bar and home indicator, matching the navigation drawer.
      child: SafeArea(
        left: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: LoafSpace.x4),
          children: [
            if (groups.admins.isNotEmpty)
              _Section(title: 'Admins', members: groups.admins, tokens: tokens),
            if (groups.members.isNotEmpty)
              _Section(
                title: 'Members',
                members: groups.members,
                tokens: tokens,
              ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.members,
    required this.tokens,
  });

  final String title;
  final List<Member> members;
  final LoafTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          // Same heading metrics as channel categories, so the two drawers
          // read as a pair.
          padding: const EdgeInsets.fromLTRB(16, 16, 12, 4),
          child: Text(
            '${title.toUpperCase()} — ${members.length}',
            style: loafBody(
              11,
              600,
              height: 1.3,
            ).copyWith(color: tokens.textMuted, letterSpacing: 0.04 * 11),
          ),
        ),
        for (final member in members)
          _MemberRow(member: member, tokens: tokens),
      ],
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({required this.member, required this.tokens});

  final Member member;
  final LoafTokens tokens;

  @override
  Widget build(BuildContext context) {
    // Offline people fade back rather than disappearing: still findable,
    // clearly not around.
    final status = member.statusMessage;
    //
    // Not a button: there is no profile to open yet, and a row that ripples
    // and then does nothing promises what it cannot keep.
    return Opacity(
      key: ValueKey('member-${member.id}'),
      opacity: member.presence == Presence.offline ? 0.5 : 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        child: Row(
          children: [
            _PresenceAvatar(member: member, tokens: tokens),
            const SizedBox(width: LoafSpace.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    member.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: loafBody(
                      15,
                      500,
                    ).copyWith(color: tokens.nameColor(member.role)),
                  ),
                  if (status != null)
                    Text(
                      status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: loafBody(
                        12,
                        400,
                      ).copyWith(color: tokens.textMuted),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PresenceAvatar extends StatelessWidget {
  const _PresenceAvatar({required this.member, required this.tokens});

  static const _size = 32.0;

  final Member member;
  final LoafTokens tokens;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _size,
      height: _size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          LoafAvatar(
            label: member.initials,
            color: member.color,
            size: _size,
            image: member.avatar,
            textStyle: loafBody(12, 600),
          ),
          Positioned(
            right: -2,
            bottom: -2,
            child: PresenceDot(presence: member.presence, ring: tokens.sidebar),
          ),
        ],
      ),
    );
  }
}
