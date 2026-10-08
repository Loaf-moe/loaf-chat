/// The one call view: top bar, the stage of tiles, and the controls. Voice
/// channel pages and the DM call panel both wrap this; only their container
/// differs.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../members/role_colors.dart';
import '../mock/fixtures.dart';
import '../platform.dart';
import '../theme/loaf_theme.dart';
import '../widgets/action_menu.dart';
import '../widgets/loaf_button.dart';
import '../widgets/toast.dart';
import '../window/window_chrome.dart';
import 'call_controller.dart';
import 'call_controls.dart';
import 'call_stage.dart';
import 'call_tile.dart';

class CallView extends StatelessWidget {
  const CallView({
    super.key = const ValueKey('call-view'),
    required this.calls,
    this.compact = false,
    this.leading,
    this.trailing = const [],
  });

  final CallController calls;

  /// The DM panel's compact size: a slim top bar, one row of tiles.
  final bool compact;

  /// Before the title: the phone's navigation button, for instance.
  final Widget? leading;

  /// Container-specific top-bar buttons: expand, shrink, fullscreen.
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final session = calls.session!;
    final tokens = LoafTokens.of(context);
    final showShareStrip = isDesktop && calls.sharing != null;

    return ColoredBox(
      color: tokens.page,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CallTopBar(
            calls: calls,
            session: session,
            compact: compact,
            leading: leading,
            trailing: trailing,
          ),
          if (showShareStrip) _ShareStrip(calls: calls),
          Expanded(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                LoafSpace.x3,
                compact ? LoafSpace.x2 : LoafSpace.x3,
                LoafSpace.x3,
                0,
              ),
              child: session.over
                  ? _EndState(calls: calls, session: session)
                  : CallStage(
                      tiles: callTiles(calls, session),
                      spotlight: calls.spotlight,
                      compact: compact,
                      tileBuilder: (info, {required small}) =>
                          _tile(context, info, session, small: small),
                    ),
            ),
          ),
          if (!session.over)
            CallControls(calls: calls, dense: compact, onLeave: calls.leave),
        ],
      ),
    );
  }

  Widget _tile(
    BuildContext context,
    TileInfo info,
    CallSession session, {
    required bool small,
  }) {
    final tokens = LoafTokens.of(context);
    final pinned = calls.pinned == info.id;
    return CallTile(
      info: info,
      small: small,
      // Name colour is power level, and DMs have no power levels.
      nameColor: session.direct ? null : tokens.nameColor(info.member.role),
      dimmed:
          session.phase == CallPhase.connecting ||
          session.phase == CallPhase.reconnecting,
      pinned: pinned,
      onTogglePin: info.waiting
          ? null
          : () => calls.pin(pinned ? null : info.id),
      onMenu: info.waiting
          ? null
          : (position) => showTileActions(context, calls, info, position),
      onFlipCamera: info.you && info.camera && !isDesktop
          ? calls.flipCamera
          : null,
    );
  }
}

/// You, then everyone else, as the stage draws them.
List<TileInfo> callTiles(CallController calls, CallSession session) => [
  TileInfo(
    calls.me,
    you: true,
    muted: calls.muted,
    deafened: calls.deafened,
    camera: calls.camera,
    screen: calls.sharing != null,
  ),
  for (final p in session.participants) TileInfo.of(p),
];

enum _TileAction { pin, unpin }

/// Pin and volume — a sheet on a phone, a menu on a computer. No profile
/// entry: there is no profile view to open yet.
Future<void> showTileActions(
  BuildContext context,
  CallController calls,
  TileInfo info,
  Offset? position,
) async {
  final pinned = calls.pinned == info.id;
  final items = [
    ActionItem(
      value: pinned ? _TileAction.unpin : _TileAction.pin,
      icon: pinned ? LucideIcons.pinOff : LucideIcons.pin,
      label: pinned ? 'Unpin' : 'Pin',
    ),
  ];
  final _TileAction? action;
  if (position != null) {
    action = await showActionMenu(
      context,
      position: position,
      leading: [if (!info.you) _VolumeEntry(calls: calls, id: info.id)],
      items: items,
    );
  } else {
    action = await showActionSheet(
      context,
      header: info.you
          ? null
          : (context) => _VolumeSlider(calls: calls, id: info.id),
      items: items,
    );
  }
  if (!context.mounted) return;
  switch (action) {
    case _TileAction.pin:
      calls.pin(info.id);
    case _TileAction.unpin:
      calls.pin(null);
    case null:
  }
}

