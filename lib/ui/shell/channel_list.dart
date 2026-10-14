/// The middle column: a space's categories and channels.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../call/call_tile.dart';
import '../call/volume_slider.dart';
import '../members/person_card.dart';
import '../members/presence_dot.dart';
import '../mock/fixtures.dart';
import '../platform.dart';
import '../settings/voice_settings.dart';
import '../theme/loaf_theme.dart';
import '../widgets/action_menu.dart';
import '../widgets/count_label.dart';
import '../widgets/loaf_avatar.dart';
import '../widgets/speaking_ring.dart';
import '../window/window_chrome.dart';
import 'channel_actions.dart';
import 'user_bar.dart';

class ChannelList extends StatefulWidget {
  const ChannelList({
    super.key,
    required this.space,
    required this.selectedChannelId,
    required this.onSelect,
    this.onAction,
    this.ringingId,
    this.home = false,
    this.invites = const [],
    this.selectedInviteId,
    this.onOpenInvite,
    this.onReorderFavourites,
    this.onNewMessage,
    this.allowedActions,
    this.call,
    required this.myId,
    this.onHangUp,
    this.onSilence,
  });

  final Space space;

  /// Asked to take [member] out of [channel]'s call. Left null, nobody's
  /// menu offers it.
  final void Function(Channel channel, Member member)? onHangUp;

  /// Asked to put [silence] on [member] in [channel]'s call for everyone,
  /// or with null to lift it. Left null, nobody's menu offers it.
  final void Function(Channel channel, Member member, CallSilence? silence)?
  onSilence;

  /// Your own user id: your row under a voice channel has no menu.
  final String myId;

  /// The call you are in: its channel, and how each of its people is heard,
  /// you among them. Null in no call, or one that is not connected.
  final ({String channelId, List<TileInfo> people})? call;

  /// Home only: the "+" on the direct messages heading.
  final VoidCallback? onNewMessage;

  /// Home rather than a space: sections instead of admin-made categories,
  /// no space menu, and rows that can be tagged.
  final bool home;

  /// Home only: shown above everything else, since they wait on you.
  final List<Invite> invites;
  final String? selectedInviteId;
  final ValueChanged<String>? onOpenInvite;

  /// Home only: the favourites' ids in their new order after a drag.
  final ValueChanged<List<String>>? onReorderFavourites;

  /// A direct chat whose call is ringing at you.
  final String? ringingId;
  final String selectedChannelId;
  final ValueChanged<String> onSelect;

  /// Receives what was picked from a channel's actions (long press on a
  /// phone, right-click on a computer). Left null, channels have no menu.
  final void Function(String channelId, ChannelAction action)? onAction;

  /// The row actions the backend can do yet; null for all of them. A row
  /// left with none opens no menu.
  final Set<ChannelAction>? allowedActions;

  @override
  State<ChannelList> createState() => _ChannelListState();
}

class _ChannelListState extends State<ChannelList> {
  /// Categories you have opened or closed. Anything not in here falls back
  /// to its default: open, except Home's low priority.
  final Map<String, bool> _collapsed = {};

  bool _isCollapsed(String category) =>
      _collapsed[category] ?? (widget.home && category == _lowPriority);

  static const _lowPriority = 'low priority';

