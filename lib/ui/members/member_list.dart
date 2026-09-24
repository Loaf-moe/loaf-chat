/// Who is in the space: admins in their own section up top, everyone else
/// below, each with a presence dot and a name coloured by power level.
library;

import 'package:flutter/material.dart';

import '../mock/fixtures.dart';
import '../theme/loaf_theme.dart';
import 'role_colors.dart';

/// Splits [members] into the two sections the list shows. Moderators stay
/// with members: their name colour already sets them apart, and a third
/// section would start to become the roles UI the spec defers.
///
/// Within each section online people come first, then alphabetical — the
/// people you could talk to right now are the ones you are looking for.
({List<Member> admins, List<Member> members}) groupMembers(
  Iterable<Member> members,
) {
  int byPresenceThenName(Member a, Member b) {
    if (a.online != b.online) return a.online ? -1 : 1;
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
    final groups = groupMembers(members);

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
    return Opacity(
      opacity: member.online ? 1 : 0.5,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        child: InkWell(
          borderRadius: BorderRadius.circular(LoafRadius.md),
          onTap: () {},
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                _PresenceAvatar(member: member, tokens: tokens),
                const SizedBox(width: LoafSpace.x3),
                Expanded(
                  child: Text(
                    member.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: loafBody(
                      15,
                      500,
                    ).copyWith(color: tokens.nameColor(member.role)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PresenceAvatar extends StatelessWidget {
  const _PresenceAvatar({required this.member, required this.tokens});

  static const _size = 32.0;
  static const _dot = 12.0;

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
          Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: member.color,
              shape: BoxShape.circle,
            ),
            child: Text(
              member.initials,
              style: loafBody(12, 600).copyWith(color: Colors.white),
            ),
          ),
          Positioned(
            right: -2,
            bottom: -2,
            // The sidebar-coloured ring cuts the dot out of the avatar, so it
            // reads as a badge rather than a blob touching the circle.
            child: Container(
              width: _dot,
              height: _dot,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: member.online ? tokens.online : tokens.sidebar,
                border: Border.all(
                  color: member.online ? tokens.sidebar : tokens.textMuted,
                  width: member.online ? 2.5 : 2,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