/// Per-person volume. Local only: it changes what you hear, not them.
class _VolumeSlider extends StatefulWidget {
  const _VolumeSlider({required this.calls, required this.id});

  final CallController calls;
  final String id;

  @override
  State<_VolumeSlider> createState() => _VolumeSliderState();
}

class _VolumeSliderState extends State<_VolumeSlider> {
  late double _value = widget.calls.volumeOf(widget.id);

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Row(
      children: [
        Icon(LucideIcons.volume1, size: 18, color: tokens.textMuted),
        Expanded(
          child: Slider(
            value: _value,
            max: 2,
            onChanged: (v) {
              setState(() => _value = v);
              widget.calls.setVolume(widget.id, v);
            },
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            '${(_value * 100).round()}%',
            textAlign: TextAlign.end,
            style: loafBody(13, 500).copyWith(color: tokens.textBody),
          ),
        ),
      ],
    );
  }
}

class _VolumeEntry extends PopupMenuEntry<_TileAction> {
  const _VolumeEntry({required this.calls, required this.id});

  final CallController calls;
  final String id;

  @override
  double get height => 48;

  @override
  bool represents(_TileAction? value) => false;

  @override
  State<_VolumeEntry> createState() => _VolumeEntryState();
}

class _VolumeEntryState extends State<_VolumeEntry> {
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 240,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x3),
      child: _VolumeSlider(calls: widget.calls, id: widget.id),
    ),
  );
}

class CallTopBar extends StatelessWidget {
  const CallTopBar({
    super.key,
    required this.calls,
    required this.session,
    this.compact = false,
    this.leading,
    this.trailing = const [],
  });

  final CallController calls;
  final CallSession session;
  final bool compact;
  final Widget? leading;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final status = callStatus(session.phase);
    final present = session.participants.where((p) => p.present).length + 1;
    return WindowDragArea(
      child: Container(
        height: compact ? 44 : 56,
        padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x3),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: tokens.border)),
        ),
        child: Row(
          children: [
            const WindowControls(WindowEdge.leading),
            ?leading,
            if (leading != null) const SizedBox(width: LoafSpace.x1),
            Icon(
              session.direct ? LucideIcons.phone : LucideIcons.volume2,
              size: 18,
              color: tokens.textMuted,
            ),
            const SizedBox(width: LoafSpace.x2),
            // The title and its marks share one flexible run, so the buttons
            // after it stay pinned to the right edge whatever its length.
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      session.target.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: loafBody(
                        15,
                        600,
                      ).copyWith(color: tokens.textStrong),
                    ),
                  ),
                  if (status != null) ...[
                    const SizedBox(width: LoafSpace.x2),
                    if (session.phase == CallPhase.connecting) ...[
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: tokens.textMuted,
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    Text(
                      status,
                      style: loafBody(13, 500).copyWith(
                        color: session.phase == CallPhase.reconnecting
                            ? tokens.idle
                            : tokens.textMuted,
                      ),
                    ),
                  ],
                  if (calls.encrypted) ...[
                    const SizedBox(width: LoafSpace.x2),
                    _EncryptedMark(),
                  ],
                ],
              ),
            ),
            if (!isDesktop && !compact) ...[
              Icon(LucideIcons.users, size: 16, color: tokens.textMuted),
              const SizedBox(width: LoafSpace.x1),
              Text(
                '$present',
                style: loafBody(13, 500).copyWith(color: tokens.textMuted),
              ),
              const SizedBox(width: LoafSpace.x2),
            ],
            ...trailing,
            const WindowControls(WindowEdge.trailing),
          ],
        ),
      ),
    );
  }
}

