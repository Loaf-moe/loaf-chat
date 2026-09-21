/// Sign-in, as a design mockup. Static: nothing probes a homeserver and
/// nothing authenticates.
///
/// Homeservers differ in what they accept, so the real screen will render
/// whatever `/_matrix/client/v3/login` reports. loaf.moe advertises both
/// `m.login.sso` (delegated to Kanidm, named "loaf.moe") and
/// `m.login.password`; other servers offer one or the other. Those
/// possibilities are the [LoginLook]s below, so each can be looked at.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/loaf_theme.dart';

/// The states this screen has to look right in.
enum LoginLook {
  /// What loaf.moe actually offers: SSO first, password behind a link.
  ssoAndPassword,

  /// A server with no password flow — no link, because it would dead-end.
  ssoOnly,

  /// A server with no SSO: the form, with nothing to go back to.
  passwordOnly,

  /// Waiting on the homeserver.
  probing,

  /// Nothing answered.
  unreachable,
}

class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key,
    required this.onSignedIn,
    this.look = LoginLook.ssoAndPassword,
    this.server = 'loaf.moe',
    this.ssoProviderName = 'loaf.moe',
  });

  final VoidCallback onSignedIn;
  final LoginLook look;
  final String server;
  final String ssoProviderName;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late final _server = TextEditingController(text: widget.server);
  final _user = TextEditingController();
  final _password = TextEditingController();

  /// Which face of the form is showing. Presentation only, like the drawer
  /// or a collapsed category.
  var _showingPassword = false;
  var _editingServer = false;

  @override
  void dispose() {
    _server.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);

    return Scaffold(
      backgroundColor: tokens.page,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(LoafSpace.x6),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _Wordmark(),
                  const SizedBox(height: LoafSpace.x6),
                  _Heading(tokens: tokens, editingServer: _editingServer),
                  const SizedBox(height: LoafSpace.x8),
                  // Choosing a homeserver replaces the sign-in controls
                  // rather than sitting under them — otherwise the screen
                  // asks two questions at once.
                  if (_editingServer)
                    ..._serverSection(tokens)
                  else ...[
                    ..._authSection(tokens),
                    const SizedBox(height: LoafSpace.x5),
                    _ServerRow(
                      tokens: tokens,
                      server: _server.text.trim(),
                      onEdit: () => setState(() => _editingServer = true),
                    ),
                    if (widget.look == LoginLook.unreachable) ...[
                      const SizedBox(height: LoafSpace.x3),
                      _ErrorNote(
                        tokens: tokens,
                        message:
                            "couldn't reach a matrix server at that address",
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The homeserver picker, shown instead of the sign-in controls.
  List<Widget> _serverSection(LoafTokens tokens) => [
    _Field(
      tokens: tokens,
      controller: _server,
      hint: 'homeserver',
      icon: LucideIcons.server,
      autofocus: true,
      onSubmit: () => setState(() => _editingServer = false),
    ),
    const SizedBox(height: LoafSpace.x3),
    _PrimaryButton(
      label: 'connect',
      onTap: () => setState(() => _editingServer = false),
    ),
    _TextLink(
      label: 'cancel',
      onTap: () => setState(() => _editingServer = false),
    ),
  ];

  List<Widget> _authSection(LoafTokens tokens) {
    final sso =
        widget.look == LoginLook.ssoAndPassword ||
        widget.look == LoginLook.ssoOnly;
    final password =
        widget.look == LoginLook.ssoAndPassword ||
        widget.look == LoginLook.passwordOnly;

    switch (widget.look) {
      case LoginLook.probing:
        return [_ProbingNote(tokens: tokens, server: _server.text.trim())];
      case LoginLook.unreachable:
        return [
          _PrimaryButton(
            label: 'try again',
            icon: LucideIcons.refreshCw,
            onTap: () {},
          ),
        ];
      case LoginLook.ssoAndPassword:
      case LoginLook.ssoOnly:
      case LoginLook.passwordOnly:
        break;
    }

    if (password && (_showingPassword || !sso)) {
      return [
        _Field(
          tokens: tokens,
          controller: _user,
          hint: 'username',
          icon: LucideIcons.atSign,
        ),
        const SizedBox(height: LoafSpace.x2),
        _Field(
          tokens: tokens,
          controller: _password,
          hint: 'password',
          icon: LucideIcons.keyRound,
          obscure: true,
        ),
        const SizedBox(height: LoafSpace.x3),
        _PrimaryButton(label: 'sign in', onTap: widget.onSignedIn),
        if (sso)
          _TextLink(
            label: 'back to ${widget.ssoProviderName}',
            onTap: () => setState(() => _showingPassword = false),
          ),
      ];
    }

    return [
      _PrimaryButton(
        label: 'continue with ${widget.ssoProviderName}',
        icon: LucideIcons.logIn,
        onTap: widget.onSignedIn,
      ),
      // Offered only where it leads somewhere: a server advertising no
      // m.login.password gets no link to a form it would reject.
      if (password)
        _TextLink(
          label: 'use a username and password',
          onTap: () => setState(() => _showingPassword = true),
        ),
    ];
  }
}

class _Wordmark extends StatelessWidget {
  const _Wordmark();

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Center(
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          color: tokens.onRail,
          borderRadius: BorderRadius.circular(LoafRadius.xl),
          boxShadow: tokens.shadowMd,
        ),
        child: Center(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: 'l',
                  style: loafDisplay(38, 600).copyWith(color: tokens.rail),
                ),
                TextSpan(
                  text: '.',
                  style: loafDisplay(38, 600).copyWith(color: tokens.accent),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading({required this.tokens, this.editingServer = false});

  final LoafTokens tokens;
  final bool editingServer;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      // One italic red word as the flourish, per the brand.
      Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: 'come on ',
              style: loafDisplay(30, 600).copyWith(color: tokens.textStrong),
            ),
            TextSpan(
              text: 'in',
              style: loafDisplay(
                30,
                600,
                style: FontStyle.italic,
              ).copyWith(color: tokens.accent),
            ),
          ],
        ),
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: LoafSpace.x2),
      Text(
        editingServer
            ? 'where does your account live?'
            : 'sign in to pick up where you left off',
        textAlign: TextAlign.center,
        style: loafBody(15, 400).copyWith(color: tokens.textMuted),
      ),
    ],
  );
}

