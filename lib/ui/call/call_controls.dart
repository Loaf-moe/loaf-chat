/// The call's control bar. Mobile: mic, camera, audio route, deafen, leave.
/// Desktop: mic, camera and deafen with device menus, share screen, leave,
/// each naming its keyboard shortcut.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../platform.dart';
import '../settings/voice_settings.dart';
import '../theme/loaf_theme.dart';
import '../widgets/action_menu.dart';
import 'calls.dart';

/// The shortcut as the platform writes it: ⌘⇧M on a Mac, Ctrl+Shift+M
/// elsewhere.
String shortcutLabel(String key) =>
    defaultTargetPlatform == TargetPlatform.macOS
    ? '⌘⇧$key'
    : 'Ctrl+Shift+$key';

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

  final Calls calls;
  final VoidCallback onLeave;

  /// The DM panel's compact size: smaller buttons, same set.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final buttons = isDesktop
        ? _desktop(context, VoiceScope.maybeOf(context))
        : _mobile(context);
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

  bool _has(CallFeature feature) => calls.features.contains(feature);

  List<Widget> _mobile(BuildContext context) => [
    _micButton(context),
    if (_has(CallFeature.camera)) _cameraButton(context),
    if (_has(CallFeature.audioRoute))
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

  /// [voice] is which microphone and speaker calls use; without it there
  /// is nothing to choose them with.
  List<Widget> _desktop(BuildContext context, VoiceController? voice) => [
    if (voice != null)
      _WithMenu(
        button: _micButton(context),
        tooltip: 'Microphone',
        onOpen: (context, position) => _chooseDevice(
          context,
          position,
          voice: voice,
          devices: () => voice.microphones,
          chosen: () => voice.microphone,
          choose: voice.chooseMicrophone,
        ),
      )
    else
      _micButton(context),
    if (_has(CallFeature.camera))
      if (_has(CallFeature.cameraDevices))
        _WithMenu(
          button: _cameraButton(context),
          tooltip: 'Camera',
          onOpen: (context, position) async {
            final picked = await showActionMenu<String>(
              context,
              position: position,
              items: [
                for (final camera in mockCameras)
                  ActionItem(
                    value: camera,
                    icon: camera == calls.cameraDevice
                        ? LucideIcons.check
                        : LucideIcons.dot,
                    label: camera,
                  ),
              ],
            );
            if (picked != null) calls.setCameraDevice(picked);
          },
        )
      else
        _cameraButton(context),
    if (_has(CallFeature.screenShare))
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
    if (voice != null)
      _WithMenu(
        button: _deafenButton(),
        tooltip: 'Speaker',
        onOpen: (context, position) => _chooseDevice(
          context,
          position,
          voice: voice,
          devices: () => voice.speakers,
          chosen: () => voice.speaker,
          choose: voice.chooseSpeaker,
        ),
      )
    else
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
        // On a computer the microphone chosen did not open; the ⌄ beside
        // it chooses another.
        message: isDesktop ? "Couldn't open your microphone" : null,
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

/// A control that cannot be used. Disabled with a slash; says why on
/// hover, or on a phone, on tap.
class _BlockedButton extends StatelessWidget {
  const _BlockedButton({
    required this.icon,
    required this.what,
    required this.size,
    this.message,
  });

  final IconData icon;
  final String what;
  final double size;

  /// What hovering says. Null: that the system has denied [what].
  final String? message;

  @override
  Widget build(BuildContext context) {
    final message = this.message ?? '$what blocked in system settings';
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

/// A desktop control with a small ⌄ beside it that opens a menu under
/// itself.
class _WithMenu extends StatefulWidget {
  const _WithMenu({
    required this.button,
    required this.tooltip,
    required this.onOpen,
  });

  final Widget button;
  final String tooltip;

  /// Shows the menu at [position], from the ⌄'s own [context]. Done when
  /// the menu has closed.
  final Future<void> Function(BuildContext context, Offset position) onOpen;

  @override
  State<_WithMenu> createState() => _WithMenuState();
}

class _WithMenuState extends State<_WithMenu> {
  /// From a tap until its menu has closed. A menu may take a moment to
  /// show, and a second tap meanwhile would open a second.
  var _open = false;

  Future<void> _tap(BuildContext context) async {
    if (_open) return;
    _open = true;
    final box = context.findRenderObject()! as RenderBox;
    try {
      await widget.onOpen(
        context,
        box.localToGlobal(Offset(0, box.size.height)),
      );
    } finally {
      _open = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        widget.button,
        Builder(
          builder: (context) => Tooltip(
            message: '${widget.tooltip} settings',
            child: InkWell(
              borderRadius: BorderRadius.circular(LoafRadius.full),
              onTap: () => unawaited(_tap(context)),
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

/// Asks the machine what it has, then offers [devices] to [choose] from.
Future<void> _chooseDevice(
  BuildContext context,
  Offset position, {
  required VoiceController voice,
  required List<AudioDevice> Function() devices,
  required AudioDevice? Function() chosen,
  required ValueChanged<AudioDevice?> choose,
}) async {
  await voice.refresh();
  if (!context.mounted) return;
  final picked = await showActionMenu<DeviceChoice>(
    context,
    position: position,
    items: [
      for (final choice in deviceChoices(devices(), chosen()))
        ActionItem(
          value: choice,
          icon: choice.chosen ? LucideIcons.check : LucideIcons.dot,
          label: choice.label,
        ),
    ],
  );
  if (picked != null) choose(picked.device);
}
