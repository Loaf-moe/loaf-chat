/// The recovery key on screen: shown in fours for reading and copying by
/// eye, and typed or pasted back in to unlock.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../platform.dart';
import '../theme/loaf_theme.dart';
import '../widgets/loaf_field.dart';

/// [key] regrouped into fours, whatever spacing it arrived with.
String groupKey(String key) {
  final squashed = key.replaceAll(RegExp(r'\s'), '');
  final groups = [
    for (var i = 0; i < squashed.length; i += 4)
      squashed.substring(i, (i + 4).clamp(0, squashed.length)),
  ];
  return groups.join(' ');
}

class RecoveryKeyDisplay extends StatelessWidget {
  const RecoveryKeyDisplay({super.key, required this.recoveryKey});

  final String recoveryKey;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final text = groupKey(recoveryKey);
    final style = loafMono(
      16,
      weight: FontWeight.w500,
    ).copyWith(color: tokens.textStrong, height: 1.6);
    return Container(
      padding: const EdgeInsets.all(LoafSpace.x4),
      decoration: BoxDecoration(
        color: tokens.sunken,
        borderRadius: BorderRadius.circular(LoafRadius.lg),
        border: Border.all(color: tokens.border),
      ),
      // A computer never loses text selection; the spaces between groups are
      // where it wraps.
      child: isDesktop
          ? SelectableText(text, textAlign: TextAlign.center, style: style)
          : Text(text, textAlign: TextAlign.center, style: style),
    );
  }
}

class RecoveryKeyField extends StatefulWidget {
  const RecoveryKeyField({
    super.key,
    required this.controller,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final VoidCallback onSubmit;

  @override
  State<RecoveryKeyField> createState() => _RecoveryKeyFieldState();
}

class _RecoveryKeyFieldState extends State<RecoveryKeyField> {
  var _hidden = true;

  /// A phone's clipboard is a long-press away and fiddly in a masked field;
  /// a computer pastes with the usual shortcut.
  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || !mounted) return;
    widget.controller.text = text;
  }

  @override
  Widget build(BuildContext context) => LoafField(
    controller: widget.controller,
    hint: 'recovery key or passphrase',
    icon: LucideIcons.keyRound,
    obscure: _hidden,
    exact: true,
    autofocus: true,
    textInputAction: TextInputAction.done,
    onSubmit: widget.onSubmit,
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!isDesktop)
          _IconTap(
            icon: LucideIcons.clipboardPaste,
            tooltip: 'paste',
            onTap: _paste,
          ),
        _IconTap(
          icon: _hidden ? LucideIcons.eye : LucideIcons.eyeOff,
          tooltip: _hidden ? 'show' : 'hide',
          onTap: () => setState(() => _hidden = !_hidden),
        ),
      ],
    ),
  );
}

class _IconTap extends StatelessWidget {
  const _IconTap({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(LoafSpace.x1),
            child: Icon(icon, size: 17, color: tokens.textMuted),
          ),
        ),
      ),
    );
  }
}
