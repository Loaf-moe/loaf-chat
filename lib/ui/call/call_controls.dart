/// The call's control bar. Mobile: mic, camera, audio route, deafen, leave.
/// Desktop: mic and camera with device menus, share screen, deafen, leave,
/// each naming its keyboard shortcut.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../platform.dart';
import '../theme/loaf_theme.dart';
import '../widgets/action_menu.dart';
import 'call_controller.dart';

/// The shortcut as the platform writes it: ⌘⇧M on a Mac, Ctrl+Shift+M
/// elsewhere.
String shortcutLabel(String key) =>
    defaultTargetPlatform == TargetPlatform.macOS
    ? '⌘⇧$key'
    : 'Ctrl+Shift+$key';

const mockMics = ['MacBook Pro Microphone', 'AirPods Pro', 'Blue Yeti'];
const mockCameras = ['FaceTime HD Camera', 'Continuity Camera'];
const mockShareSources = [
  'Entire screen',
  'Second display',
  'Window · Firefox',
  'Window · Terminal',
];

class CallControls extends StatelessWidget {
  const CallControls({
    super.key,
    required this.calls,
    required this.onLeave,
    this.dense = false,
  });

  final CallController calls;
  final VoidCallback onLeave;

  /// The DM panel's compact size: smaller buttons, same set.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final buttons = isDesktop ? _desktop(context) : _mobile(context);
    return Padding(
      padding: EdgeInsets.symmetric(
        vertical: dense ? LoafSpace.x2 : LoafSpace.x3,
      ),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: dense ? LoafSpace.x2 : LoafSpace.x3,
        runSpacing: LoafSpace.x2,
        children: buttons,
      ),
    );
  }

  double get _size => dense ? 40 : 52;

  List<Widget> _mobile(BuildContext context) => [
    _micButton(context),
    _cameraButton(context),
    CallButton(
      icon: switch (calls.route) {
        AudioRoute.speaker => LucideIcons.volume2,
        AudioRoute.phone => LucideIcons.smartphone,
        AudioRoute.bluetooth => LucideIcons.bluetooth,
      },
      tooltip: 'Audio output',
      size: _size,
      onTap: () async {
        final route = await showActionSheet<AudioRoute>(
          context,
          items: [
            for (final r in AudioRoute.values)
              ActionItem(
                value: r,
                icon: r == calls.route ? LucideIcons.check : LucideIcons.dot,
                label: r.label,
              ),
          ],
        );
        if (route != null) calls.setRoute(route);
      },
    ),
    _deafenButton(),
    _leaveButton(),
  ];

  List<Widget> _desktop(BuildContext context) => [
    _WithDevices(
      button: _micButton(context),
      tooltip: 'Microphone',
      devices: mockMics,
      current: calls.micDevice,
      onPick: calls.setMicDevice,
    ),
    _WithDevices(
      button: _cameraButton(context),
      tooltip: 'Camera',
      devices: mockCameras,
      current: calls.cameraDevice,
      onPick: calls.setCameraDevice,
    ),
    Builder(
      builder: (context) => CallButton(
        icon: LucideIcons.screenShare,
        tooltip: calls.sharing == null ? 'Share screen' : 'Stop sharing',
        size: _size,
        active: calls.sharing != null,
        onTap: () async {
          if (calls.sharing != null) return calls.stopScreenShare();
          final box = context.findRenderObject()! as RenderBox;
          final source = await showActionMenu<String>(
            context,
            position: box.localToGlobal(Offset(0, box.size.height)),
            items: [
              for (final s in mockShareSources)
                ActionItem(
                  value: s,
                  icon: s.startsWith('Window')
                      ? LucideIcons.appWindow
                      : LucideIcons.monitor,
                  label: s,
                ),
            ],
          );
          if (source != null) calls.startScreenShare(source);
        },
      ),
    ),
    _deafenButton(),
    _leaveButton(),
  ];

  String _withShortcut(String label, String key) =>
      isDesktop ? '$label (${shortcutLabel(key)})' : label;

  Widget _micButton(BuildContext context) {
    if (calls.micBlocked) {
      return _BlockedButton(
        icon: LucideIcons.micOff,
        what: 'Microphone',
        size: _size,
      );
    }
    return CallButton(
      icon: calls.muted ? LucideIcons.micOff : LucideIcons.mic,
      tooltip: _withShortcut(calls.muted ? 'Unmute' : 'Mute', 'M'),
      size: _size,
      alert: calls.muted,
      onTap: calls.toggleMute,
    );
  }

  Widget _cameraButton(BuildContext context) {
    if (calls.cameraBlocked) {
      return _BlockedButton(
        icon: LucideIcons.videoOff,
        what: 'Camera',
        size: _size,
      );
    }
    return CallButton(
      icon: calls.camera ? LucideIcons.video : LucideIcons.videoOff,
      tooltip: _withShortcut(
        calls.camera ? 'Turn camera off' : 'Turn camera on',
        'V',
      ),
      size: _size,
      active: calls.camera,
      onTap: calls.toggleCamera,
    );
  }

  Widget _deafenButton() => CallButton(
    icon: calls.deafened ? LucideIcons.headphoneOff : LucideIcons.headphones,
    tooltip: _withShortcut(calls.deafened ? 'Undeafen' : 'Deafen', 'D'),
    size: _size,
    alert: calls.deafened,
    onTap: calls.toggleDeafen,
  );

  Widget _leaveButton() => CallButton(
    icon: LucideIcons.phoneOff,
    tooltip: 'Leave call',
    size: _size,
    leave: true,
    onTap: onLeave,
  );
}

