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
import '../members/member_list.dart';
import '../members/presence_dot.dart';
import '../mock/call_fixtures.dart';
import '../mock/fixtures.dart';
import '../mock/mock_rooms.dart';
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
import '../widgets/toast.dart';
import '../settings/settings_page.dart';
import 'app_notice.dart';
import 'channel_actions.dart';
import 'profile_controller.dart';
import 'shell_faces.dart';
import 'status_picker.dart';
import 'spaces_rail.dart';
import 'user_bar.dart';

/// Below this width the navigation collapses into a drawer.
const _wideBreakpoint = 900.0;

class AppShell extends StatefulWidget {
  const AppShell({super.key, this.session, this.rooms});

  /// Who is signed in, and how far this device is trusted. The app passes
  /// its one session; left out (tests, previews), the shell makes its own.
  final LoafSession? session;

  /// Makes the account's rooms, once, when the shell opens; the shell
  /// disposes them when it closes. Left out, the rooms are the mock's.
  final Rooms Function()? rooms;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _profile = ProfileController();
  late final LoafSession _session = widget.session ?? MockSession();
  late final Rooms _rooms = widget.rooms?.call() ?? MockRooms();
  late final _calls = CallController(
    me: currentUser,
    rings: mockRings,
    flags: mockCallFlags,
    onRecord: _onCallRecord,
  );

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
  }

  void _onChange() => setState(() {});

  @override
  void dispose() {
    _session.removeListener(_onSessionChange);
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

  /// Mockup state: whether the update notice is showing.
  var _showUpdate = true;

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
      if (joining) _rooms.setJoined(id, true);
      _open(_spaceId, id);
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

  Future<void> _addSpace() async {
    final result = await showAddSpace(
      context,
      joined: {for (final s in _spaces) s.id},
      directory: _rooms.directory,
    );
    if (result == null || !mounted) return;
    switch (result) {
      case OpenSpace(:final id):
        setState(() {
          _spaceId = id;
          _fullscreen = false;
        });
      case JoinSpace(:final space):
        await _rooms.joinSpace(space);
        if (!mounted) return;
        setState(() {
          _spaceId = space.id;
          _fullscreen = false;
        });
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

  Future<void> _newMessage() async {
    final me = _me;
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

  /// Made fresh for each request and ended with its panel.
  Future<void> _answerIncoming(IncomingRequest request) async {
    final v = VerificationController(
      purpose: VerifyPurpose.incoming,
      verifier: _session.verifier,
      incoming: request.verification,
      incomingDevice: request.device,
      server: _session.homeserverName,
      onTrusted: () {},
    );
    _incomingFlow = v;
    final finished = await showVerifyPanel(context, v);
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
    // Phones update through the App Store or TestFlight, never in-app. The
    // mock's notice only: there is no updater behind it yet.
    if (_showUpdate && isDesktop && _session is MockSession)
      AppNotice.update(
        version: '0.3.0',
        onAction: () {},
        onDismiss: () => setState(() => _showUpdate = false),
      ),
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

  Widget _buildMain({required bool wide}) {
    final channel = _channel;
    final openNavigation = wide
        ? null
        : () => _scaffoldKey.currentState?.openDrawer();

    final invite = _home
        ? _invites.where((i) => i.id == _previewInvite).firstOrNull
        : null;
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
        (channel.kind == ChannelKind.voice && !_can(RoomAbility.calls))) {
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
                      if (members != null &&
                          _showMembers &&
                          _previewInvite == null &&
                          (channel!.kind == ChannelKind.text ||
                              channel.kind == ChannelKind.room ||
                              // Before messages are wired, a voice channel
                              // is the same pane, toggle and all.
                              (channel.kind == ChannelKind.voice &&
                                  !_can(RoomAbility.messages))))
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
          endDrawer: members == null
              ? null
              : Drawer(
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
    return PresenceScope(
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
    );
  }

  /// Who is in [channel]: a DM's people and you, a Home room's own
  /// members, or a space channel's space. Asks the rooms for the whole
  /// list, where they only have some of it; they say when it arrives.
  MemberList _members(Channel channel, Member me) {
    // Your own row shows your presence and status, which only a backend
    // that edits your profile has; elsewhere the room's row, with your real
    // power level, is the better one.
    Member you(Member m) =>
        m.id == me.id && _can(RoomAbility.editProfile) ? me : m;
    final List<Member> members;
    switch (channel.kind) {
      case ChannelKind.direct:
        members = [me, ...channel.members];
      case ChannelKind.room:
        _rooms.loadMembers(channel.id);
        members = [for (final m in channel.members) you(m)];
      case ChannelKind.text || ChannelKind.voice:
        final space = _space;
        _rooms.loadMembers(space.id);
        members = [for (final m in space.members) you(m)];
    }
    return MemberList(members: members);
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
            ),
            me: _me,
            onAvatarTap: _can(RoomAbility.editProfile)
                ? (anchor) =>
                      showStatusPicker(context, _profile, anchor: anchor)
                : null,
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
