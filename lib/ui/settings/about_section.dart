/// About — which loaf chat this is, and a way to ask for the next one now
/// rather than waiting on the schedule.
///
/// The button is only there when something can update this copy: a phone's
/// store, or a build made by hand, gets a sentence instead of a button that
/// would do nothing.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../model/app_version.dart';
import '../model/updater.dart';
import '../theme/loaf_theme.dart';
import '../widgets/loaf_button.dart';

class AboutSection extends StatefulWidget {
  const AboutSection({
    super.key,
    this.updater = const NoUpdater(),
    this.version = appVersion,
  });

  final Updater updater;

  /// Empty for a build made by hand.
  final String version;

  @override
  State<AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends State<AboutSection> {
  /// A check asked for here is under way.
  var _checking = false;

  /// How the last check asked for here came out; null until one is.
  UpdateCheck? _last;

  @override
  void initState() {
    super.initState();
    widget.updater.addListener(_onUpdate);
  }

  @override
  void dispose() {
    widget.updater.removeListener(_onUpdate);
    super.dispose();
  }

  void _onUpdate() => setState(() {});

  Future<void> _check() async {
    setState(() => _checking = true);
    final result = await widget.updater.check();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _last = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final muted = loafBody(13, 400).copyWith(color: tokens.textMuted);

    return ListView(
      padding: const EdgeInsets.all(LoafSpace.x6),
      children: [
        Text(
          'loaf chat',
          style: loafDisplay(22, 600).copyWith(color: tokens.textStrong),
        ),
        const SizedBox(height: LoafSpace.x1),
        SelectableText(
          widget.version.isEmpty
              ? 'a build made by hand'
              : 'version ${widget.version}',
          style: loafBody(14, 400).copyWith(color: tokens.textBody),
        ),
        const SizedBox(height: LoafSpace.x6),
        ..._updates(muted),
      ],
    );
  }

  List<Widget> _updates(TextStyle muted) {
    final updater = widget.updater;
    if (!updater.canCheck) {
      return [
        Text(switch (defaultTargetPlatform) {
          TargetPlatform.iOS => 'TestFlight keeps loaf chat up to date.',
          _ when widget.version.isEmpty => "this copy doesn't update itself.",
          _ => 'your system keeps loaf chat up to date.',
        }, style: muted),
      ];
    }

    final state = updater.state;
    return switch (state) {
      UpdateReady(:final version) || UpdateApplying(:final version) => [
        Text(
          version == null
              ? 'a new loaf chat is ready.'
              : 'loaf chat $version is ready.',
          style: muted,
        ),
        const SizedBox(height: LoafSpace.x3),
        // Past the point of no return once applying: no button to press.
        _button(
          state is UpdateApplying ? 'restarting…' : 'restart to update',
          LucideIcons.rotateCw,
          state is UpdateApplying ? null : () => unawaited(updater.restart()),
        ),
      ],
      _ => [
        if (!_checking && state is UpdateIdle && _last != null) ...[
          Text(switch (_last!) {
            UpdateCheck.upToDate => "you're on the newest loaf chat.",
            _ => "couldn't check for updates. try again?",
          }, style: muted),
          const SizedBox(height: LoafSpace.x3),
        ],
        // A background check or download counts as checking: asking twice
        // would only wait on the same one.
        _checking || state is UpdatePreparing
            ? _button('checking…', LucideIcons.refreshCw, null)
            : _button(
                _last == UpdateCheck.failed ? 'try again' : 'check for updates',
                LucideIcons.refreshCw,
                _check,
              ),
      ],
    };
  }

  Widget _button(String label, IconData icon, VoidCallback? onTap) => Align(
    alignment: Alignment.centerLeft,
    child: LoafButton(
      label: label,
      icon: icon,
      emphasis: LoafButtonEmphasis.outlined,
      size: LoafButtonSize.small,
      onTap: onTap,
    ),
  );
}