class _PrimaryButton extends StatefulWidget {
  const _PrimaryButton({required this.label, required this.onTap, this.icon});

  final String label;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  State<_PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<_PrimaryButton> {
  bool _pressed = false;

  void _set(bool v) => _pressed == v ? null : setState(() => _pressed = v);

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return GestureDetector(
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? LoafMotion.pressScale : 1.0,
        duration: LoafMotion.fast,
        curve: LoafMotion.ease,
        child: Container(
          height: 48,
          decoration: BoxDecoration(
            color: tokens.accent,
            borderRadius: BorderRadius.circular(LoafRadius.full),
            boxShadow: _pressed ? null : tokens.shadowAccent,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 18, color: tokens.textOnAccent),
                const SizedBox(width: LoafSpace.x2),
              ],
              Flexible(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: loafBody(15, 600).copyWith(color: tokens.textOnAccent),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A quiet secondary action. Text only — the brand keeps one red moment per
/// zone, and the primary button already spent it.
class _TextLink extends StatelessWidget {
  const _TextLink({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: LoafSpace.x3),
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Text(
          label,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: loafBody(13, 600).copyWith(color: tokens.textBody),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.tokens,
    required this.controller,
    required this.hint,
    required this.icon,
    this.obscure = false,
    this.autofocus = false,
    this.onSubmit,
  });

  final LoafTokens tokens;
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final bool obscure;
  final bool autofocus;
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context) => Container(
    height: 46,
    padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x3),
    decoration: BoxDecoration(
      color: tokens.card,
      borderRadius: BorderRadius.circular(LoafRadius.lg),
      border: Border.all(color: tokens.border),
    ),
    child: Row(
      children: [
        Icon(icon, size: 17, color: tokens.textMuted),
        const SizedBox(width: LoafSpace.x2),
        Expanded(
          child: TextField(
            controller: controller,
            obscureText: obscure,
            autofocus: autofocus,
            onSubmitted: (_) => onSubmit?.call(),
            style: loafBody(
              15,
              400,
              height: 1.4,
            ).copyWith(color: tokens.textBody),
            decoration: InputDecoration(
              // Collapsed, so the field contributes exactly its line box and
              // the Row's centring does the vertical work. The composer needs
              // an asymmetric nudge because it bottom-aligns against taller
              // controls; that constant is specific to that layout and does
              // not transfer here.
              isCollapsed: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
              hintText: hint,
              hintStyle: loafBody(
                15,
                400,
                height: 1.4,
              ).copyWith(color: tokens.textMuted),
            ),
          ),
        ),
      ],
    ),
  );
}

/// The homeserver, as a quiet line under the sign-in controls. Most people
/// never touch it, so it does not get to look like a form until tapped.
class _ServerRow extends StatelessWidget {
  const _ServerRow({
    required this.tokens,
    required this.server,
    required this.onEdit,
  });

  final LoafTokens tokens;
  final String server;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onEdit,
    behavior: HitTestBehavior.opaque,
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text('on ', style: loafBody(13, 400).copyWith(color: tokens.textMuted)),
        Flexible(
          child: Text(
            server,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: loafBody(13, 600).copyWith(color: tokens.textBody),
          ),
        ),
        const SizedBox(width: LoafSpace.x1),
        Icon(LucideIcons.pencil, size: 13, color: tokens.textMuted),
      ],
    ),
  );
}

class _ProbingNote extends StatelessWidget {
  const _ProbingNote({required this.tokens, required this.server});

  final LoafTokens tokens;
  final String server;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 15,
          height: 15,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: tokens.accent,
          ),
        ),
        const SizedBox(width: LoafSpace.x3),
        Flexible(
          child: Text(
            'looking for $server',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: loafBody(13, 400).copyWith(color: tokens.textMuted),
          ),
        ),
      ],
    ),
  );
}

class _ErrorNote extends StatelessWidget {
  const _ErrorNote({required this.tokens, required this.message});

  final LoafTokens tokens;
  final String message;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(LoafSpace.x3),
    decoration: BoxDecoration(
      color: tokens.accentSoft,
      borderRadius: BorderRadius.circular(LoafRadius.md),
      border: Border.all(color: tokens.accent),
    ),
    child: Row(
      children: [
        Icon(LucideIcons.triangleAlert, size: 16, color: tokens.accent),
        const SizedBox(width: LoafSpace.x2),
        Expanded(
          child: Text(
            message,
            style: loafBody(13, 400).copyWith(color: tokens.textBody),
          ),
        ),
      ],
    ),
  );
}
