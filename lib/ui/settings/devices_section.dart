/// Devices — every session signed in as you: what it is called, whether
/// you have verified it, when it was last around. Other sessions can be
/// renamed and signed out; this one signs out with the button at the foot
/// of settings.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../mock/accounts.dart';
import '../platform.dart';
import '../theme/loaf_theme.dart';
import '../verify/reset_identity.dart';
import '../verify/verifier.dart';
import '../verify/verify_steps.dart';
import '../widgets/adaptive_panel.dart';
import '../widgets/loaf_button.dart';
import '../widgets/loaf_field.dart';
import '../widgets/toast.dart';
import 'devices.dart';

class DevicesSection extends StatefulWidget {
  const DevicesSection({super.key, required this.devices});

  final Devices devices;

  @override
  State<DevicesSection> createState() => _DevicesSectionState();
}

class _DevicesSectionState extends State<DevicesSection> {
  var _failed = false;

  @override
  void initState() {
    super.initState();
    widget.devices.addListener(_onChange);
    _load();
  }

  @override
  void didUpdateWidget(DevicesSection old) {
    super.didUpdateWidget(old);
    if (old.devices == widget.devices) return;
    old.devices.removeListener(_onChange);
    widget.devices.addListener(_onChange);
    _load();
  }

  @override
  void dispose() {
    widget.devices.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() => setState(() {});

  Future<void> _load() async {
    final devices = widget.devices;
    setState(() => _failed = false);
    try {
      await devices.load();
    } on Object {
      // The seam throws; showing it is ours.
      if (mounted && devices == widget.devices) setState(() => _failed = true);
    }
  }

  /// Whether it went through; a failure is said here, and the caller keeps
  /// its field live so trying again is the same tap.
  Future<bool> _rename(String id, String name) async {
    try {
      await widget.devices.rename(id, name);
      return true;
    } on Object {
      if (mounted) {
        showToast(context, "couldn't rename that device. try again?");
      }
      return false;
    }
  }

  Future<void> _renameInSheet(LoafDevice device) => showAdaptivePanel<void>(
    context,
    child: _RenameSheet(
      initial: device.name,
      onSave: (name) => _rename(device.id, name),
    ),
    // Drag-to-close pops straight past the sheet's PopScope, and a save
    // under way must not be put away.
    enableDrag: false,
  );

  Future<void> _signOut(LoafDevice device) => showAdaptivePanel<bool>(
    context,
    child: _SignOutFlow(device: device, devices: widget.devices),
    // The sheet's drag-to-close pops straight past the panel's PopScope,
    // and a sign-out under way must not be put away.
    enableDrag: false,
  );

  /// This device first, then whoever was around most recently; a device the
  /// server has never seen goes last.
  List<LoafDevice> get _sorted {
    final list = [...?widget.devices.list];
    list.sort((a, b) {
      if (a.current != b.current) return a.current ? -1 : 1;
      final x = a.lastSeen;
      final y = b.lastSeen;
      if (x == null || y == null) {
        return x == y
            ? 0
            : x == null
            ? 1
            : -1;
      }
      return y.compareTo(x);
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final list = widget.devices.list;
    final Widget body;
    if (list == null && _failed) {
      body = Column(
        children: [
          Text(
            "couldn't load your devices",
            style: loafBody(14, 400).copyWith(color: tokens.textMuted),
          ),
          const SizedBox(height: LoafSpace.x3),
          LoafButton(
            label: 'try again',
            emphasis: LoafButtonEmphasis.quiet,
            size: LoafButtonSize.small,
            onTap: _load,
          ),
        ],
      );
    } else if (list == null) {
      body = const WorkingLine('loading your devices…');
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final device in _sorted)
            Padding(
              padding: const EdgeInsets.only(bottom: LoafSpace.x3),
              child: _DeviceRow(
                key: ValueKey(device.id),
                device: device,
                onRename: (name) => _rename(device.id, name),
                onRenameInSheet: () => _renameInSheet(device),
                onSignOut: () => _signOut(device),
              ),
            ),
        ],
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(LoafSpace.x6),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: body,
        ),
      ),
    );
  }
}

/// "3 days ago", coarsely: this is for telling sessions apart, not a log.
String _ago(DateTime time) {
  final d = DateTime.now().difference(time);
  String n(int count, String unit) =>
      '$count $unit${count == 1 ? '' : 's'} ago';
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return n(d.inMinutes, 'minute');
  if (d.inDays < 1) return n(d.inHours, 'hour');
  return n(d.inDays, 'day');
}

class _DeviceRow extends StatefulWidget {
  const _DeviceRow({
    super.key,
    required this.device,
    required this.onRename,
    required this.onRenameInSheet,
    required this.onSignOut,
  });

  final LoafDevice device;

