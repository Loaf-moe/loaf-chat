/// The app shell: spaces rail, channel list, and the channel you are reading.
///
/// One layout, two arrangements. Above [_wideBreakpoint] the three panes sit
/// side by side, the way the design system's desktop kit draws them. Below
/// it, the rail and channel list move into a drawer and the channel fills the
/// screen — Discord's phone layout, which is the solved version of this.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../call/call_controller.dart';
import '../call/call_debug.dart';
import '../call/connected_call_bar.dart';
import '../call/dm_call_panel.dart';
import '../call/incoming_call_card.dart';
import '../call/voice_channel_page.dart';
import '../channel/channel_view.dart';
import '../channel/timeline_controller.dart';
import '../home/direct_messages.dart';
import '../home/home_sections.dart';
import '../home/new_message_picker.dart';
import '../spaces/add_space.dart';
import '../home/invite_preview.dart';
import '../members/member_list.dart';
import '../mock/call_fixtures.dart';
import '../mock/fixtures.dart';
import '../platform.dart';
import '../theme/loaf_theme.dart';
import 'channel_list.dart';
import '../settings/settings_page.dart';
import 'app_notice.dart';
import 'channel_actions.dart';
import 'profile_controller.dart';
import 'status_picker.dart';
import 'spaces_rail.dart';
import 'user_bar.dart';