/// One round control. [active] is a positive "on" (camera, sharing);
/// [alert] is a state you should notice (muted, deafened), drawn in the
/// accent; [leave] is the red hang-up.
class CallButton extends StatefulWidget {
  const CallButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.size = 52,
    this.active = false,
    this.alert = false,
    this.leave = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final double size;
  final bool active;
  final bool alert;
  final bool leave;

  @override
  State<CallButton> createState() => _CallButtonState();
}

class _CallButtonState extends State<CallButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final enabled = widget.onTap != null;
    final Color background;
    final Color foreground;
    if (widget.leave || widget.alert) {
      background = tokens.accent;
      foreground = tokens.textOnAccent;
    } else if (widget.active) {
      background = tokens.textStrong;
      foreground = tokens.page;
    } else {
      background = tokens.card;
      foreground = enabled ? tokens.textStrong : tokens.textMuted;
    }
    return Tooltip(
      message: widget.tooltip,
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? LoafMotion.iconPressScale : 1,
          duration: LoafMotion.fast,
          curve: LoafMotion.ease,
          child: Container(
            width: widget.leave ? widget.size * 1.4 : widget.size,
            height: widget.size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(LoafRadius.full),
              border: widget.leave || widget.alert || widget.active
                  ? null
                  : Border.all(color: tokens.border),
            ),
            child: Icon(
              widget.icon,
              size: widget.size * 0.4,
              color: foreground,
            ),
          ),
        ),
      ),
    );
  }
}

/// A control the OS has denied. Disabled with a slash; says why on hover,
/// or on a phone, on tap.
class _BlockedButton extends StatelessWidget {
  const _BlockedButton({
    required this.icon,
    required this.what,
    required this.size,
  });

  final IconData icon;
  final String what;
  final double size;

  @override
  Widget build(BuildContext context) {
    final message = '$what blocked in system settings';
    final button = CallButton(
      icon: icon,
      tooltip: message,
      size: size,
      onTap: isDesktop
          ? null
          : () => showActionSheet<void>(
              context,
              header: (context) => _BlockedExplainer(what: what),
              items: const [],
            ),
    );
    return Opacity(opacity: 0.6, child: button);
  }
}

class _BlockedExplainer extends StatelessWidget {
  const _BlockedExplainer({required this.what});

  final String what;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${what.toLowerCase()} is blocked',
          style: loafBody(16, 600).copyWith(color: tokens.textStrong),
        ),
        const SizedBox(height: LoafSpace.x1),
        Text(
          'loaf needs permission in settings › privacy to use your '
          '${what.toLowerCase()}.',
          style: loafBody(14, 400).copyWith(color: tokens.textBody),
        ),
      ],
    );
  }
}

/// A desktop control with a small ⌄ beside it that picks the device.
class _WithDevices extends StatelessWidget {
  const _WithDevices({
    required this.button,
    required this.tooltip,
    required this.devices,
    required this.current,
    required this.onPick,
  });

  final Widget button;
  final String tooltip;
  final List<String> devices;
  final String current;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        button,
        Builder(
          builder: (context) => Tooltip(
            message: '$tooltip settings',
            child: InkWell(
              borderRadius: BorderRadius.circular(LoafRadius.full),
              onTap: () async {
                final box = context.findRenderObject()! as RenderBox;
                final picked = await showActionMenu<String>(
                  context,
                  position: box.localToGlobal(Offset(0, box.size.height)),
                  items: [
                    for (final d in devices)
                      ActionItem(
                        value: d,
                        icon: d == current
                            ? LucideIcons.check
                            : LucideIcons.dot,
                        label: d,
                      ),
                  ],
                );
                if (picked != null) onPick(picked);
              },
              child: Padding(
                padding: const EdgeInsets.all(LoafSpace.x1),
                child: Icon(
                  LucideIcons.chevronDown,
                  size: 16,
                  color: tokens.textMuted,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