  /// Whether it saved.
  final Future<bool> Function(String name) onRename;
  final VoidCallback onRenameInSheet;
  final VoidCallback onSignOut;

  @override
  State<_DeviceRow> createState() => _DeviceRowState();
}

class _DeviceRowState extends State<_DeviceRow> {
  final _name = TextEditingController();
  final _focus = FocusNode();
  var _editing = false;
  var _saving = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      // Clicking away is a change of mind, unless a save is on its way.
      if (!_focus.hasFocus && _editing && !_saving) _revert();
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _edit() {
    _name.text = widget.device.name;
    _name.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _name.text.length,
    );
    setState(() => _editing = true);
  }

  void _revert() {
    if (!mounted) return;
    setState(() => _editing = false);
  }

  Future<void> _save() async {
    if (_saving) return;
    final name = _name.text.trim();
    if (name.isEmpty || name == widget.device.name) return _revert();
    setState(() => _saving = true);
    final ok = await widget.onRename(name);
    if (!mounted) return;
    // Refused: the field stays as it was typed, and Enter tries again.
    setState(() {
      _saving = false;
      if (ok) _editing = false;
    });
  }

  String get _meta {
    final d = widget.device;
    final seen = d.lastSeen;
    return [
      if (d.current)
        'this device'
      else
        'last seen ${seen == null ? 'unknown' : _ago(seen)}',
      ?d.lastIp,
    ].join(' · ');
  }

  Widget _title(LoafTokens tokens) {
    final style = loafBody(15, 600).copyWith(color: tokens.textStrong);
    final name = widget.device.name;
    if (!isDesktop) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onRenameInSheet,
        child: Text(name, style: style),
      );
    }
    if (!_editing) {
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        // The name is what gets copied, so it stays selectable; a plain
        // click still opens the rename.
        child: SelectableText(name, style: style, onTap: _edit),
      );
    }
    return Focus(
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape &&
            !_saving) {
          _revert();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: TextField(
        controller: _name,
        focusNode: _focus,
        autofocus: true,
        readOnly: _saving,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _save(),
        style: style,
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(vertical: LoafSpace.x2),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final d = widget.device;
    return Container(
      padding: const EdgeInsets.all(LoafSpace.x4),
      decoration: BoxDecoration(
        color: tokens.card,
        borderRadius: BorderRadius.circular(LoafRadius.lg),
        border: Border.all(color: tokens.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(child: _title(tokens)),
                    const SizedBox(width: LoafSpace.x2),
                    _Badge(verified: d.verified),
                  ],
                ),
                const SizedBox(height: LoafSpace.x1),
                Text(
                  _meta,
                  style: loafBody(13, 400).copyWith(color: tokens.textMuted),
                ),
                if (!d.current && !d.verified) ...[
                  const SizedBox(height: LoafSpace.x1),
                  Text(
                    'verify it from that device',
                    style: loafBody(13, 400).copyWith(color: tokens.textMuted),
                  ),
                ],
              ],
            ),
          ),
          if (!d.current) ...[
            const SizedBox(width: LoafSpace.x3),
            LoafButton(
              label: 'sign out',
              emphasis: LoafButtonEmphasis.quiet,
              size: LoafButtonSize.small,
              onTap: widget.onSignOut,
            ),
          ],
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.verified});

  final bool verified;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: verified ? tokens.accentSoft : tokens.sunken,
        borderRadius: BorderRadius.circular(LoafRadius.full),
      ),
      child: Text(
        verified ? 'verified' : 'unverified',
        style: loafBody(
          11,
          600,
        ).copyWith(color: verified ? tokens.accent : tokens.textMuted),
      ),
    );
  }
}

/// Renaming on a phone: a field and a save, in a sheet.
class _RenameSheet extends StatefulWidget {
  const _RenameSheet({required this.initial, required this.onSave});

  final String initial;

  /// Whether it saved; the sheet closes only when it did.
  final Future<bool> Function(String name) onSave;

  @override
  State<_RenameSheet> createState() => _RenameSheetState();
}

class _RenameSheetState extends State<_RenameSheet> {
  late final _name = TextEditingController(text: widget.initial);
  var _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (_saving || name.isEmpty) return;
    if (name == widget.initial) return Navigator.of(context).pop();
    setState(() => _saving = true);
    final ok = await widget.onSave(name);
    if (!mounted) return;
    if (ok) return Navigator.of(context).pop();
    setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    // A save can't be called back.
    canPop: !_saving,
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(LoafSpace.x5),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LoafField(
            controller: _name,
            hint: 'device name',
            icon: LucideIcons.monitorSmartphone,
            autofocus: true,
            exact: true,
            textInputAction: TextInputAction.done,
            onSubmit: _save,
          ),
          const SizedBox(height: LoafSpace.x4),
          ListenableBuilder(
            listenable: _name,
            builder: (context, _) => LoafButton(
              label: _saving ? 'saving…' : 'save',
              onTap: _saving || _name.text.trim().isEmpty ? null : _save,
            ),
          ),
        ],
      ),
    ),
  );
}