/// The top bar's status words, or null when the call is simply live.
String? callStatus(CallPhase phase) => switch (phase) {
  CallPhase.connecting => 'connecting…',
  CallPhase.reconnecting => 'reconnecting…',
  CallPhase.ringing => 'ringing…',
  _ => null,
};

class _EncryptedMark extends StatelessWidget {
  static const _explanation = 'calls are end-to-end encrypted';

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final icon = Icon(LucideIcons.lock, size: 14, color: tokens.textMuted);
    if (isDesktop) return Tooltip(message: _explanation, child: icon);
    return GestureDetector(
      onTap: () => showToast(context, _explanation),
      child: Padding(padding: const EdgeInsets.all(4), child: icon),
    );
  }
}

class TopBarButton extends StatelessWidget {
  const TopBarButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      iconSize: 18,
      color: tokens.textMuted,
      icon: Icon(icon),
    );
  }
}

/// Broadcasting your screen must never go unnoticed, so this is one of the
/// few places the accent fills a whole strip.
class _ShareStrip extends StatelessWidget {
  const _ShareStrip({required this.calls});

  final CallController calls;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final style = loafBody(13, 600).copyWith(color: tokens.textOnAccent);
    return Container(
      color: tokens.accent,
      padding: const EdgeInsets.symmetric(
        horizontal: LoafSpace.x4,
        vertical: 6,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(LucideIcons.screenShare, size: 14, color: tokens.textOnAccent),
          const SizedBox(width: LoafSpace.x2),
          Flexible(
            child: Text(
              "you're sharing · ${calls.sharing!.toLowerCase()}",
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          const SizedBox(width: LoafSpace.x3),
          GestureDetector(
            onTap: calls.stopScreenShare,
            child: Text(
              'stop',
              style: style.copyWith(decoration: TextDecoration.underline),
            ),
          ),
        ],
      ),
    );
  }
}

/// A call that has ended without you hanging up: failed, declined, or
/// nobody answered.
class _EndState extends StatelessWidget {
  const _EndState({required this.calls, required this.session});

  final CallController calls;
  final CallSession session;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final (
      IconData icon,
      String message,
      String action,
      VoidCallback onAct,
    ) = switch (session.phase) {
      CallPhase.declined => (
        LucideIcons.phoneOff,
        '${session.target.members.first.name} declined',
        'call again',
        calls.callAgain,
      ),
      CallPhase.unanswered => (
        LucideIcons.phoneMissed,
        session.target.members.length > 1 ? 'no one answered' : 'no answer',
        'call again',
        calls.callAgain,
      ),
      _ => (LucideIcons.wifiOff, "couldn't connect", 'retry', calls.retry),
    };
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 28, color: tokens.textMuted),
            const SizedBox(height: LoafSpace.x2),
            Text(
              message,
              style: loafBody(15, 600).copyWith(color: tokens.textStrong),
            ),
            const SizedBox(height: LoafSpace.x3),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                LoafButton(
                  label: action,
                  size: LoafButtonSize.small,
                  onTap: onAct,
                ),
                const SizedBox(width: LoafSpace.x2),
                LoafButton(
                  label: 'close',
                  size: LoafButtonSize.small,
                  emphasis: LoafButtonEmphasis.outlined,
                  onTap: calls.close,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The channel's occupants plus your preview, for a voice channel you have
/// not connected to — drawn dimmed, since you are not hearing them yet.
List<TileInfo> lobbyTiles(CallController calls, Channel channel) => [
  TileInfo(calls.me, you: true, muted: calls.muted, camera: calls.camera),
  // How they are set up is visible without joining, like who is there.
  for (final m in channel.occupants)
    if (calls.flags[m.id] case final flags?)
      TileInfo.of(flags)
    else
      TileInfo(m),
];
