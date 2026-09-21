/// Sign-in: pick a homeserver, then use whatever it actually supports.
///
/// loaf.moe delegates all human auth to Kanidm over OIDC, so it advertises
/// `m.login.sso` and no password flow at all. Other homeservers do offer
/// passwords, so the screen renders what discovery reports rather than
/// assuming either. A mockup: discovery is faked, nothing authenticates.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/loaf_theme.dart';

/// What a homeserver told us it supports, from `/_matrix/client/v3/login`.
class LoginFlows {
  const LoginFlows({
    required this.sso,
    required this.password,
    this.ssoProviderName,
  });

  final bool sso;
  final bool password;

  /// The identity provider's display name, shown on the SSO button.
  final String? ssoProviderName;
}

enum _Discovery { idle, probing, ready, failed }

/// Fake `.well-known` + login-flow discovery, so the states feel real.
Future<LoginFlows> _discover(String server) async {
  await Future<void>.delayed(const Duration(milliseconds: 700));
  if (server.contains('nope') || !server.contains('.')) {
    throw const FormatException('no homeserver there');
  }
  if (server.endsWith('loaf.moe')) {
    return const LoginFlows(
      sso: true,
      password: false,
      ssoProviderName: 'loaf.moe',
    );
  }
  return const LoginFlows(
    sso: true,
    password: true,
    ssoProviderName: 'single sign-on',
  );
}

const _defaultServer = 'loaf.moe';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.onSignedIn});

  final VoidCallback onSignedIn;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _server = TextEditingController(text: _defaultServer);
  final _user = TextEditingController();
  final _password = TextEditingController();

  var _discovery = _Discovery.idle;
  LoginFlows? _flows;
  String? _error;
  var _editingServer = false;

  /// Set when the user chooses the password form on a server that offers
  /// both. SSO stays the default because it is the one that always works.
  var _usePassword = false;

  @override
  void initState() {
    super.initState();
    _probe();
  }

  @override
  void dispose() {
    _server.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _probe() async {
    final server = _server.text.trim();
    setState(() {
      _discovery = _Discovery.probing;
      _error = null;
      _flows = null;
      _usePassword = false;
    });
    try {
      final flows = await _discover(server);
      if (!mounted) return;
      setState(() {
        _flows = flows;
        _discovery = _Discovery.ready;
      });
    } on FormatException {
      if (!mounted) return;
      setState(() {
        _discovery = _Discovery.failed;
        _error = "couldn't reach a matrix server at that address";
      });
    }
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
                  _Heading(tokens: tokens),
                  const SizedBox(height: LoafSpace.x8),
                  ..._authSection(tokens),
                  const SizedBox(height: LoafSpace.x5),
                  _ServerRow(
                    tokens: tokens,
                    controller: _server,
                    editing: _editingServer,
                    onEdit: () => setState(() => _editingServer = true),
                    onSubmit: () {
                      setState(() => _editingServer = false);
                      _probe();
                    },
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: LoafSpace.x3),
                    _ErrorNote(tokens: tokens, message: _error!),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _authSection(LoafTokens tokens) {
    final flows = _flows;

    if (_discovery == _Discovery.probing) {
      return [_ProbingNote(tokens: tokens, server: _server.text.trim())];
    }
    if (flows == null) {
      return [
        _PrimaryButton(
          label: 'try again',
          icon: LucideIcons.refreshCw,
          onTap: _probe,
        ),
      ];
    }

    // Only servers advertising m.login.password can show the form at all.
    final showPassword = flows.password && (_usePassword || !flows.sso);

    if (showPassword) {
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
        if (flows.sso)
          _TextLink(
            label: 'back to ${flows.ssoProviderName}',
            onTap: () => setState(() => _usePassword = false),
          ),
      ];
    }

    if (flows.sso) {
      return [
        _PrimaryButton(
          label: 'continue with ${flows.ssoProviderName}',
          icon: LucideIcons.logIn,
          onTap: widget.onSignedIn,
        ),
        // Offered only where it leads somewhere. loaf.moe hands every login
        // to Kanidm and advertises no password flow, so it gets no link.
        if (flows.password)
          _TextLink(
            label: 'use a username and password',
            onTap: () => setState(() => _usePassword = true),
          ),
      ];
    }

    return [
      Text(
        "that server doesn't offer a sign-in method this app supports yet",
        textAlign: TextAlign.center,
        style: loafBody(13, 400).copyWith(color: tokens.textMuted),
      ),
    ];
  }
}

/// The brand mark, larger than the rail's. Cream tile, navy letter, red dot —
/// the same in both palettes, because the tile is always cream.
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
  const _Heading({required this.tokens});

  final LoafTokens tokens;

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
        'sign in to pick up where you left off',
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
    this.onSubmit,
  });

  final LoafTokens tokens;
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final bool obscure;
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
            onSubmitted: (_) => onSubmit?.call(),
            style: loafBody(
              15,
              400,
              height: 1.4,
            ).copyWith(color: tokens.textBody),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              // Same calibration as the composer: Outfit paints low inside
              // its line box, so the padding is asymmetric on purpose.
              contentPadding: const EdgeInsets.only(top: 6, bottom: 14),
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

/// The homeserver line. Collapsed it is a quiet sentence; tapping it opens a
/// field. Most people never touch it, so it does not get to look like a form.
class _ServerRow extends StatelessWidget {
  const _ServerRow({
    required this.tokens,
    required this.controller,
    required this.editing,
    required this.onEdit,
    required this.onSubmit,
  });

  final LoafTokens tokens;
  final TextEditingController controller;
  final bool editing;
  final VoidCallback onEdit;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    if (editing) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Field(
            tokens: tokens,
            controller: controller,
            hint: 'homeserver',
            icon: LucideIcons.server,
            onSubmit: onSubmit,
          ),
          const SizedBox(height: LoafSpace.x2),
          GestureDetector(
            onTap: onSubmit,
            child: Text(
              'connect',
              textAlign: TextAlign.center,
              style: loafBody(13, 600).copyWith(color: tokens.accent),
            ),
          ),
        ],
      );
    }

    return GestureDetector(
      onTap: onEdit,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'on ',
            style: loafBody(13, 400).copyWith(color: tokens.textMuted),
          ),
          Flexible(
            child: Text(
              controller.text.trim(),
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
