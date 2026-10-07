/// A voice channel's page. The call is the channel, so this takes the
/// channel view's place: the live call when you are connected, the lobby
/// when you are not.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../members/role_colors.dart';
import '../mock/fixtures.dart';
import '../platform.dart';
import '../theme/loaf_theme.dart';
import '../widgets/loaf_button.dart';
import '../window/window_chrome.dart';
import 'call_controller.dart';
import 'call_controls.dart';
import 'call_stage.dart';
import 'call_tile.dart';
import 'call_view.dart';

class VoiceChannelPage extends StatelessWidget {
  const VoiceChannelPage({
    super.key,
    required this.channel,
    required this.calls,
    required this.onJoin,
    this.onOpenNavigation,
    this.fullscreen = false,
    this.onToggleFullscreen,
  });

  final Channel channel;
  final CallController calls;
  final VoidCallback onJoin;

  /// The phone layout's way back to the channel list.
  final VoidCallback? onOpenNavigation;

  final bool fullscreen;
  final VoidCallback? onToggleFullscreen;

  bool get _connectedHere =>
      calls.inCall && calls.session!.target.id == channel.id;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final nav = onOpenNavigation == null
        ? null
        : TopBarButton(
            icon: LucideIcons.menu,
            tooltip: 'Channels',
            onTap: onOpenNavigation,
          );
    final Widget body;
    if (_connectedHere) {
      body = CallView(
        calls: calls,
        leading: nav,
        trailing: [
          if (isDesktop && onToggleFullscreen != null)
            TopBarButton(
              icon: fullscreen ? LucideIcons.minimize : LucideIcons.maximize,
              tooltip: fullscreen ? 'Exit fullscreen' : 'Fullscreen',
              onTap: onToggleFullscreen,
            ),
        ],
      );
    } else {
      body = _Lobby(
        channel: channel,
        calls: calls,
        onJoin: onJoin,
        leading: nav,
      );
    }
    return ColoredBox(
      color: tokens.page,
      child: SafeArea(child: body),
    );
  }
}

/// Who is there, your preview, and a choice of mic and camera before you
/// commit: on a phone, a mistimed tap should never open a live mic.
class _Lobby extends StatelessWidget {
  const _Lobby({
    required this.channel,
    required this.calls,
    required this.onJoin,
    this.leading,
  });

  final Channel channel;
  final CallController calls;
  final VoidCallback onJoin;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final count = channel.occupants.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WindowDragArea(
          child: Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x3),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: tokens.border)),
            ),
            child: Row(
              children: [
                const WindowControls(WindowEdge.leading),
                ?leading,
                if (leading != null) const SizedBox(width: LoafSpace.x1),
                Icon(LucideIcons.volume2, size: 18, color: tokens.textMuted),
                const SizedBox(width: LoafSpace.x2),
                Expanded(
                  child: Text(
                    channel.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: loafBody(15, 600).copyWith(color: tokens.textStrong),
                  ),
                ),
                Text(
                  count == 0
                      ? 'nobody here'
                      : count == 1
                      ? '1 person here'
                      : '$count people here',
                  style: loafBody(13, 500).copyWith(color: tokens.textMuted),
                ),
                const WindowControls(WindowEdge.trailing),
              ],
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(LoafSpace.x3),
            child: CallStage(
              tiles: lobbyTiles(calls, channel),
              tileBuilder: (info, {required small}) => CallTile(
                info: info,
                small: small,
                nameColor: tokens.nameColor(info.member.role),
                // Everyone but your own preview is dimmed: you are not
                // hearing them yet.
                dimmed: !info.you,
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            LoafSpace.x4,
            0,
            LoafSpace.x4,
            LoafSpace.x4,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CallButton(
                icon: calls.muted ? LucideIcons.micOff : LucideIcons.mic,
                tooltip: calls.muted ? 'Unmute' : 'Mute',
                alert: calls.muted,
                onTap: calls.micBlocked ? null : calls.toggleMute,
              ),
              const SizedBox(width: LoafSpace.x3),
              CallButton(
                icon: calls.camera ? LucideIcons.video : LucideIcons.videoOff,
                tooltip: calls.camera ? 'Turn camera off' : 'Turn camera on',
                active: calls.camera,
                onTap: calls.cameraBlocked ? null : calls.toggleCamera,
              ),
              const SizedBox(width: LoafSpace.x4),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: LoafButton(
                    label: 'join voice',
                    icon: LucideIcons.phone,
                    onTap: onJoin,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
