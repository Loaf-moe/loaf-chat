/// The app shell: spaces rail, channel list, and the channel you are reading.
///
/// One layout, two arrangements. Above [_wideBreakpoint] the three panes sit
/// side by side, the way the design system's desktop kit draws them. Below
/// it, the rail and channel list move into a drawer and the channel fills the
/// screen — Discord's phone layout, which is the solved version of this.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../call/call_controller.dart';
import '../call/connected_call_bar.dart';
import '../call/dm_call_panel.dart';
import '../call/incoming_call_card.dart';
import '../call/voice_channel_page.dart';
import '../channel/channel_view.dart';
import '../home/direct_messages.dart';
import '../home/home_sections.dart';
import '../home/new_message_picker.dart';
import '../spaces/add_space.dart';
import '../home/invite_preview.dart';
import '../members/invite_panel.dart';
import '../members/member_list.dart';
import '../members/person_card.dart';
import '../members/presence_dot.dart';
import '../mock/call_fixtures.dart';
import '../mock/fixtures.dart';
import '../mock/mock_rooms.dart';
import 'notifier.dart';
import '../channel/timeline.dart' show messageUnavailable;
import '../model/message_route.dart';
import '../model/updater.dart';
import '../platform.dart';
import '../rooms/rooms.dart';
import '../theme/loaf_theme.dart';
import 'channel_list.dart';
import 'mock_debug.dart';
import '../auth/loaf_session.dart';
import '../mock/mock_session.dart';
import '../verify/verification_controller.dart';
import '../verify/verify_panel.dart';
import '../verify/verify_state.dart';
import '../model/media_source.dart';
import '../widgets/avatar_images.dart';
import '../widgets/toast.dart';
import '../window/window_chrome.dart';
import '../settings/notification_settings.dart';
import '../settings/settings_page.dart';
import 'app_notice.dart';
import 'channel_actions.dart';
import 'idle_watcher.dart';
import 'profile.dart';
import 'profile_controller.dart';
import 'shell_faces.dart';
import 'space_actions.dart';
import 'status_picker.dart';
import 'spaces_rail.dart';
import 'user_bar.dart';