  void _toggle(String category) {
    setState(() => _collapsed[category] = !_isCollapsed(category));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: tokens.sidebar,
        border: Border(right: BorderSide(color: tokens.border, width: 1)),
      ),
      // Background and divider run edge to edge; the rail beside us already
      // owns the left inset, so only the top and bottom apply here.
      child: SafeArea(
        left: false,
        child: Column(
          children: [
            _Header(space: widget.space, tokens: tokens),
            _SearchField(tokens: tokens),
            Expanded(
              child: ListView(
                // Clears the account panel floating over the bottom.
                padding: const EdgeInsets.only(bottom: UserBar.clearance),
                children: [
                  if (widget.invites.isNotEmpty) ...[
                    _CategoryHeading(
                      name: 'invites',
                      collapsed: _isCollapsed('invites'),
                      tokens: tokens,
                      onToggle: () => _toggle('invites'),
                    ),
                    if (!_isCollapsed('invites'))
                      for (final invite in widget.invites)
                        _InviteEntry(
                          invite: invite,
                          selected: invite.id == widget.selectedInviteId,
                          tokens: tokens,
                          onTap: () => widget.onOpenInvite?.call(invite.id),
                        ),
                  ],
                  for (final category in widget.space.categories)
                    _CategorySection(
                      category: category,
                      collapsed: _isCollapsed(category.name),
                      selectedChannelId: widget.selectedInviteId == null
                          ? widget.selectedChannelId
                          : null,
                      tokens: tokens,
                      onToggle: () => _toggle(category.name),
                      onSelect: widget.onSelect,
                      onAction: widget.onAction,
                      allowedActions: widget.allowedActions,
                      ringingId: widget.ringingId,
                      call: widget.call,
                      myId: widget.myId,
                      onHangUp: widget.onHangUp,
                      onSilence: widget.onSilence,
                      home: widget.home,
                      onReorder: widget.home && category.name == 'favourites'
                          ? widget.onReorderFavourites
                          : null,
                      onAdd: widget.home && category.name == 'direct messages'
                          ? widget.onNewMessage
                          : null,
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

class _Header extends StatelessWidget {
  const _Header({required this.space, required this.tokens});

  final Space space;
  final LoafTokens tokens;

  @override
  Widget build(BuildContext context) {
    // The channel list never touches a window corner, so this only moves
    // the window; the buttons live in the bars beside it.
    return WindowDragArea(
      // The channel header's height, so the two dividers meet in one line.
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: tokens.border, width: 1)),
        ),
        child: Text(
          space.name,
          style: loafDisplay(17, 600).copyWith(color: tokens.textStrong),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.tokens});

  final LoafTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: tokens.card,
          border: Border.all(color: tokens.border),
          borderRadius: BorderRadius.circular(LoafRadius.md),
        ),
        child: Row(
          children: [
            Icon(LucideIcons.search, color: tokens.textMuted, size: 16),
            const SizedBox(width: 8),
            Text(
              'Search',
              style: loafBody(13, 400).copyWith(color: tokens.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryHeading extends StatelessWidget {
  const _CategoryHeading({
    required this.name,
    required this.collapsed,
    required this.tokens,
    required this.onToggle,
    this.onAdd,
  });

  final String name;
  final bool collapsed;
  final LoafTokens tokens;
  final VoidCallback onToggle;

  /// A "+" at the heading's end, for starting something in this section.
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 4),
        child: Row(
          children: [
            AnimatedRotation(
              duration: LoafMotion.fast,
              curve: LoafMotion.ease,
              turns: collapsed ? -0.25 : 0,
              child: Icon(
                LucideIcons.chevronDown,
                size: 14,
                color: tokens.textMuted,
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                name.toUpperCase(),
                style: loafBody(
                  11,
                  600,
                  height: 1.3,
                ).copyWith(color: tokens.textMuted, letterSpacing: 0.04 * 11),
              ),
            ),
            if (onAdd != null)
              Tooltip(
                message: 'New message',
                child: InkWell(
                  onTap: onAdd,
                  borderRadius: BorderRadius.circular(LoafRadius.sm),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(
                      LucideIcons.plus,
                      size: 16,
                      color: tokens.textMuted,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CategorySection extends StatelessWidget {
  const _CategorySection({
    required this.category,
    required this.collapsed,
    required this.selectedChannelId,
    required this.tokens,
    required this.onToggle,
    required this.onSelect,
    required this.onAction,
    this.allowedActions,
    this.ringingId,
    this.call,
    required this.myId,
    this.onHangUp,
    this.onSilence,
    this.home = false,
    this.onReorder,
    this.onAdd,
  });

  final ChannelCategory category;
  final Set<ChannelAction>? allowedActions;

  /// Home's direct messages only: starts a new one.
  final VoidCallback? onAdd;
  final String? ringingId;
  final ({String channelId, List<TileInfo> people})? call;
  final String myId;
  final void Function(Channel channel, Member member)? onHangUp;
  final void Function(Channel channel, Member member, CallSilence? silence)?
  onSilence;
  final bool collapsed;
  final String? selectedChannelId;
  final LoafTokens tokens;
  final VoidCallback onToggle;
  final ValueChanged<String> onSelect;
  final void Function(String channelId, ChannelAction action)? onAction;
  final bool home;

  /// Makes the rows draggable. Home's favourites only: everything else is
  /// ordered by the space's admins or by Home's own rules.
  final ValueChanged<List<String>>? onReorder;

  _ChannelEntry _entry(Channel channel, {bool longPressActions = true}) =>
      _ChannelEntry(
        channel: channel,
        // An older duplicate lights up the row that stands for it.
        selected:
            channel.id == selectedChannelId ||
            channel.earlier.any((c) => c.id == selectedChannelId),
        ringing: channel.id == ringingId,
        people: channel.id == call?.channelId ? call!.people : const [],
        myId: myId,
        onHangUp: onHangUp,
        onSilence: onSilence,
        tokens: tokens,
        home: home,
        longPressActions: longPressActions,
        onTap: () => onSelect(channel.id),
        allowedActions: allowedActions,
        onAction:
            onAction == null ||
                !channel.joined ||
                actionsFor(channel, home: home, allowed: allowedActions).isEmpty
            ? null
            : (action) => onAction!(channel.id, action),
      );

  @override
  Widget build(BuildContext context) {
    // Collapsed categories still surface channels with pending mentions, so
    // pings never get hidden behind a collapse. Channels you have not joined
    // cannot have any, so a collapse always hides them.
    //
    // Unjoined channels sink to the bottom of their own category rather than
    // a separate section: the category is structure the space's admins
    // built, and the channel belongs in it.
    final visibleChannels = collapsed
        ? category.channels.where((c) => c.joined && c.mentions > 0).toList()
        : [
            ...category.channels.where((c) => c.joined),
            ...category.channels.where((c) => !c.joined),
          ];

    final onReorder = this.onReorder;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A space's own channels, outside any category, have no heading.
        if (category.name.isNotEmpty)
          _CategoryHeading(
            name: category.name,
            collapsed: collapsed,
            tokens: tokens,
            onToggle: onToggle,
            onAdd: onAdd,
          ),
        if (onReorder != null && !collapsed)
          _Reorderable(
            channels: visibleChannels,
            entry: _entry,
            onReorder: onReorder,
          )
        else
          for (final channel in visibleChannels) _entry(channel),
      ],
    );
  }
}

/// Rows you can drag into your own order. A computer drags on a plain
/// drag. A phone drags after a long press — and since a long press is also
/// how a phone asks for a row's actions, one that lets go without moving
/// opens them instead, the way the iOS home screen does.
class _Reorderable extends StatefulWidget {
  const _Reorderable({
    required this.channels,
    required this.entry,
    required this.onReorder,
  });

  final List<Channel> channels;
  final _ChannelEntry Function(Channel, {bool longPressActions}) entry;
  final ValueChanged<List<String>> onReorder;

  @override
  State<_Reorderable> createState() => _ReorderableState();
}

class _ReorderableState extends State<_Reorderable> {
  int? _dragFrom;

  /// The list only reports drops that move something, so a long press let
  /// go in place is spotted here: it ends in its own gap, just before or
  /// just after itself.
  void _dragEnded(int gap) {
    final from = _dragFrom;
    _dragFrom = null;
    if (from == null || isDesktop) return;
    if (gap == from || gap == from + 1) {
      HapticFeedback.mediumImpact();
      widget.entry(widget.channels[from]).openActions(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final channels = widget.channels;
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: channels.length,
      proxyDecorator: (child, index, animation) => Material(
        color: Colors.transparent,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.card,
            borderRadius: BorderRadius.circular(LoafRadius.md),
            boxShadow: tokens.shadowMd,
          ),
          child: child,
        ),
      ),
      onReorderStart: (index) => _dragFrom = index,
      onReorderEnd: _dragEnded,
      onReorderItem: (from, to) {
        final ids = [for (final c in channels) c.id];
        ids.insert(to, ids.removeAt(from));
        widget.onReorder(ids);
      },
      itemBuilder: (context, index) {
        final row = widget.entry(channels[index], longPressActions: false);
        return isDesktop
            ? _DragAfterSlop(
                key: ValueKey('reorder-${channels[index].id}'),
                index: index,
                child: row,
              )
            : ReorderableDelayedDragStartListener(
                key: ValueKey('reorder-${channels[index].id}'),
                index: index,
                child: row,
              );
      },
    );
  }
}

/// Starts a drag only once the pointer has moved, so a plain click on a
/// row still opens it.
class _DragAfterSlop extends ReorderableDragStartListener {
  const _DragAfterSlop({super.key, required super.index, required super.child});

  @override
  MultiDragGestureRecognizer createRecognizer() =>
      VerticalMultiDragGestureRecognizer(debugOwner: this);
}

class _ChannelEntry extends StatelessWidget {
  const _ChannelEntry({
    required this.channel,
    required this.selected,
    required this.tokens,
    required this.onTap,
    required this.onAction,
    this.allowedActions,
    this.ringing = false,
    this.people = const [],
    required this.myId,
    this.onHangUp,
    this.onSilence,
    this.home = false,
    this.longPressActions = true,
  });

  final Channel channel;
  final Set<ChannelAction>? allowedActions;
  final bool selected;
  final bool ringing;

  /// How each person in this channel's call is heard, when it is the call
  /// you are in. Empty otherwise.
  final List<TileInfo> people;
  final String myId;
  final void Function(Channel channel, Member member)? onHangUp;
  final void Function(Channel channel, Member member, CallSilence? silence)?
  onSilence;

  /// Mutes or deafens [member] for everyone in this channel's call, or
  /// null where you may not: the app does none of it, your level here does
  /// not reach, or it is you.
  ValueChanged<CallSilence?>? _silence(Member member) {
    final onSilence = this.onSilence;
    if (onSilence == null || !channel.canSilence || member.id == myId) {
      return null;
    }
    return (silence) => onSilence(channel, member, silence);
  }

  /// Takes [member] out of this channel's call, or null where you may not:
  /// the app does none of it, or it is you.
  VoidCallback? _hangUp(Member member) {
    final onHangUp = this.onHangUp;
    if (onHangUp == null || member.id == myId) return null;
    return () => onHangUp(channel, member);
  }

  /// A Home row: its actions include favourite and low priority.
  final bool home;

  /// Off when a long press already means something else — dragging a
  /// favourite, which opens the actions itself if you let go in place.
  final bool longPressActions;
  final LoafTokens tokens;
  final VoidCallback onTap;
  final ValueChanged<ChannelAction>? onAction;

  Future<void> openActions(BuildContext context, {Offset? position}) async {
    final onAction = this.onAction;
    if (onAction == null) return;
    final action = await showChannelActions(
      context,
      channel,
      position: position,
      home: home,
      allowed: allowedActions,
    );
    if (action != null) onAction(action);
  }

  @override
  Widget build(BuildContext context) {
    final joined = channel.joined;
    final direct = channel.kind == ChannelKind.direct;
    final room = channel.kind == ChannelKind.room;
    // A level quiets notifications and sound, not what's unread.
    final unread = joined && channel.unread > 0;
    final iconData = channel.icon;
    final fg = selected
        ? tokens.accent
        : unread
        ? tokens.textStrong
        : joined
        ? tokens.textBody
        : tokens.textMuted;

    return Padding(
      key: ValueKey('channel-${channel.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 34,
            decoration: BoxDecoration(
              color: selected ? tokens.card : null,
              borderRadius: BorderRadius.circular(LoafRadius.md),
              boxShadow: selected ? tokens.shadowSm : null,
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: onTap,
                // Long press on a phone, right-click on a computer — the
                // same split as message actions.
                onLongPress: !isDesktop && onAction != null && longPressActions
                    ? () {
                        HapticFeedback.mediumImpact();
                        openActions(context);
                      }
                    : null,
                onSecondaryTapUp: isDesktop && onAction != null
                    ? (details) =>
                          openActions(context, position: details.globalPosition)
                    : null,
                hoverColor: tokens.card.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(LoafRadius.md),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      if (direct)
                        _DirectAvatar(channel: channel, tokens: tokens)
                      else if (room)
                        RoomAvatar(
                          name: channel.name,
                          id: channel.id,
                          size: 22,
                          image: channel.avatar,
                        )
                      else
                        Icon(iconData, size: 16, color: fg),
                      SizedBox(width: direct || room ? 8 : 6),
                      Expanded(
                        child: Text(
                          channel.name,
                          overflow: TextOverflow.ellipsis,
                          style:
                              (unread ? loafBody(15, 600) : loafBody(15, 400))
                                  .copyWith(color: fg),
                        ),
                      ),
                      if (channel.notify != NotifyLevel.all) ...[
                        const SizedBox(width: 6),
                        Icon(
                          channel.notify == NotifyLevel.none
                              ? LucideIcons.bellOff
                              : LucideIcons.bellMinus,
                          size: 14,
                          color: tokens.textMuted,
                        ),
                      ],
                      if (ringing) ...[
                        const SizedBox(width: 6),
                        Pulse(
                          key: const ValueKey('dm-ringing'),
                          child: Icon(
                            LucideIcons.phoneIncoming,
                            size: 16,
                            color: tokens.online,
                          ),
                        ),
                      ] else if (!joined) ...[
                        const SizedBox(width: 6),
                        _JoinPill(tokens: tokens),
                      ] else if (direct && channel.unread > 0) ...[
                        // Everything in a DM is addressed to you, so its
                        // unread count is the badge.
                        const SizedBox(width: 6),
                        _CountBadge(count: channel.unread, tokens: tokens),
                      ] else if (channel.mentions > 0) ...[
                        const SizedBox(width: 6),
                        _CountBadge(count: channel.mentions, tokens: tokens),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (channel.kind != ChannelKind.text && channel.occupants.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 30, top: 2, bottom: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final member in channel.occupants)
                    _Occupant(
                      key: ValueKey('occupant-${channel.id}-${member.id}'),
                      member: member,
                      heard: people
                          .where((person) => person.id == member.id)
                          .firstOrNull,
                      you: member.id == myId,
                      onHangUp: _hangUp(member),
                      silenced: channel.silenced[member.id],
                      onSilence: _silence(member),
                      tokens: tokens,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Someone in a voice channel's call. In the call you are in, [heard] says
/// whether they are talking or muted; elsewhere nobody can tell.
class _Occupant extends StatelessWidget {
  const _Occupant({
    super.key,
    required this.member,
    required this.heard,
    required this.you,
    required this.onHangUp,
    required this.silenced,
    required this.onSilence,
    required this.tokens,
  });

  final Member member;
  final TileInfo? heard;
  final bool you;

  /// Null where you may not take them out of the call.
  final VoidCallback? onHangUp;

  /// What someone has put on them for everyone, if anything.
  final CallSilence? silenced;

  /// Null where you may not mute or deafen them for everyone.
  final ValueChanged<CallSilence?>? onSilence;
  final LoafTokens tokens;

  /// Their volume, where [voice] keeps one, and what you may do to them for
  /// everyone: a menu at [position] on a computer, a sheet on a phone.
  Future<void> _openMenu(
    BuildContext context,
    VoiceController? voice, {
    Offset? position,
  }) async {
    final onHangUp = this.onHangUp;
    final onSilence = this.onSilence;
    final items = [
      if (onSilence != null) ...[
        if (silenced == null)
          const ActionItem(
            value: _OccupantAction.mute,
            icon: LucideIcons.micOff,
            label: 'mute for everyone',
          ),
        if (silenced == CallSilence.muted)
          const ActionItem(
            value: _OccupantAction.lift,
            icon: LucideIcons.mic,
            label: 'unmute for everyone',
          ),
        if (silenced == CallSilence.deafened)
          const ActionItem(
            value: _OccupantAction.lift,
            icon: LucideIcons.headphones,
            label: 'undeafen for everyone',
          )
        else
          const ActionItem(
            value: _OccupantAction.deafen,
            icon: LucideIcons.headphoneOff,
            label: 'deafen for everyone',
          ),
      ],
      if (onHangUp != null)
        const ActionItem(
          value: _OccupantAction.hangUp,
          icon: LucideIcons.phoneOff,
          label: 'remove from call',
        ),
    ];
    final _OccupantAction? action;
    if (position != null) {
      action = await showActionMenu(
        context,
        position: position,
        leading: [
          PersonCardEntry(member: member, isYou: you),
          if (voice != null) VolumeMenuEntry(voice: voice, id: member.id),
        ],
        items: items,
      );
    } else {
      action = await showActionSheet(
        context,
        header: (context) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PersonCard(member: member, isYou: you),
            if (voice != null) VolumeSlider(voice: voice, id: member.id),
          ],
        ),
        items: items,
      );
    }
    switch (action) {
      case _OccupantAction.mute:
        onSilence?.call(CallSilence.muted);
      case _OccupantAction.deafen:
        onSilence?.call(CallSilence.deafened);
      case _OccupantAction.lift:
        onSilence?.call(null);
      case _OccupantAction.hangUp:
        onHangUp?.call();
      case null:
    }
  }

  @override
  Widget build(BuildContext context) {
    final speaking = heard?.speaking ?? false;
    final deafened =
        silenced == CallSilence.deafened || (heard?.deafened ?? false);
    final muted = silenced != null || (heard?.muted ?? false);
    // Your own sound is never played to you, so there is nothing to set.
    // Found, not watched: whether the app keeps voice settings never
    // changes while it runs.
    final voice = you ? null : VoiceScope.find(context);
    final hasMenu = voice != null || onHangUp != null || onSilence != null;
    return Semantics(
      label: [
        member.name,
        if (speaking) 'speaking',
        // Deafened is muted too; the one word says both.
        if (silenced != null)
          '${deafened ? 'deafened' : 'muted'} for everyone'
        else if (deafened)
          'deafened'
        else if (muted)
          'muted',
      ].join(', '),
      // One node a row, not one for the whole list of people.
      container: true,
      excludeSemantics: true,
      // A screen reader has no right-click; it opens the menu where the
      // row is.
      onLongPress: !hasMenu
          ? null
          : () {
              final box = context.findRenderObject()! as RenderBox;
              unawaited(
                _openMenu(
                  context,
                  voice,
                  position: isDesktop
                      ? box.localToGlobal(Offset(0, box.size.height))
                      : null,
                ),
              );
            },
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          // Long press on a phone, right-click on a computer, as for a
          // channel's own actions.
          onLongPress: !isDesktop && hasMenu
              ? () {
                  HapticFeedback.mediumImpact();
                  unawaited(_openMenu(context, voice));
                }
              : null,
          onSecondaryTapUp: isDesktop && hasMenu
              ? (details) => unawaited(
                  _openMenu(context, voice, position: details.globalPosition),
                )
              : null,
          hoverColor: tokens.card.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(LoafRadius.md),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                SpeakingRing(
                  speaking: speaking,
                  child: _MemberAvatar(member: member, size: 20),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    member.name,
                    overflow: TextOverflow.ellipsis,
                    style: loafBody(13, 400).copyWith(color: tokens.textMuted),
                  ),
                ),
                if (deafened || muted)
                  Padding(
                    padding: const EdgeInsets.only(
                      left: 6,
                      right: LoafSpace.x3,
                    ),
                    child: Icon(
                      deafened ? LucideIcons.headphoneOff : LucideIcons.micOff,
                      size: 14,
                      // A moderator's doing stands out from their own.
                      color: silenced != null
                          ? tokens.accent
                          : tokens.textMuted,
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

/// What the menu on someone in a voice channel can do.
enum _OccupantAction { mute, deafen, lift, hangUp }

/// A line of plain text heading a menu.
/// Marks a channel you can join with one tap. Not a separate button: the
/// whole row joins, and this says so.
/// A standalone room's face: a rounded square with its initial, since it is
/// a room of its own rather than a channel in a space.
class RoomAvatar extends StatelessWidget {
  const RoomAvatar({
    super.key,
    required this.name,
    required this.id,
    this.size = 22,
    this.color,
    this.image,
  });

  final String name;
  final String id;
  final double size;

  /// Null draws the initial.
  final AvatarRef? image;

  /// Defaults to a colour picked from the room's id, as real clients do.
  final Color? color;

  static const _palette = [
    Color(0xFF64748B),
    Color(0xFF0891B2),
    Color(0xFF7C3AED),
    Color(0xFFD97B2A),
    Color(0xFF4E9E76),
    Color(0xFFDB2777),
  ];

  @override
  Widget build(BuildContext context) {
    final fill =
        color ??
        _palette[id.codeUnits.fold(0, (a, b) => a + b) % _palette.length];
    return LoafAvatar(
      label: name.characters.first.toUpperCase(),
      color: fill,
      size: size,
      radius: size * 0.3,
      image: image,
      textStyle: loafBody(size * 0.5, 700),
    );
  }
}

/// An invite in Home: who is asking you in, and to what. Tapping it opens
/// a preview; nothing is joined until you accept there.
class _InviteEntry extends StatelessWidget {
  const _InviteEntry({
    required this.invite,
    required this.selected,
    required this.tokens,
    required this.onTap,
  });

  final Invite invite;
  final bool selected;
  final LoafTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final avatar = invite.kind == InviteKind.direct
        ? _MemberAvatar(member: invite.inviter, size: 30)
        : RoomAvatar(
            name: invite.name,
            id: invite.id,
            size: 30,
            color: invite.color,
            image: invite.space?.avatar ?? invite.room?.avatar,
          );
    return Padding(
      key: ValueKey('invite-${invite.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
      child: Material(
        color: selected ? tokens.card : Colors.transparent,
        borderRadius: BorderRadius.circular(LoafRadius.md),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(LoafRadius.md),
          hoverColor: tokens.card.withValues(alpha: 0.5),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                avatar,
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        invite.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: loafBody(
                          15,
                          600,
                        ).copyWith(color: tokens.textStrong),
                      ),
                      Text(
                        invite.summary,
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
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: tokens.accent,
                    shape: BoxShape.circle,
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

/// A DM's face in the list: the person with their presence, or for a group,
/// two of its people overlapping.
class _DirectAvatar extends StatelessWidget {
  const _DirectAvatar({required this.channel, required this.tokens});

  final Channel channel;
  final LoafTokens tokens;

  @override
  Widget build(BuildContext context) {
    final members = channel.members;
    if (members.length == 1) {
      return SizedBox(
        width: 22,
        height: 22,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            _MemberAvatar(member: members.single, size: 22),
            Positioned(
              right: -3,
              bottom: -3,
              child: PresenceDot(
                presence: members.single.presence,
                ring: tokens.sidebar,
                size: 10,
              ),
            ),
          ],
        ),
      );
    }
    return SizedBox(
      width: 22,
      height: 22,
      child: Stack(
        children: [
          _MemberAvatar(member: members[0], size: 15),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: tokens.sidebar, width: 1.5),
              ),
              child: _MemberAvatar(member: members[1], size: 14),
            ),
          ),
        ],
      ),
    );
  }
}

class _JoinPill extends StatelessWidget {
  const _JoinPill({required this.tokens});

  final LoafTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x2),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(LoafRadius.full),
        border: Border.all(color: tokens.borderStrong),
      ),
      child: Text(
        'join',
        style: loafBody(11, 600).copyWith(color: tokens.textBody),
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count, required this.tokens});

  final int count;
  final LoafTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 18),
      height: 18,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tokens.accent,
        borderRadius: BorderRadius.circular(LoafRadius.full),
      ),
      child: Text(
        countLabel(count),
        style: loafBody(11, 700).copyWith(color: Colors.white),
      ),
    );
  }
}

class _MemberAvatar extends StatelessWidget {
  const _MemberAvatar({required this.member, required this.size});

  final Member member;
  final double size;

  @override
  Widget build(BuildContext context) {
    return LoafAvatar(
      // Two letters don't fit a group DM's tiny overlapping pair.
      label: size < 18 ? member.initials.characters.first : member.initials,
      color: member.color,
      size: size,
      image: member.avatar,
      // Scales with the circle: a group DM's overlapping pair is smaller
      // than a voice occupant's avatar.
      textStyle: loafBody(size * 0.42, 600),
    );
  }
}