enum _SignOutStep { confirm, auth, signingOut }

/// Signing one device out: say who, prove it's you, and then it is done.
/// The request goes up the moment "sign out" is pressed (a server that
/// remembers you recently asks nothing), so from there nothing offers to
/// take it back, until the server asks who you are and waits for the answer.
class _SignOutFlow extends StatefulWidget {
  const _SignOutFlow({required this.device, required this.devices});

  final LoafDevice device;
  final Devices devices;

  @override
  State<_SignOutFlow> createState() => _SignOutFlowState();
}

class _SignOutFlowState extends State<_SignOutFlow> {
  final _password = TextEditingController();
  var _step = _SignOutStep.confirm;
  AuthChallenge? _challenge;
  var _checking = false;
  var _rejected = false;
  var _inBrowser = false;
  var _finished = false;

  /// A step that can't be put away: the answer is on its way.
  bool get _locked => _step == _SignOutStep.signingOut || _checking;

  String get _name => widget.device.name;

  @override
  void dispose() {
    // Put away while the server waits on an answer: none is coming.
    if (!_finished) _challenge?.cancel();
    _password.dispose();
    super.dispose();
  }

  void _onAuth(AuthChallenge challenge) {
    if (!mounted) return challenge.cancel();
    if (challenge.retry) _password.clear();
    setState(() {
      _challenge = challenge;
      _step = _SignOutStep.auth;
      _checking = false;
      _inBrowser = false;
      _rejected = challenge.retry;
    });
  }

  Future<void> _signOut() async {
    setState(() => _step = _SignOutStep.signingOut);
    try {
      final ok = await widget.devices.signOut(
        widget.device.id,
        onAuth: _onAuth,
      );
      if (!mounted) return;
      _finished = true;
      // Cancelled is closed quietly, as done is.
      Navigator.of(context).pop(ok);
    } on Object {
      if (!mounted) return;
      _challenge = null;
      setState(() {
        _step = _SignOutStep.confirm;
        _checking = false;
        _inBrowser = false;
        _rejected = false;
      });
      showToast(context, "couldn't sign that device out. try again?");
    }
  }

  void _byPassword() {
    final c = _challenge;
    if (_step != _SignOutStep.auth || _checking || c == null) return;
    if (_password.text.isEmpty) return;
    setState(() {
      _checking = true;
      _rejected = false;
    });
    c.password(_password.text);
  }

  void _bySso() {
    final c = _challenge;
    if (_step != _SignOutStep.auth || _inBrowser || _checking || c == null) {
      return;
    }
    c.openBrowser();
    setState(() {
      _inBrowser = true;
      _rejected = false;
    });
  }

  void _reopen() {
    if (_inBrowser && !_checking) _challenge?.openBrowser();
  }

  void _browserFinished() {
    if (!_inBrowser || _checking) return;
    setState(() => _checking = true);
    _challenge?.browserFinished();
  }

  /// Leaves the browser step, and the sign-out with it: nothing changed.
  void _cancelBrowser() {
    if (!_inBrowser || _checking) return;
    _challenge?.cancel();
  }

  Widget _body(LoafTokens tokens) => switch (_step) {
    _SignOutStep.confirm => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'sign out $_name?',
          style: loafBody(17, 600).copyWith(color: tokens.textStrong),
        ),
        const SizedBox(height: LoafSpace.x2),
        const StepNote("it'll need to sign in again to read anything."),
        const SizedBox(height: LoafSpace.x5),
        LoafButton(label: 'sign out', onTap: _signOut),
        const SizedBox(height: LoafSpace.x2),
        LoafButton(
          label: 'keep it',
          emphasis: LoafButtonEmphasis.quiet,
          size: LoafButtonSize.small,
          onTap: () => Navigator.of(context).pop(false),
        ),
      ],
    ),
    _SignOutStep.auth => ResetAuthStep(
      byPassword: _challenge?.kind == AuthKind.password,
      password: _password,
      checking: _checking,
      rejected: _rejected,
      inBrowser: _inBrowser,
      providerName: loafMoeProvider.name,
      onPassword: _byPassword,
      onSso: _bySso,
      onReopen: _reopen,
      onFinished: _browserFinished,
      onCancelBrowser: _cancelBrowser,
      lead: "confirm it's you before $_name is signed out.",
    ),
    _SignOutStep.signingOut => const Padding(
      padding: EdgeInsets.symmetric(vertical: LoafSpace.x5),
      child: WorkingLine('signing out…'),
    ),
  };

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_locked,
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(LoafSpace.x5),
      child: _body(LoafTokens.of(context)),
    ),
  );
}