/// Below this width the navigation collapses into a drawer.
const _wideBreakpoint = 900.0;

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _timeline = TimelineController(mockTimeline(), you: currentUser);
  final _profile = ProfileController();
  late final _calls = CallController(
    me: currentUser,
    rings: mockRings,
    flags: mockCallFlags,
    onRecord: _onCallRecord,
  );

  /// Conversations of their own: Home's rooms, and channels in spaces
  /// joined or made this session. See _timelineFor.
  final _directTimelines = <String, TimelineController>{};

  @override
  void initState() {
    super.initState();
    _profile.addListener(_onChange);
    _calls.addListener(_onChange);
  }

  void _onChange() => setState(() {});

  @override
  void dispose() {
    _profile
      ..removeListener(_onChange)
      ..dispose();
    _calls
      ..removeListener(_onChange)
      ..dispose();
    _timeline.dispose();
    for (final t in _directTimelines.values) {
      t.dispose();
    }
    super.dispose();
  }

  String _spaceId = mockSpaces.first.id;

  /// Where you were in each space. Switching away and back should not dump
  /// you in the first channel again.
  final _channelBySpace = <String, String>{};

  /// Mockup state: which app notices are showing.
  var _showUpdate = true;
  final _showVerify = true;

  /// Only consulted on wide layouts, where the member list is a column you
  /// can put away. On a phone it is a drawer and opens on demand.
  bool _showMembers = true;

  /// The DM call panel fills the conversation rather than docking above it.
  bool _dmPanelExpanded = false;

  /// Desktop only: the voice call fills the window.
  bool _fullscreen = false;

  // This session's changes, layered over the fixtures by Space.withSession.
  final _membership = <String, bool>{};
  final _mutedNow = <String, bool>{};
  final _read = <String>{};
  final _missedCalls = <String, int>{};

  // Home's room tags, as this session has them. Favourites are a list so
  // their order is the list's; m.favourite's `order` is its position.
  late final _favourites = [
    for (final room in [
      ...mockHomeRooms,
    ]..sort((a, b) => (a.favouriteOrder ?? 1).compareTo(b.favouriteOrder ?? 1)))
      if (room.favourite) room.id,
  ];
  final _lowPriority = <String, bool>{};

  /// When a DM last saw a message or a call, this session.
  final _activity = <String, DateTime>{};

  // Invites answered this session, and what accepting them brought in.
  final _answeredInvites = <String>{};
  final _acceptedRooms = <Channel>[];
  final _acceptedSpaces = <Space>[];

  /// The invite being previewed in place of a conversation, if any.
  String? _previewInvite;

  List<Space> get _spaces => [...mockSpaces, ..._acceptedSpaces];

  List<Invite> get _invites => [
    for (final invite in mockInvites)
      if (!_answeredInvites.contains(invite.id)) invite,
  ];

  bool get _home => _spaceId == mockHome.id;

  /// Home's rooms with this session's tags and activity applied. Rooms you
  /// have left are gone: Home has no "join" pills, only what you are in.
  List<Channel> get _homeRooms => [
    for (final room in [...mockHomeRooms, ..._acceptedRooms])
      if (_membership[room.id] != false)
        room.copyWith(
          favourite: _favourites.contains(room.id),
          favouriteOrder: _favourites.contains(room.id)
              ? _favourites.indexOf(room.id) / _favourites.length
              : null,
          lowPriority: _lowPriority[room.id],
          lastActivity: _activity[room.id],
          // Read state is applied per room here, before duplicates fold
          // together, so an older room's unreads still count on the row.
          unread:
              (_read.contains(room.id) ? 0 : room.unread) +
              (_missedCalls[room.id] ?? 0),
          mentions: _read.contains(room.id) ? 0 : room.mentions,
        ),
  ];

  Space get _space {
    if (!_home) {
      return _spaces
          .firstWhere((s) => s.id == _spaceId)
          .withSession(
            membership: _membership,
            muted: _mutedNow,
            read: _read,
            occupants: _callOccupants,
            unread: _missedCalls,
          );
    }
    // Home's rooms already carry their read state; see _homeRooms.
    return Space(
      id: mockHome.id,
      name: mockHome.name,
      color: mockHome.color,
      members: mockHome.members,
      categories: homeSections(collapseDuplicates(_homeRooms)),
    ).withSession(
      membership: _membership,
      muted: _mutedNow,
      occupants: _callOccupants,
    );
  }

  /// Who is in the call you are in, you included — so its channel or DM
  /// lists you under it like everyone else.
  Map<String, List<Member>> get _callOccupants {
    final session = _calls.session;
    if (session == null || !_calls.inCall) return const {};
    if (session.phase == CallPhase.ringing) return const {};
    return {
      session.target.id: [
        _profile.me,
        for (final p in session.participants)
          if (p.present) p.member,
      ],
    };
  }

  Channel get _channel {
    final rows = _space.allChannels;
    // An older duplicate DM is not a row of its own, but can be open.
    final channels = [...rows, for (final row in rows) ...row.earlier];
    final remembered = _channelBySpace[_spaceId];
    return channels.firstWhere(
      (c) => c.id == remembered && c.joined,
      orElse: () =>
          channels.firstWhere((c) => c.kind != ChannelKind.voice && c.joined),
    );
  }

  static bool _inHome(Channel c) =>
      c.kind == ChannelKind.direct || c.kind == ChannelKind.room;

  /// The original spaces' channels share one mock conversation. Anything
  /// joined or made this session, and every Home room, has its own.
  static bool _sharesMockTimeline(Channel c) =>
      mockSpaces.any((s) => s.allChannels.any((x) => x.id == c.id));

  TimelineController _timelineFor(Channel channel) =>
      _sharesMockTimeline(channel)
      ? _timeline
      : _directTimelines.putIfAbsent(channel.id, () {
          final timeline = TimelineController(
            _inHome(channel)
                ? mockHomeTimeline(channel.id)
                : mockSpaceTimeline(channel.id),
            you: currentUser,
          );
          var count = timeline.messages.length;
          // A new message moves a DM up the list.
          timeline.addListener(() {
            if (timeline.messages.length > count) {
              setState(() => _activity[channel.id] = DateTime.now());
            }
            count = timeline.messages.length;
          });
          return timeline;
        });

  void _selectSpace(String id) => setState(() {
    _spaceId = id;
    // Home opens straight onto a DM, and seeing it is reading it.
    if (_home) _open(id, _channel.id);
  });

  void _open(String spaceId, String channelId) {
    _spaceId = spaceId;
    _channelBySpace[spaceId] = channelId;
    _fullscreen = false;
    _previewInvite = null;
    if (spaceId == mockHome.id) {
      _read.add(channelId);
      _missedCalls.remove(channelId);
    }
  }

  void _selectChannel(String id) {
    final channel = _space.allChannels.firstWhere((c) => c.id == id);

    // Tapping a channel you are not in joins it and opens it. A voice
    // channel opens to its lobby rather than connecting: membership and
    // being in the call are separate steps.
    final joining = !channel.joined;
    setState(() {
      if (joining) _membership[id] = true;
      _open(_spaceId, id);
      // A computer connects on click; a phone shows the lobby first, since a
      // stray tap there should never open a live mic.
      if (channel.kind == ChannelKind.voice && !joining && isDesktop) {
        final here = _calls.inCall && _calls.session!.target.id == id;
        if (!here) _joinVoice(channel);
      }
    });
    _scaffoldKey.currentState?.closeDrawer();
  }

  void _joinVoice(Channel channel) {
    final space = _spaces.firstWhere(
      (s) => s.allChannels.any((c) => c.id == channel.id),
    );
    _calls.joinVoice(channel, spaceName: space.name);
  }

  Future<void> _channelAction(String id, ChannelAction action) async {
    if (action == ChannelAction.olderConversations) {
      final row = _space.allChannels.firstWhere((c) => c.id == id);
      final chosen = await showOlderConversations(context, row);
      if (chosen != null) setState(() => _open(mockHome.id, chosen));
      _scaffoldKey.currentState?.closeDrawer();
      return;
    }
    setState(() => _applyChannelAction(id, action));
  }

  void _applyChannelAction(String id, ChannelAction action) {
    switch (action) {
      case ChannelAction.markRead:
        _read.add(id);
      case ChannelAction.favourite:
        _favourites.add(id);
      case ChannelAction.unfavourite:
        _favourites.remove(id);
      case ChannelAction.lowPriority:
        _lowPriority[id] = true;
      case ChannelAction.notLowPriority:
        _lowPriority[id] = false;
      case ChannelAction.olderConversations:
        break; // Handled before any state changes: it asks first.
      case ChannelAction.mute:
        _mutedNow[id] = true;
      case ChannelAction.unmute:
        _mutedNow[id] = false;
      case ChannelAction.leave:
        // Leaving the channel you are reading falls through to the space's
        // first joined text channel: see _channel.
        _membership[id] = false;
        // Leaving a voice channel you are in takes you out of the call too.
        if (_calls.session?.target.id == id) _calls.leave();
    }
  }

  /// Back to wherever the call lives: its voice channel, or its DM.
  void _goToCall() {
    final target = _calls.session?.target;
    if (target == null) return;
    setState(() {
      if (target.kind == ChannelKind.direct) {
        _open(mockHome.id, target.id);
      } else {
        final space = _spaces.firstWhere(
          (s) => s.allChannels.any((c) => c.id == target.id),
        );
        _open(space.id, target.id);
      }
    });
  }

  // ── Adding spaces ──────────────────────────────────────────────────

  var _made = 0;

  Future<void> _addSpace() async {
    final result = await showAddSpace(
      context,
      joined: {for (final s in _spaces) s.id},
    );
    if (result == null || !mounted) return;
    setState(() {
      switch (result) {
        case OpenSpace(:final id):
          _spaceId = id;
        case JoinSpace(:final space):
          _acceptedSpaces.add(space);
          // Joining a space you were invited to answers the invite.
          for (final invite in mockInvites) {
            if (invite.space?.id == space.id) _answeredInvites.add(invite.id);
          }
          _spaceId = space.id;
        case CreateSpace(:final name):
          // The mock's space creation: the space room, then #general and a
          // voice channel as its children, both restricted to its members.
          final id = 'made-${_made++}';
          _acceptedSpaces.add(
            Space(
              id: id,
              name: name,
              color: spaceColorFor(name),
              members: [_profile.me],
              categories: [
                ChannelCategory('', [
                  Channel(id: '$id-general', name: 'general'),
                  Channel(
                    id: '$id-hangout',
                    name: 'hangout',
                    kind: ChannelKind.voice,
                  ),
                ]),
              ],
            ),
          );
          _open(id, '$id-general');
      }
      _fullscreen = false;
    });
    _scaffoldKey.currentState?.closeDrawer();
  }

  // ── New messages ───────────────────────────────────────────────────

  var _started = 0;

  Future<void> _newMessage() async {
    final me = _profile.me;
    final people = <String, Member>{
      for (final space in _spaces)
        for (final m in space.members)
          if (m.id != me.id) m.id: m,
      for (final room in _homeRooms)
        for (final m in room.members)
          if (m.id != me.id) m.id: m,
    };
    final start = await showNewMessagePicker(
      context,
      people: people.values.toList(),
      rooms: [
        for (final room in _homeRooms)
          if (room.kind == ChannelKind.direct) room,
      ],
    );
    if (start == null || !mounted) return;
    setState(() {
      switch (start) {
        case OpenExisting(:final room):
          _open(mockHome.id, room.id);
        case CreateDirect(:final members):
          // The mock's createRoom: is_direct, trusted_private_chat, the
          // people invited, and the room added to m.direct.
          final room = Channel(
            id: 'dm-new-${_started++}',
            name: members.length == 1
                ? members.single.name
                : members.map((m) => m.name.split(' ').first).join(', '),
            kind: ChannelKind.direct,
            members: members,
            waitingFor: members,
          );
          _acceptedRooms.add(room);
          _activity[room.id] = DateTime.now();
          _open(mockHome.id, room.id);
      }
    });
    _scaffoldKey.currentState?.closeDrawer();
  }

  // ── Invites ────────────────────────────────────────────────────────────

  void _openInvite(String id) {
    setState(() => _previewInvite = id);
    _scaffoldKey.currentState?.closeDrawer();
  }

  /// A DM or room joins its section and opens; a space joins the rail and
  /// you stay in Home, where the rest of your invites are.
  void _acceptInvite(Invite invite) => setState(() {
    _answeredInvites.add(invite.id);
    _previewInvite = null;
    final room = invite.room;
    final space = invite.space;
    if (room != null) {
      _acceptedRooms.add(room);
      _activity[room.id] = DateTime.now();
      _open(mockHome.id, room.id);
    } else if (space != null) {
      _acceptedSpaces.add(space);
    }
  });

  void _declineInvite(Invite invite) => setState(() {
    _answeredInvites.add(invite.id);
    _previewInvite = null;
  });

  void _onCallRecord(Channel chat, CallRecord record) {
    _activity[chat.id] = DateTime.now();
    _timelineFor(chat).addCall(
      record.label,
      record is EndedCall ? CallLine.ended : CallLine.missed,
      from: chat.members.first,
    );
    final looking = _home && _channel.id == chat.id;
    if (record is MissedCall && !looking) {
      _missedCalls[chat.id] = (_missedCalls[chat.id] ?? 0) + 1;
    }
  }

  // ── Incoming calls ─────────────────────────────────────────────────────

  /// iOS answers through CallKit's own screen, never ours: the mock skips
  /// straight to having answered.
  bool get _callKit => defaultTargetPlatform == TargetPlatform.iOS;

  void _ring(String chatId, String callerId) {
    final chat = mockHome.allChannels.firstWhere((c) => c.id == chatId);
    final caller = chat.members.firstWhere((m) => m.id == callerId);
    _calls.receive(chat, from: caller);
    if (_callKit) _accept();
  }

  void _accept() {
    final ring = _calls.incoming;
    if (ring == null) return;
    _calls.accept();
    setState(() {
      _open(mockHome.id, ring.chat.id);
      // Answering on a phone is committing to the call; a computer has room
      // for the call and the conversation together.
      _dmPanelExpanded = !isDesktop;
    });
    _scaffoldKey.currentState?.closeDrawer();
  }

  void _openIncoming() {
    final ring = _calls.incoming;
    if (ring == null) return;
    setState(() => _open(mockHome.id, ring.chat.id));
  }

  Future<void> _debug(Rect anchor) async {
    final pick = await showCallDebug(context, anchor);
    if (pick == null) return;
    switch (pick) {
      case CallDebug.ringFromMika:
        _ring('dm-mika', '@mika');
      case CallDebug.ringFromCrew:
        _ring('dm-crew', '@jun');
      case CallDebug.reconnecting:
        _calls.toggleReconnecting();
      case CallDebug.failNext:
        _calls.failNextConnection();
      case CallDebug.encryption:
        _calls.toggleEncryption();
      case CallDebug.micBlocked:
        _calls.toggleMicBlocked();
      case CallDebug.cameraBlocked:
        _calls.toggleCameraBlocked();
      case CallDebug.remoteShare:
        final someone = _calls.session?.participants
            .where((p) => p.present)
            .firstOrNull;
        if (someone != null) _calls.toggleRemoteShare(someone.member.id);
    }
  }

  // ── Building ───────────────────────────────────────────────────────────

  List<AppNotice> get _notices => [
    if (_showVerify) AppNotice.verify(onAction: () {}),
    // Phones update through the App Store or TestFlight, never in-app.
    if (_showUpdate && isDesktop)
      AppNotice.update(
        version: '0.3.0',
        onAction: () {},
        onDismiss: () => setState(() => _showUpdate = false),
      ),
  ];

  /// Whether the call's own page or panel is what you are looking at, in
  /// which case the bar would only repeat it.
  bool get _lookingAtCall =>
      _calls.session?.target.id == _channel.id &&
      (_home || _channel.kind == ChannelKind.voice);

  Widget? _buildCallBar() {
    final session = _calls.session;
    if (session == null || !_calls.inCall || _lookingAtCall) return null;
    final target = session.target;
    final present = [
      for (final p in session.participants)
        if (p.present) p.member,
    ];
    final String subtitle;
    if (target.kind != ChannelKind.direct) {
      subtitle = '${target.name} · ${session.spaceName ?? ''}';
    } else if (target.members.length == 1) {
      subtitle = 'call with ${target.members.single.name}';
    } else {
      final names = target.members.take(2).map((m) => m.name).join(', ');
      final more = target.members.length - 2;
      subtitle = more > 0 ? 'call · $names +$more' : 'call · $names';
    }
    final title = switch (session.phase) {
      CallPhase.ringing => 'Ringing…',
      CallPhase.connecting => 'Connecting…',
      CallPhase.reconnecting => 'Reconnecting…',
      _ => session.direct ? 'Call connected' : 'Voice connected',
    };
    return ConnectedCallBar(
      title: title,
      subtitle: subtitle,
      warning: session.phase == CallPhase.reconnecting,
      occupants: present,
      muted: _calls.muted,
      onToggleMute: _calls.toggleMute,
      onDisconnect: _calls.leave,
      onExpand: _goToCall,
    );
  }

  Widget _buildMain({required bool wide}) {
    final channel = _channel;
    final openNavigation = wide
        ? null
        : () => _scaffoldKey.currentState?.openDrawer();

    final invite = _home
        ? _invites.where((i) => i.id == _previewInvite).firstOrNull
        : null;
    if (invite != null) {
      return InvitePreview(
        invite: invite,
        onAccept: () => _acceptInvite(invite),
        onDecline: () => _declineInvite(invite),
        onOpenNavigation: openNavigation,
      );
    }

    if (channel.kind == ChannelKind.voice) {
      return VoiceChannelPage(
        channel: channel,
        calls: _calls,
        onJoin: () => _joinVoice(channel),
        onOpenNavigation: openNavigation,
        fullscreen: _fullscreen,
        onToggleFullscreen: wide
            ? () => setState(() => _fullscreen = !_fullscreen)
            : null,
      );
    }

    final session = _calls.session;
    final callHere = session != null && session.target.id == channel.id;
    return ChannelView(
      channel: channel,
      timeline: _timelineFor(channel),
      navigationAttention: _notices.any((n) => n.loud),
      callBar: _buildCallBar(),
      onOpenNavigation: openNavigation,
      onToggleMembers: wide
          ? () => setState(() => _showMembers = !_showMembers)
          : () => _scaffoldKey.currentState?.openEndDrawer(),
      onStartCall: callHere
          ? null
          : ({required video}) {
              _dmPanelExpanded = false;
              _calls.startDirect(channel, video: video);
            },
      callPanel: callHere
          ? DmCallPanel(
              calls: _calls,
              expanded: _dmPanelExpanded,
              onToggleExpanded: () =>
                  setState(() => _dmPanelExpanded = !_dmPanelExpanded),
            )
          : null,
      callPanelExpanded: _dmPanelExpanded,
    );
  }

  /// Desktop call shortcuts, live only while you are in a call. Escape
  /// leaves fullscreen.
  Map<ShortcutActivator, VoidCallback> get _shortcuts {
    if (!isDesktop) return const {};
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    SingleActivator combo(LogicalKeyboardKey key) =>
        SingleActivator(key, shift: true, meta: mac, control: !mac);
    return {
      if (_calls.inCall) ...{
        combo(LogicalKeyboardKey.keyM): _calls.toggleMute,
        combo(LogicalKeyboardKey.keyD): _calls.toggleDeafen,
        combo(LogicalKeyboardKey.keyV): _calls.toggleCamera,
      },
      if (_fullscreen)
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            setState(() => _fullscreen = false),
    };
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);

    // Fullscreen only makes sense while there is a call on screen.
    if (_fullscreen && !(_calls.inCall && _channel.kind == ChannelKind.voice)) {
      _fullscreen = false;
    }

    final shell = LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _wideBreakpoint;

        final main = _buildMain(wide: wide);
        final me = _profile.me;
        final channel = _channel;
        final members = MemberList(
          members: channel.kind == ChannelKind.direct
              ? [me, ...channel.members]
              : channel.kind == ChannelKind.room
              ? [for (final m in channel.members) m.id == me.id ? me : m]
              : [for (final m in _space.members) m.id == me.id ? me : m],
        );

        if (wide) {
          return Scaffold(
            key: _scaffoldKey,
            backgroundColor: tokens.page,
            body: _fullscreen
                ? main
                : Row(
                    children: [
                      SizedBox(
                        width: LoafShell.railWidth + LoafShell.sidebarWidth,
                        child: _navigation,
                      ),
                      Expanded(child: main),
                      if (_showMembers &&
                          _previewInvite == null &&
                          (channel.kind == ChannelKind.text ||
                              channel.kind == ChannelKind.room))
                        DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border(
                              left: BorderSide(color: tokens.border),
                            ),
                          ),
                          child: SizedBox(
                            width: LoafShell.memberListWidth,
                            child: members,
                          ),
                        ),
                    ],
                  ),
          );
        }

        // Leave a sliver of the channel visible behind the drawer so it reads
        // as a layer over the conversation rather than a separate screen.
        final drawerWidth = (LoafShell.railWidth + LoafShell.sidebarWidth)
            .clamp(0.0, constraints.maxWidth * 0.88);

        return Scaffold(
          key: _scaffoldKey,
          backgroundColor: tokens.page,
          drawerEdgeDragWidth: 48,
          drawer: Drawer(
            width: drawerWidth,
            shape: const RoundedRectangleBorder(),
            backgroundColor: tokens.sidebar,
            child: _navigation,
          ),
          // The mirror of the navigation drawer: same width rules, same
          // edge-to-edge surface.
          endDrawer: Drawer(
            width: drawerWidth.clamp(0.0, LoafShell.memberListWidth + 40),
            shape: const RoundedRectangleBorder(),
            backgroundColor: tokens.sidebar,
            child: members,
          ),
          body: main,
        );
      },
    );

    final ring = _calls.incoming;
    return CallbackShortcuts(
      bindings: _shortcuts,
      child: Focus(
        autofocus: true,
        child: Stack(
          children: [
            shell,
            if (ring != null && !_callKit)
              _IncomingPosition(
                child: IncomingCallCard(
                  ring: ring,
                  onAccept: _accept,
                  onDecline: _calls.decline,
                  onOpen: _openIncoming,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Everything in a DM is addressed to you, so a DM's unreads count; a
  /// room counts only its mentions, like a channel. Invites wait on you too.
  int get _homeBadge {
    return _homeRooms.fold(
          0,
          (sum, c) =>
              sum + (c.kind == ChannelKind.direct ? c.unread : c.mentions),
        ) +
        _invites.length;
  }

  /// Rail and channel list side by side, with the account panel floating
  /// over the bottom of both. Overlaid rather than stacked, so the columns
  /// still run the full height behind it and your avatar appears once.
  ///
  /// Deliberately not wrapped in a [SafeArea]: each column paints edge to
  /// edge and insets only its own contents, so the rail and divider don't
  /// stop short of the status bar and home indicator.
  Widget get _navigation => Builder(
    builder: (context) => Stack(
      children: [
        Row(
          children: [
            SpacesRail(
              // With this session's reading applied, so badges recount.
              spaces: [
                for (final space in _spaces)
                  space.withSession(
                    membership: _membership,
                    muted: _mutedNow,
                    read: _read,
                  ),
              ],
              selectedSpaceId: _spaceId,
              onSelect: _selectSpace,
              notices: _notices,
              homeSelected: _home,
              onHome: () => _selectSpace(mockHome.id),
              homeBadge: _homeBadge,
              homeRinging: _calls.incoming != null,
              onAddSpace: _addSpace,
            ),
            Expanded(
              child: ChannelList(
                space: _space,
                selectedChannelId: _channel.id,
                onSelect: _selectChannel,
                onAction: _channelAction,
                ringingId: _calls.incoming?.chat.id,
                home: _home,
                invites: _home ? _invites : const [],
                selectedInviteId: _previewInvite,
                onOpenInvite: _openInvite,
                onNewMessage: _newMessage,
                onReorderFavourites: (ids) => setState(
                  () => _favourites
                    ..clear()
                    ..addAll(ids),
                ),
              ),
            ),
          ],
        ),
        Positioned(
          left: UserBar.inset + MediaQuery.paddingOf(context).left,
          right: UserBar.inset,
          bottom: UserBar.inset + MediaQuery.paddingOf(context).bottom,
          child: UserBar(
            muted: _calls.muted,
            deafened: _calls.deafened,
            onToggleMute: _calls.toggleMute,
            onToggleDeafen: _calls.toggleDeafen,
            onSettings: () => showSettings(context, profile: _profile),
            me: _profile.me,
            onAvatarTap: (anchor) =>
                showStatusPicker(context, _profile, anchor: anchor),
            onDebug: kDebugMode ? _debug : null,
          ),
        ),
      ],
    ),
  );
}

/// Desktop: a card in the top-right corner. Android: pinned across the top.
class _IncomingPosition extends StatelessWidget {
  const _IncomingPosition({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    if (isDesktop) {
      return Positioned(
        top: LoafSpace.x4 + padding.top,
        right: LoafSpace.x4,
        width: IncomingCallCard.width,
        child: child,
      );
    }
    return Positioned(
      top: LoafSpace.x2 + padding.top,
      left: LoafSpace.x2,
      right: LoafSpace.x2,
      child: child,
    );
  }
}
