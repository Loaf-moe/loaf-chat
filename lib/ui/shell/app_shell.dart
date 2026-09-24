/// The app shell: spaces rail, channel list, and the channel you are reading.
///
/// One layout, two arrangements. Above [_wideBreakpoint] the three panes sit
/// side by side, the way the design system's desktop kit draws them. Below
/// it, the rail and channel list move into a drawer and the channel fills the
/// screen — Discord's phone layout, which is the solved version of this.
library;

import 'package:flutter/material.dart';

import '../call/connected_call_bar.dart';
import '../channel/channel_view.dart';
import '../channel/timeline_controller.dart';
import '../members/member_list.dart';
import '../mock/fixtures.dart';
import '../platform.dart';
import '../theme/loaf_theme.dart';
import 'channel_list.dart';
import '../settings/settings_page.dart';
import 'app_notice.dart';
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

  @override
  void dispose() {
    _timeline.dispose();
    super.dispose();
  }

  String _spaceId = mockSpaces.first.id;

  /// Where you were in each space. Switching away and back should not dump
  /// you in the first channel again.
  final _channelBySpace = <String, String>{};

  /// Mockup state: which app notices are showing.
  var _showUpdate = true;
  final _showVerify = true;

  Channel? _connected;
  String? _connectedSpaceName;
  bool _muted = false;
  bool _deafened = false;

  /// Only consulted on wide layouts, where the member list is a column you
  /// can put away. On a phone it is a drawer and opens on demand.
  bool _showMembers = true;

  Space get _space => mockSpaces.firstWhere((s) => s.id == _spaceId);

  Channel get _channel {
    final channels = _space.allChannels;
    final remembered = _channelBySpace[_spaceId];
    return channels.firstWhere(
      (c) => c.id == remembered,
      orElse: () => channels.firstWhere((c) => c.kind == ChannelKind.text),
    );
  }

  void _selectSpace(String id) => setState(() => _spaceId = id);

  void _selectChannel(String id) {
    final channel = _space.allChannels.firstWhere((c) => c.id == id);

    // Tapping a voice channel joins it rather than navigating — you stay
    // where you were reading. That is what makes voice ambient.
    if (channel.kind == ChannelKind.voice) {
      setState(() {
        final alreadyHere = _connected?.id == channel.id;
        _connected = alreadyHere ? null : channel;
        _connectedSpaceName = alreadyHere ? null : _space.name;
        if (alreadyHere) _muted = false;
      });
      return;
    }

    setState(() => _channelBySpace[_spaceId] = id);
    _scaffoldKey.currentState?.closeDrawer();
  }

  void _disconnect() => setState(() {
    _connected = null;
    _connectedSpaceName = null;
    _muted = false;
  });

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

  Widget? _buildCallBar() {
    final connected = _connected;
    if (connected == null) return null;
    return ConnectedCallBar(
      channel: connected,
      spaceName: _connectedSpaceName ?? '',
      muted: _muted,
      onToggleMute: () => setState(() => _muted = !_muted),
      onDisconnect: _disconnect,
      onExpand: () {},
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _wideBreakpoint;

        final channel = ChannelView(
          channel: _channel,
          timeline: _timeline,
          navigationAttention: _notices.any((n) => n.loud),
          callBar: _buildCallBar(),
          onOpenNavigation: wide
              ? null
              : () => _scaffoldKey.currentState?.openDrawer(),
          onToggleMembers: wide
              ? () => setState(() => _showMembers = !_showMembers)
              : () => _scaffoldKey.currentState?.openEndDrawer(),
        );
        final members = MemberList(members: _space.members);

        if (wide) {
          return Scaffold(
            key: _scaffoldKey,
            backgroundColor: tokens.page,
            body: Row(
              children: [
                SizedBox(
                  width: LoafShell.railWidth + LoafShell.sidebarWidth,
                  child: _navigation,
                ),
                Expanded(child: channel),
                if (_showMembers)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border(left: BorderSide(color: tokens.border)),
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
          body: channel,
        );
      },
    );
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
              spaces: mockSpaces,
              selectedSpaceId: _spaceId,
              onSelect: _selectSpace,
              notices: _notices,
            ),
            Expanded(
              child: ChannelList(
                space: _space,
                selectedChannelId: _channel.id,
                onSelect: _selectChannel,
              ),
            ),
          ],
        ),
        Positioned(
          left: UserBar.inset + MediaQuery.paddingOf(context).left,
          right: UserBar.inset,
          bottom: UserBar.inset + MediaQuery.paddingOf(context).bottom,
          child: UserBar(
            muted: _muted,
            deafened: _deafened,
            // Deafening implies muting. Coming back out restores you to
            // unmuted rather than leaving you silently muted for a reason
            // you never chose.
            onToggleMute: () => setState(() {
              _muted = !_muted;
              if (!_muted) _deafened = false;
            }),
            onToggleDeafen: () => setState(() {
              _deafened = !_deafened;
              if (!_deafened) _muted = false;
            }),
            onSettings: () => showSettings(context),
          ),
        ),
      ],
    ),
  );
}