/// Below this width the navigation collapses into a drawer.
const _wideBreakpoint = 900.0;

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    this.session,
    this.rooms,
    this.updater,
    this.routes,
  });

  /// Who is signed in, and how far this device is trusted. The app passes
  /// its one session; left out (tests, previews), the shell makes its own.
  final LoafSession? session;

  /// Makes the account's rooms, once, when the shell opens; the shell
  /// disposes them when it closes. Left out, the rooms are the mock's.
  final Rooms Function()? rooms;

  /// What replaces this copy of the app with a newer one. The app passes
  /// its one updater, which outlives the shell. Left out, the mock plays an
  /// update that is ready and a real session has none.
  final Updater? updater;

  /// Messages to open, as notifications are clicked or tapped. One that
  /// comes before the first sync waits for it.
  final Stream<MessageRoute>? routes;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  late final LoafSession _session = widget.session ?? MockSession();
  late final Rooms _rooms = widget.rooms?.call() ?? MockRooms();
  late final Updater _updater =
      widget.updater ??
      (_session is MockSession
          ? (FakeUpdater(const UpdateReady('0.3.0'))
              ..checkTakes = const Duration(milliseconds: 1500))
          : const NoUpdater());
  // The rooms own the profile and dispose it; the controller only views it.
  late final _profile = ProfileController(
    profile: _rooms.profile,
    onError: _profileFailed,
  );
  StreamSubscription<MessageRoute>? _routes;

  /// A route that came before the rooms were synced: its room may not be
  /// known yet, so it waits rather than say the message isn't there. Only
  /// the latest is kept: of two clicks before the sync, the last one wins.
  MessageRoute? _heldRoute;

  late final _calls = CallController(
    me: currentUser,
    rings: mockRings,
    flags: mockCallFlags,
    onRecord: _onCallRecord,
  );

  Notifier? _notifier;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Not in initState: the scope is an inherited widget. The closures read
    // the controller live, so a later toggle needs no rebuild.
    final notifications = NotificationScope.maybeOf(context);
    if (_notifier == null && notifications != null) {
      _notifier = Notifier(
        arrivals: _rooms.arrivals,
        chime: notifications.chime,
        soundOn: () => notifications.sound,
        openRoom: () => _openMessagesRoom,
      );
    }
  }

  @override
  void initState() {
    super.initState();
    // The channel the app opens on is being read from the first frame.
    // Before listening: nothing is built yet to hear it.
    final opening = _channel;
    if (opening != null && _can(RoomAbility.markRead)) {
      _rooms.markRead(opening.id);
    }
    _rooms.addListener(_onChange);
    _profile.addListener(_onChange);
    _calls.addListener(_onChange);
    _session.addListener(_onSessionChange);
    _updater.addListener(_onChange);
    _routes = widget.routes?.listen(_follow);
  }

  void _onChange() {
    final held = _heldRoute;
    if (held != null && _rooms.synced) {
      _heldRoute = null;
      _follow(held);
    }
    setState(() {});
  }

  /// A presence or status write the server refused: the profile has already
  /// put things back, so a toast says to try again.
  void _profileFailed(ProfileCall call, Object error) {
    if (!mounted) return;
    showToast(
      context,
      error is HalfApplied
          ? 'do not disturb only half-applied. try again?'
          : switch (call) {
              ProfileCall.presence =>
                "couldn't change your presence. try again?",
              ProfileCall.status => "couldn't save your status. try again?",
            },
    );
  }

  @override
  void dispose() {
    _notifier?.dispose();
    unawaited(_routes?.cancel());
    _session.removeListener(_onSessionChange);
    _updater.removeListener(_onChange);
    if (widget.updater == null) _updater.dispose();
    _rooms
      ..removeListener(_onChange)
      ..dispose();
    _keep(null)?.dispose();
    _incomingFlow?.dispose();
    _incomingFlow = null;
    if (widget.session == null) _session.dispose();
    _profile
      ..removeListener(_onChange)
      ..dispose();
    _calls
      ..removeListener(_onChange)
      ..dispose();
    super.dispose();
  }

  late String _spaceId = _rooms.spaces.firstOrNull?.id ?? mockHome.id;

  /// Where you were in each space. Switching away and back should not dump
  /// you in the first channel again.
  final _channelBySpace = <String, String>{};

  /// The update put off with "later", until the next launch. The empty
  /// string stands for one that came without a version.
  String? _laterUpdate;

  AppNotice? get _updateNotice => switch (_updater.state) {
    UpdateReady(:final version) when _laterUpdate != (version ?? '') =>
      AppNotice.update(
        version: version,
        onAction: () => unawaited(_updater.restart()),
        onDismiss: () => setState(() => _laterUpdate = version ?? ''),
      ),
    UpdateApplying(:final version) => AppNotice.update(
      version: version,
      applying: true,
    ),
    _ => null,
  };

  /// Only consulted on wide layouts, where the member list is a column you
  /// can put away. On a phone it is a drawer and opens on demand.
  bool _showMembers = true;

  /// The DM call panel fills the conversation rather than docking above it.
  bool _dmPanelExpanded = false;

  /// Desktop only: the voice call fills the window.
  bool _fullscreen = false;

  // What the call and timeline mocks add over the rooms: missed calls
  // count as unread, and a DM that saw a message or a call moves up. They
  // go when those mocks do.
  final _missedCalls = <String, int>{};
  final _activity = <String, DateTime>{};

  /// The invite being previewed in place of a conversation, if any.
  String? _previewInvite;

  /// The invite whose answer is on its way to the server, and which.
  (String, Answering)? _answering;

  List<Space> get _spaces => _rooms.spaces;

  List<Invite> get _invites => _rooms.invites;

  /// Where you are: the space you chose, or Home once it has gone — left
  /// from another client, say.
  String get _placeId =>
      _spaceId != mockHome.id && _spaces.any((s) => s.id == _spaceId)
      ? _spaceId
      : mockHome.id;

  bool get _home => _placeId == mockHome.id;

  bool _can(RoomAbility ability) => _rooms.abilities.contains(ability);

  /// Whether a voice channel opens to its call page. Without both, it is a
  /// room's header over a line saying voice isn't available.
  bool get _voiceWorks => _can(RoomAbility.messages) && _can(RoomAbility.calls);

  /// The row actions the rooms can carry out. Older conversations is only
  /// a way to reach a room, so it is always there.
  Set<ChannelAction> get _allowedActions => {
    if (_can(RoomAbility.markRead)) ChannelAction.markRead,
    if (_can(RoomAbility.tag)) ...[
      ChannelAction.favourite,
      ChannelAction.unfavourite,
      ChannelAction.lowPriority,
      ChannelAction.notLowPriority,
    ],
    ChannelAction.olderConversations,
    if (_can(RoomAbility.mute)) ...[ChannelAction.mute, ChannelAction.unmute],
    if (_can(RoomAbility.invite)) ChannelAction.invite,
    if (_can(RoomAbility.leave)) ChannelAction.leave,
  };

  /// You as others see you: with your presence and status where the
  /// backend can set them, and as the rooms know you where it cannot.
  Member get _me => _can(RoomAbility.editProfile) ? _profile.me : _rooms.me;

  /// Home's rooms with the calls' and timelines' changes layered on.
  List<Channel> get _homeRooms => [
    for (final room in _rooms.homeRooms)
      room.copyWith(
        lastActivity: _activity[room.id],
        // Per room, before duplicates fold together, so an older room's
        // missed calls still count on the row.
        unread: room.unread + (_missedCalls[room.id] ?? 0),
      ),
  ];

  Space get _space {
    if (!_home) {
      return _spaces
          .firstWhere((s) => s.id == _placeId)
          .withSession(occupants: _callOccupants, unread: _missedCalls);
    }
    return Space(
      id: mockHome.id,
      name: mockHome.name,
      color: mockHome.color,
      members: mockHome.members,
      categories: homeSections(collapseDuplicates(_homeRooms)),
    ).withSession(occupants: _callOccupants);
  }

  /// Who is in the call you are in, you included — so its channel or DM
  /// lists you under it like everyone else.
  Map<String, List<Member>> get _callOccupants {
    final session = _calls.session;
    if (session == null || !_calls.inCall) return const {};
    if (session.phase == CallPhase.ringing) return const {};
    return {
      session.target.id: [
        _me,
        for (final p in session.participants)
          if (p.present) p.member,
      ],
    };
  }

  /// The conversation you are reading: the one you last opened here while
  /// it is still here, else the first you can read. Null when there is none
  /// — the first sync is still coming, or the account is in no rooms.
  Channel? get _channel {
    final rows = _space.allChannels;
    // An older duplicate DM is not a row of its own, but can be open.
    final channels = [...rows, for (final row in rows) ...row.earlier];
    final remembered = _channelBySpace[_placeId];
    return channels.where((c) => c.id == remembered && c.joined).firstOrNull ??
        channels
            .where((c) => c.kind != ChannelKind.voice && c.joined)
            .firstOrNull;
  }

  void _selectSpace(String id) => setState(() {
    _spaceId = id;
    // A space opens onto a conversation, and seeing it is reading it.
    _open(id, _channel?.id);
  });

  /// Goes to [spaceId], and opens [channelId] there if there is one.
  void _open(String spaceId, String? channelId) {
    _spaceId = spaceId;
    _fullscreen = false;
    _previewInvite = null;
    if (channelId == null) return;
    _channelBySpace[spaceId] = channelId;
    // Seeing a conversation is reading it, in a space as much as in Home.
    if (_can(RoomAbility.markRead)) _rooms.markRead(channelId);
    _missedCalls.remove(channelId);
  }

  void _selectChannel(String id) {
    final channel = _space.allChannels.firstWhere((c) => c.id == id);

    // Tapping a channel you are not in joins it and opens it. A voice
    // channel opens to its lobby rather than connecting: membership and
    // being in the call are separate steps.
    final joining = !channel.joined;
    // A backend that cannot join has nothing to open here.
    if (joining && !_can(RoomAbility.join)) return;
    setState(() {
      if (joining) unawaited(_rooms.setJoined(id, true).catchError(_refused));
      // The place on screen, not [_spaceId]: that can still name a space
      // chosen but not synced yet, and a choice kept under it would never
      // be the one [_channel] reads, so every tap here would do nothing.
      _open(_placeId, id);
      // A conversation left back in history opens at its newest again:
      // choosing a channel is asking for what is happening there now.
      if (channel.kind != ChannelKind.voice && _can(RoomAbility.messages)) {
        _rooms.timeline(id)?.showNewest();
      }
      // A computer connects on click; a phone shows the lobby first, since a
      // stray tap there should never open a live mic.
      if (channel.kind == ChannelKind.voice &&
          !joining &&
          isDesktop &&
          _can(RoomAbility.calls)) {
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
    if (action == ChannelAction.invite) {
      final row = _space.allChannels.firstWhere((c) => c.id == id);
      await _openInvitePanel(id, row.name, row.members);
      return;
    }
    setState(() => _applyChannelAction(id, action));
  }

  void _applyChannelAction(String id, ChannelAction action) {
    switch (action) {
      case ChannelAction.markRead:
        _rooms.markRead(id);
      case ChannelAction.favourite:
        unawaited(_rooms.setFavourite(id, true).catchError(_refused));
      case ChannelAction.unfavourite:
        unawaited(_rooms.setFavourite(id, false).catchError(_refused));
      case ChannelAction.lowPriority:
        unawaited(_rooms.setLowPriority(id, true).catchError(_refused));
      case ChannelAction.notLowPriority:
        unawaited(_rooms.setLowPriority(id, false).catchError(_refused));
      case ChannelAction.olderConversations:
        break; // Handled before any state changes: it asks first.
      case ChannelAction.invite:
        break; // Handled before any state changes: it opens the panel first.
      case ChannelAction.mute:
        unawaited(_rooms.setMuted(id, true).catchError(_refused));
      case ChannelAction.unmute:
        unawaited(_rooms.setMuted(id, false).catchError(_refused));
      case ChannelAction.leave:
        // Leaving the channel you are reading falls through to the space's
        // first joined text channel: see _channel.
        unawaited(_rooms.setJoined(id, false).catchError(_refused));
        // Leaving a voice channel you are in takes you out of the call too.
        if (_calls.session?.target.id == id) _calls.leave();
    }
  }

  /// A quick toggle's refusal: the change snaps back once the listener
  /// hears the backend's own state again, and a toast says to try again.
  void _refused(Object error) {
    if (mounted) showToast(context, "couldn't do that. try again?");
  }

  void _reorderFavourites(List<String> roomIds) =>
      unawaited(_rooms.reorderFavourites(roomIds).catchError(_refused));

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

  /// Every room you are in that an address could name: the spaces on the
  /// rail, the channels you joined in them, and Home's rooms.
  Set<String> get _joinedIds => {
    for (final space in _spaces) ...[
      space.id,
      for (final c in space.allChannels)
        if (c.joined) c.id,
    ],
    for (final room in _rooms.homeRooms) room.id,
  };

  /// Goes to [id] wherever it lives: a space opens onto its conversation,
  /// and a room you are in opens in its space or in Home. Anything else is
  /// a space the server has made or let you into but sync has yet to
  /// bring, chosen now so the shell moves there once it arrives.
  void _goTo(String id) {
    if (_spaces.any((s) => s.id == id)) {
      _spaceId = id;
      _open(id, _channel?.id);
      return;
    }
    // The space on screen wins when it has the room: a room can sit in
    // several spaces, and moving you out of this one would be a surprise.
    final here =
        !_home && _space.allChannels.any((c) => c.id == id && c.joined);
    final space = here
        ? _spaces.firstWhere((s) => s.id == _placeId)
        : _spaces
              .where((s) => s.allChannels.any((c) => c.id == id && c.joined))
              .firstOrNull;
    if (space != null) {
      _open(space.id, id);
    } else if (_rooms.homeRooms.any((r) => r.id == id)) {
      _open(mockHome.id, id);
    } else {
      _open(id, null);
    }
  }

  /// Opens the message [route] names. Its room opens where [_goTo] puts
  /// it, then the conversation brings the message into view. A room you
  /// are not in has nothing to open, so you stay where you are.
  void _follow(MessageRoute route) {
    if (!mounted) return;
    if (!_rooms.synced) {
      _heldRoute = route;
      return;
    }
    final id = route.roomId;
    final joined = !_spaces.any((s) => s.id == id) && _joinedIds.contains(id);
    final timeline = joined ? _rooms.timeline(id) : null;
    if (timeline == null) {
      showToast(context, messageUnavailable);
      return;
    }
    setState(() => _goTo(id));
    _scaffoldKey.currentState?.closeDrawer();
    timeline.jumpTo(route.eventId);
  }

  Future<void> _addSpace() async {
    final result = await showAddSpace(
      context,
      joined: _joinedIds,
      directory: _rooms.directory,
      onCreate: (name) => _rooms.createSpace(name, me: _me),
    );
    if (result == null || !mounted) return;
    switch (result) {
      case OpenSpace(:final id, :final missing):
        setState(() {
          if (missing.isEmpty) {
            _goTo(id);
          } else {
            _open(id, '$id-general');
          }
        });
        if (missing.isNotEmpty && mounted) {
          showToast(
            context,
            "made it, but ${missing.join(' and ')} didn't happen",
          );
        }
      case JoinSpace(:final space):
        try {
          await _rooms.joinSpace(space);
        } on Object {
          // The panel is already closed, so the toast is the way forward:
          // stay where you were rather than open a space that isn't joined.
          if (mounted) {
            showToast(context, "couldn't join ${space.name}. try again?");
          }
          return;
        }
        if (!mounted) return;
        setState(() => _goTo(space.id));
      case CreateSpace(:final name):
        final id = await _rooms.createSpace(name, me: _me);
        if (!mounted) return;
        setState(() {
          _open(id, '$id-general');
          _fullscreen = false;
        });
    }
    _scaffoldKey.currentState?.closeDrawer();
  }

  // ── New messages ───────────────────────────────────────────────────

  /// Everyone you could start with or invite: people you share a space or
  /// a DM with, keyed by id so someone in several places counts once.
  Map<String, Member> _knownPeople() {
    final me = _me;
    return {
      for (final space in _spaces)
        for (final m in space.members)
          if (m.id != me.id) m.id: m,
      for (final room in _homeRooms)
        for (final m in room.members)
          if (m.id != me.id) m.id: m,
    };
  }

  Future<void> _newMessage() async {
    final start = await showNewMessagePicker(
      context,
      people: _knownPeople().values.toList(),
      rooms: [
        for (final room in _homeRooms)
          if (room.kind == ChannelKind.direct) room,
      ],
      onStart: _rooms.createDirect,
    );
    if (start == null || !mounted) return;
    switch (start) {
      case OpenExisting(:final room):
        setState(() => _open(mockHome.id, room.id));
      case CreateDirect(:final members):
        final dm = await _rooms.createDirect(members);
        if (!mounted) return;
        setState(() => _open(mockHome.id, dm.id));
    }
    _scaffoldKey.currentState?.closeDrawer();
  }

  // ── Invites ──────────────────────────────────────────────────────────

  /// Opens the invite panel for [roomId]: everyone known minus whoever is
  /// already in it. On success it toasts how many went through; a refusal
  /// is the panel's own to show and retry.
  Future<void> _openInvitePanel(
    String roomId,
    String roomName,
    List<Member> already,
  ) async {
    final alreadyIn = {for (final m in already) m.id};
    final people = [
      for (final m in _knownPeople().values)
        if (!alreadyIn.contains(m.id)) m,
    ];
    await showInvitePanel(
      context,
      roomName: roomName,
      people: people,
      onInvite: (ids) async {
        await _rooms.invite(roomId, ids);
        if (mounted) {
          showToast(
            context,
            ids.length == 1
                ? 'invited 1 person'
                : 'invited ${ids.length} people',
          );
        }
      },
    );
  }

  // ── Spaces ───────────────────────────────────────────────────────────

  /// The space menu was asked for: resolves what it can offer and opens
  /// it, a sheet on a phone, a menu at [position] on a computer.
  Future<void> _openSpaceActions(String spaceId, Offset position) async {
    final space = _spaces.firstWhere((s) => s.id == spaceId);
    final allowed = {
      if (_can(RoomAbility.invite)) SpaceAction.invite,
      if (_can(RoomAbility.leave)) SpaceAction.leave,
    };
    final chosen = await showSpaceActions(
      context,
      space,
      position: position,
      allowed: allowed,
    );
    if (chosen != null && mounted) await _spaceAction(space, chosen);
  }

  Future<void> _spaceAction(Space space, SpaceAction action) async {
    switch (action) {
      case SpaceAction.invite:
        await _openInvitePanel(space.id, space.name, space.members);
      case SpaceAction.leave:
        final rooms = space.allChannels.where((c) => c.joined).length;
        final confirmed = await confirmLeaveSpace(context, space, rooms: rooms);
        if (!confirmed || !mounted) return;
        // Once confirmed there is no cancelling it. If you are inside the
        // space, move to Home at once rather than waiting on the network;
        // from anywhere else, stay where you are.
        if (_spaceId == space.id) setState(() => _open(mockHome.id, null));
        unawaited(
          _rooms.leaveSpace(space.id).catchError((Object error) {
            if (!mounted) return;
            if (error is PartlyDone) {
              showToast(context, "couldn't leave everything in ${space.name}");
            } else {
              _refused(error);
            }
          }),
        );
    }
  }

  // ── Invites ────────────────────────────────────────────────────────────

  void _openInvite(String id) {
    setState(() => _previewInvite = id);
    _scaffoldKey.currentState?.closeDrawer();
  }

  /// A DM or room joins its section and opens; a space joins the rail and
  /// you stay in Home, where the rest of your invites are. A room the
  /// server has let you into but not yet synced opens once it arrives:
  /// until then the list's first room holds its place.
  Future<void> _acceptInvite(Invite invite) async {
    if (!await _answer(invite, Answering.accepting)) return;
    setState(() {
      _previewInvite = null;
      final room = invite.room;
      if (room != null) _open(mockHome.id, room.id);
    });
  }

  Future<void> _declineInvite(Invite invite) async {
    if (!await _answer(invite, Answering.declining)) return;
    setState(() => _previewInvite = null);
  }

  /// Sends the answer, spinning its button meanwhile. False when it failed,
  /// which leaves the preview up with its buttons to try again, or when the
  /// shell has gone.
  Future<bool> _answer(Invite invite, Answering answering) async {
    setState(() => _answering = (invite.id, answering));
    try {
      await (answering == Answering.accepting
          ? _rooms.accept(invite)
          : _rooms.decline(invite));
      return mounted;
    } on Object {
      if (mounted) {
        showToast(
          context,
          answering == Answering.accepting
              ? "couldn't join. try again?"
              : "couldn't decline. try again?",
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _answering = null);
    }
  }

  void _onCallRecord(Channel chat, CallRecord record) {
    _activity[chat.id] = DateTime.now();
    // Calls are the mock's alone, and so are the lines they leave.
    final rooms = _rooms;
    if (rooms is! MockRooms) return;
    rooms
        .timeline(chat.id)
        .addCall(
          record.label,
          record is EndedCall ? CallLine.ended : CallLine.missed,
          from: chat.members.first,
        );
    final looking = _home && _channel?.id == chat.id;
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
    final pick = await showMockDebug(
      context,
      anchor,
      presenceShared: _profile.presenceShared,
      nextCheck: switch (_updater) {
        final FakeUpdater fake => fake.nextCheck,
        _ => UpdateCheck.upToDate,
      },
    );
    if (pick == null) return;
    switch (pick) {
      case MockDebug.ringFromMika:
        _ring('dm-mika', '@mika');
      case MockDebug.ringFromCrew:
        _ring('dm-crew', '@jun');
      case MockDebug.reconnecting:
        _calls.toggleReconnecting();
      case MockDebug.failNext:
        // One "make the next thing fail" lever: the next call, sign-in or
        // verification, whichever comes first for each.
        _calls.failNextConnection();
        if (_session case final MockSession mock) mock.failNext();
      case MockDebug.encryption:
        _calls.toggleEncryption();
      case MockDebug.micBlocked:
        _calls.toggleMicBlocked();
      case MockDebug.cameraBlocked:
        _calls.toggleCameraBlocked();
      case MockDebug.presence:
        _profile.togglePresenceShared();
      case MockDebug.remoteShare:
        final someone = _calls.session?.participants
            .where((p) => p.present)
            .firstOrNull;
        if (someone != null) _calls.toggleRemoteShare(someone.member.id);
      case MockDebug.signOut:
        _session.signOut();
      // The account levers only move the mock; a real account's state
      // comes from its server.
      case MockDebug.expireSession:
        if (_session case final MockSession mock) mock.expireSession();
      case MockDebug.freshAccount:
        if (_session case final MockSession mock) mock.useFreshAccount();
      case MockDebug.newSignIn:
        if (_session case final MockSession mock) mock.receiveRequest();
      case MockDebug.personAsks:
        if (_session case final MockSession mock) mock.receivePersonRequest();
      // The update levers move the mock's fake updater only.
      case MockDebug.forgetUpdate:
        if (_updater case final FakeUpdater fake) {
          fake.state = const UpdateIdle();
        }
      case MockDebug.nextUpdateCheck:
        if (_updater case final FakeUpdater fake) {
          fake.nextCheck = UpdateCheck
              .values[(fake.nextCheck.index + 1) % UpdateCheck.values.length];
        }
    }
  }

  IncomingRequest? _shownRequest;

  void _onSessionChange() {
    setState(() {});
    final request = _session.incoming;
    if (request == null || identical(request, _shownRequest)) return;
    _shownRequest = request;
    // Straight away rather than as a notice: it is time-bound, and you
    // usually asked for it on the other device seconds ago.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _openVerification(VerifyPurpose.incoming, request: request);
      }
    });
  }

  /// The verification flow in hand, kept only while it works unseen
  /// (history restoring after the panel was put away, a new key being made
  /// or waiting to be saved). Never an incoming request's. Listened to, so
  /// the rail follows a key it holds.
  VerificationController? _verification;

  /// Swaps the flow in hand, moving the listener with it; returns the one
  /// it replaced, for the caller to dispose.
  VerificationController? _keep(VerificationController? v) {
    final old = _verification;
    if (identical(old, v)) return null;
    old?.removeListener(_onChange);
    v?.addListener(_onChange);
    _verification = v;
    return old;
  }

  /// The incoming request's flow, while its panel is up. Its own slot: a
  /// request can arrive over any open flow, and must never end that one —
  /// a key being made or shown unsaved would be lost with it.
  VerificationController? _incomingFlow;

  Future<void> _openVerification(
    VerifyPurpose purpose, {
    IncomingRequest? request,
  }) async {
    if (purpose == VerifyPurpose.incoming) {
      if (request != null) await _answerIncoming(request);
      return;
    }
    final kept = _verification;
    final VerificationController v;
    // A flow that works unseen is reopened whatever was asked for: ending
    // it could drop a key being made, or stop history mid-restore.
    if (kept != null && (kept.purpose == purpose || kept.worksUnseen)) {
      v = kept;
    } else {
      v = VerificationController(
        purpose: purpose,
        verifier: _session.verifier,
        server: _session.homeserverName,
        onTrusted: _session.markVerified,
      );
    }
    _keep(v)?.dispose();
    final finished = await showVerifyPanel(context, v);
    if (!mounted) return;
    if (finished == true) showToast(context, v.doneMessage);
    // A flow put away mid-restore, or holding a key, carries on; any other
    // starts over next time, rather than resuming a stale wait.
    if (!v.worksUnseen && identical(_verification, v)) {
      _keep(null);
      v.dispose();
    }
  }

  void _openDevices() {
    if (!mounted) return;
    unawaited(
      showSettings(
        context,
        initial: SettingsSection.devices,
        devices: _rooms.devices,
        profile: _profile,
        me: _me,
        editable: _can(RoomAbility.editProfile),
        onSignOut: _session.signOut,
        updater: _updater,
      ),
    );
  }

  /// Made fresh for each request and ended with its panel.
  Future<void> _answerIncoming(IncomingRequest request) async {
    final person = request.person;
    final v = VerificationController(
      purpose: person == null ? VerifyPurpose.incoming : VerifyPurpose.person,
      verifier: _session.verifier,
      incoming: request.verification,
      incomingDevice: request.device,
      personName: person,
      server: _session.homeserverName,
      onTrusted: () {},
    );
    _incomingFlow = v;
    final finished = await showVerifyPanel(
      context,
      v,
      // "that's not me" points at the sessions, where a stranger's signs out.
      onOpenDevices: person == null && _can(RoomAbility.devices)
          ? _openDevices
          : null,
    );
    // Already ended if the shell went while the panel was up.
    if (identical(_incomingFlow, v)) {
      _incomingFlow = null;
      v.dispose();
    }
    _session.clearIncoming();
    if (mounted && finished == true) showToast(context, v.doneMessage);
  }

  // ── Building ───────────────────────────────────────────────────────────

  List<AppNotice> get _notices => [
    // A key being made or shown unsaved outranks verifying: on a real server
    // trust flips the moment the identity exists, and this is then the only
    // way back to the key.
    if (_verification case final kept? when kept.holdsKey)
      AppNotice.newKey(
        onAction: () => _openVerification(kept.purpose),
        making: kept.state.step != VerifyStep.showKey,
      )
    else if (_session.trust == DeviceTrust.unverified)
      AppNotice.verify(onAction: () => _openVerification(VerifyPurpose.verify))
    else if (_session.trust == DeviceTrust.noIdentity)
      AppNotice.setUpRecovery(
        onAction: () => _openVerification(VerifyPurpose.setUp),
      ),
    // Phones update through the App Store or TestFlight, never in-app.
    if (isDesktop) ?_updateNotice,
  ];

  /// Whether the call's own page or panel is what you are looking at, in
  /// which case the bar would only repeat it.
  bool get _lookingAtCall =>
      _calls.session?.target.id == _channel?.id &&
      (_home || _channel?.kind == ChannelKind.voice);

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

  /// The invite on screen in place of a channel, if any. Shared by
  /// [_buildMain] and [_openMessagesRoom] so the two can't drift.
  Invite? get _previewedInvite =>
      _home ? _invites.where((i) => i.id == _previewInvite).firstOrNull : null;

  /// The channel whose messages are on screen right now, which is being
  /// read, so its new messages don't chime. Null for an invite preview, a
  /// voice channel page, the nothing-here or syncing face, and a channel
  /// that can't show messages yet. Mirrors where [_buildMain] builds a
  /// message view.
  String? get _openMessagesRoom {
    final channel = _channel;
    if (_previewedInvite != null || channel == null) return null;
    if (!_can(RoomAbility.messages) || channel.kind == ChannelKind.voice) {
      return null;
    }
    return channel.id;
  }

  Widget _buildMain({required bool wide}) {
    final channel = _channel;
    final openNavigation = wide
        ? null
        : () => _scaffoldKey.currentState?.openDrawer();

    final invite = _previewedInvite;
    if (invite != null) {
      final (answeringId, answering) = _answering ?? ('', null);
      return InvitePreview(
        invite: invite,
        onAccept: () => _acceptInvite(invite),
        onDecline: () => _declineInvite(invite),
        answering: answeringId == invite.id ? answering : null,
        onOpenNavigation: openNavigation,
      );
    }

    if (channel == null) {
      return _rooms.synced
          ? NothingHereFace(onOpenNavigation: openNavigation)
          : SyncingFace(
              progress: _rooms.syncProgress,
              onOpenNavigation: openNavigation,
            );
    }

    // Before the backend can read messages, every room is its header and a
    // line saying so — and so is a voice channel before it can join calls,
    // since joining one is that channel's only next step.
    if (!_can(RoomAbility.messages) ||
        (channel.kind == ChannelKind.voice && !_voiceWorks)) {
      return ChannelView(
        channel: channel,
        timeline: null,
        navigationAttention: _notices.any((n) => n.loud),
        onOpenNavigation: openNavigation,
        onToggleMembers: wide
            ? () => setState(() => _showMembers = !_showMembers)
            : () => _scaffoldKey.currentState?.openEndDrawer(),
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
      timeline: _rooms.timeline(channel.id),
      onRead: _can(RoomAbility.markRead)
          ? () => _rooms.markRead(channel.id)
          : null,
      trust: _session.trust,
      onVerify: () => _openVerification(
        _session.trust == DeviceTrust.noIdentity
            ? VerifyPurpose.setUp
            : VerifyPurpose.verify,
      ),
      navigationAttention: _notices.any((n) => n.loud),
      callBar: _buildCallBar(),
      onOpenNavigation: openNavigation,
      onToggleMembers: wide
          ? () => setState(() => _showMembers = !_showMembers)
          : () => _scaffoldKey.currentState?.openEndDrawer(),
      onStartCall: callHere || !_can(RoomAbility.calls)
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
      people: _members(channel, _me).members,
      channels: _mentionableChannels,
    );
  }

  /// What `#` offers in the composer: the space's channels, or Home's rooms
  /// — never its DMs, which are people rather than places.
  List<Channel> get _mentionableChannels => _home
      ? [
          for (final room in _homeRooms)
            if (room.kind == ChannelKind.room) room,
        ]
      : _space.allChannels.toList();

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
    if (_fullscreen &&
        !(_calls.inCall && _channel?.kind == ChannelKind.voice)) {
      _fullscreen = false;
    }

    final shell = LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _wideBreakpoint;

        final main = _buildMain(wide: wide);
        final me = _me;
        final channel = _channel;
        final members = channel == null ? null : _members(channel, me);
        final membersShown =
            members != null &&
            _showMembers &&
            _previewInvite == null &&
            (channel!.kind == ChannelKind.text ||
                channel.kind == ChannelKind.room ||
                // A voice channel that can't be joined yet is
                // the same pane as a room, toggle and all.
                (channel.kind == ChannelKind.voice && !_voiceWorks));

        if (wide) {
          return Scaffold(
            key: _scaffoldKey,
            backgroundColor: tokens.page,
            body: _fullscreen
                ? main
                : Row(
                    children: [
                      // Each column says which window corner it touches, so
                      // exactly one bar draws each corner's buttons.
                      WindowEdges(
                        leading: true,
                        trailing: false,
                        child: SizedBox(
                          width: LoafShell.railWidth + LoafShell.sidebarWidth,
                          child: _navigation,
                        ),
                      ),
                      Expanded(
                        child: WindowEdges(
                          leading: false,
                          trailing: !membersShown,
                          child: main,
                        ),
                      ),
                      if (membersShown)
                        WindowEdges(
                          leading: false,
                          trailing: true,
                          child: DecoratedBox(
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
            // Drawers slide over the page that already holds the buttons.
            child: WindowEdges.none(child: _navigation),
          ),
          // The mirror of the navigation drawer: same width rules, same
          // edge-to-edge surface.
          endDrawer: members == null
              ? null
              : Drawer(
                  width: drawerWidth.clamp(0.0, LoafShell.memberListWidth + 40),
                  shape: const RoundedRectangleBorder(),
                  backgroundColor: tokens.sidebar,
                  child: WindowEdges.none(child: members),
                ),
          body: main,
        );
      },
    );

    final ring = _calls.incoming;
    final scoped = AvatarImagesScope(
      images: _rooms.avatarImages,
      child: MediaSourceScope(
        source: _rooms.media,
        child: PresenceScope(
          shared: _profile.presenceShared,
          child: CallbackShortcuts(
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
          ),
        ),
      ),
    );
    // Only where there is a profile to be away from.
    return _can(RoomAbility.editProfile)
        ? IdleWatcher(onAway: _profile.away, child: scoped)
        : scoped;
  }

  /// Who is in [channel]: a DM's people and you, a Home room's own
  /// members, or a space channel's space. Asks the rooms for the whole
  /// list, where they only have some of it; they say when it arrives.
  MemberList _members(Channel channel, Member me) {
    // Your own row shows your presence and status, which only a backend
    // that edits your profile has; elsewhere the room's row, with your real
    // power level, is the better one.
    Member you(Member m) {
      if (!_can(RoomAbility.editProfile)) return m;
      if (m.id == me.id) return me;
      // Others show what the server last said of them; where nothing was
      // heard, the row's own presence stands.
      final heard = _profile.presenceOf(m.id);
      return heard == null
          ? m
          : m.copyWith(presence: heard.$1, statusMessage: heard.$2);
    }

    final List<Member> members;
    switch (channel.kind) {
      case ChannelKind.direct:
        members = [me, for (final m in channel.members) you(m)];
      case ChannelKind.room:
        _rooms.loadMembers(channel.id);
        members = [for (final m in channel.members) you(m)];
      case ChannelKind.text || ChannelKind.voice:
        final space = _space;
        _rooms.loadMembers(space.id);
        members = [for (final m in space.members) you(m)];
    }
    return MemberList(members: members, onOpen: _openPerson);
  }

  /// Someone's card, and verifying them if that is what it was opened for.
  Future<void> _openPerson(Member member) async {
    final verifier = _session.verifier;
    final verify = await showPersonCard(
      context,
      member: member,
      trust: verifier.personTrust(member.id),
      isYou: member.id == _me.id,
      canVerify: _session.trust == DeviceTrust.verified,
    );
    if (verify != true || !mounted) return;
    final v = VerificationController(
      purpose: VerifyPurpose.person,
      verifier: verifier,
      personId: member.id,
      personName: member.name,
      server: _session.homeserverName,
      onTrusted: () {},
    );
    final finished = await showVerifyPanel(context, v);
    final done = v.doneMessage;
    // Ends a request still waiting on them: closing the panel withdraws it.
    v.dispose();
    if (mounted && finished == true) showToast(context, done);
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
              spaces: _spaces,
              selectedSpaceId: _placeId,
              onSelect: _selectSpace,
              notices: _notices,
              homeSelected: _home,
              onHome: () => _selectSpace(mockHome.id),
              homeBadge: _homeBadge,
              homeRinging: _calls.incoming != null,
              onAddSpace: _addSpace,
              addSpace: _can(RoomAbility.addSpace),
              onSpaceActions:
                  _can(RoomAbility.invite) || _can(RoomAbility.leave)
                  ? _openSpaceActions
                  : null,
            ),
            Expanded(
              child: ChannelList(
                space: _space,
                selectedChannelId: _channel?.id ?? '',
                onSelect: _selectChannel,
                onAction: _channelAction,
                allowedActions: _allowedActions,
                ringingId: _calls.incoming?.chat.id,
                home: _home,
                invites: _home ? _invites : const [],
                selectedInviteId: _previewInvite,
                onOpenInvite: _openInvite,
                onNewMessage: _can(RoomAbility.startDirect)
                    ? _newMessage
                    : null,
                onReorderFavourites: _can(RoomAbility.tag)
                    ? _reorderFavourites
                    : null,
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
            callControls: _can(RoomAbility.calls),
            onSettings: () => showSettings(
              context,
              profile: _profile,
              me: _me,
              editable: _can(RoomAbility.editProfile),
              onSignOut: _session.signOut,
              devices: _can(RoomAbility.devices) ? _rooms.devices : null,
              updater: _updater,
            ),
            me: _me,
            onAvatarTap: _can(RoomAbility.editProfile)
                ? (anchor) =>
                      showStatusPicker(context, _profile, anchor: anchor)
                : null,
            // The levers drive the mocks. On a real account they would
            // ring fake calls over real rooms, and sign-out is real.
            onDebug: kDebugMode && _session is MockSession ? _debug : null,
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
