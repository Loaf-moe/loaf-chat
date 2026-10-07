/// Sign-in, as a design mockup: [SignInController] plays a fake homeserver
/// and this draws whatever state it reports.
///
/// Homeservers differ in what they accept, so the screen renders whatever
/// `/_matrix/client/v3/login` reports. loaf.moe advertises `m.login.sso`
/// (delegated to Kanidm, named "loaf.moe") and `m.login.password`; other
/// servers offer one, the other, or several identity providers. See
/// "Sign-in and verification" in the design spec.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../mock/fixtures.dart';
import '../theme/loaf_theme.dart';
import '../widgets/adaptive_panel.dart';
import '../widgets/error_note.dart';
import '../widgets/loaf_avatar.dart';
import '../widgets/loaf_button.dart';
import '../widgets/loaf_field.dart';
import '../window/window_chrome.dart';
import 'browser_wait.dart';
import 'sign_in_controller.dart';
import 'sign_in_state.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.controller, this.onSignOutInstead});

  final SignInController controller;

  /// Soft logout only: give up on this account, and this device's keys with
  /// it.
  final VoidCallback? onSignOutInstead;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _server = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();

  /// Which face of the form is showing. Presentation only, like the drawer
  /// or a collapsed category.
  var _showingPassword = false;
  var _editingServer = false;

  SignInController get _c => widget.controller;

  /// Whether the password form was on screen, last build and this one.
  var _formWasShown = false;
  var _formShown = false;

  /// A password form that goes while this screen stays was abandoned: back
  /// to SSO, another server, a failed look-up. iOS is told to forget what
  /// was typed, or it offers to save a password nobody signed in with.
  /// Signing in instead replaces the whole screen, and the screen's
  /// AutofillGroup commits as it goes: the one time a save is worth
  /// offering. (Telling iOS from here on success doesn't work: the
  /// group's own dispose would speak last.)
  void _forgetAbandonedForm() {
    if (_formWasShown && !_formShown) {
      TextInput.finishAutofillContext(shouldSave: false);
    }
    _formWasShown = _formShown;
  }

  @override
  void dispose() {
    _server.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  void _editServer() {
    _server.text = _c.state.server;
    setState(() => _editingServer = true);
  }

  void _connect() {
    if (serverNameFrom(_server.text) == null) return;
    _c.connect(_server.text);
    setState(() => _editingServer = false);
  }

  void _usernameChanged(String text) {
    // Someone typing here has chosen the form: a re-point to a server that
    // leads with SSO must not pull it out from under them.
    _showingPassword = true;
    _c.usernameChanged(text);
  }

  void _submitPassword() {
    final soft = _c.state.softLogout;
    _c.signInWithPassword(soft?.userId ?? _user.text, _password.text);
  }

  Future<void> _confirmSignOut(SoftLogout soft) async {
    final yes = await showAdaptivePanel<bool>(
      context,
      maxHeight: 320,
      child: _SignOutInstead(userId: soft.userId),
    );
    if (yes == true) widget.onSignOutInstead?.call();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Scaffold(
      backgroundColor: tokens.page,
      body: Column(
        children: [
          // Sign-in is the whole window, so it holds both corners.
          const WindowBand(),
          Expanded(
            child: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(LoafSpace.x6),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 380),
                    child: ListenableBuilder(
                      listenable: _c,
                      builder: (context, _) {
                        _formShown = false;
                        final state = _c.state;
                        // The point of no return: the picker offers a "connect"
                        // nothing would act on, and popping it up again on a
                        // commit that then fails would be worse than not asking.
                        if (state.activity == SignInActivity.signedIn &&
                            _editingServer) {
                          _editingServer = false;
                        }
                        final faces = _faces(tokens, state);
                        _forgetAbandonedForm();
                        // Around the whole screen, not the form: it outlives the form,
                        // so only the screen going (signed in) commits a save.
                        return AutofillGroup(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: faces,
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _faces(LoafTokens tokens, SignInState s) {
    // The browser has the conversation now; the screen only waits for it.
    if (s.activity == SignInActivity.inBrowser) {
      return [
        const _Wordmark(),
        const SizedBox(height: LoafSpace.x8),
        BrowserWait(
          name: s.provider?.name ?? s.server,
          onReopen: _c.reopenBrowser,
          onCancel: _c.cancelSso,
        ),
      ];
    }
    final soft = s.softLogout;
    final check = s.check;
    final failed = check is ServerFailed ? check : null;
    return [
      if (soft == null) const _Wordmark() else _Avatar(member: soft.member),
      const SizedBox(height: LoafSpace.x6),
      _Heading(tokens: tokens, softLogout: soft, editingServer: _editingServer),
      const SizedBox(height: LoafSpace.x8),
      // Choosing a homeserver replaces the sign-in controls rather than
      // sitting under them: otherwise the screen asks two questions at once.
      if (_editingServer)
        ..._serverSection()
      else ...[
        ..._authSection(tokens, s),
        // A soft-logged-out device belongs to its account's server.
        if (soft == null) ...[
          const SizedBox(height: LoafSpace.x5),
          _ServerRow(
            tokens: tokens,
            server: s.repointing ?? s.server,
            looking: s.repointing != null,
            onEdit: s.activity == SignInActivity.signedIn ? null : _editServer,
          ),
        ],
        if (failed != null) ...[
          const SizedBox(height: LoafSpace.x3),
          ErrorNote(message: failed.messageFor(s.server)),
        ],
        if (s.failure case final failure?) ...[
          const SizedBox(height: LoafSpace.x3),
          ErrorNote(message: failure),
        ],
        if (soft != null && s.activity != SignInActivity.signedIn) ...[
          const SizedBox(height: LoafSpace.x5),
          LoafButton(
            label: 'sign out instead',
            onTap: () => _confirmSignOut(soft),
            emphasis: LoafButtonEmphasis.quiet,
            size: LoafButtonSize.small,
          ),
        ],
      ],
    ];
  }

  /// The homeserver picker, shown instead of the sign-in controls.
  List<Widget> _serverSection() => [
    LoafField(
      controller: _server,
      hint: 'homeserver',
      icon: LucideIcons.server,
      exact: true,
      keyboardType: TextInputType.url,
      autofocus: true,
      onSubmit: _connect,
    ),
    const SizedBox(height: LoafSpace.x3),
    LoafButton(label: 'connect', onTap: _connect),
    Padding(
      padding: const EdgeInsets.only(top: LoafSpace.x3),
      child: LoafButton(
        label: 'cancel',
        onTap: () => setState(() => _editingServer = false),
        emphasis: LoafButtonEmphasis.quiet,
        size: LoafButtonSize.small,
      ),
    ),
  ];

  List<Widget> _authSection(LoafTokens tokens, SignInState s) {
    switch (s.check) {
      case ServerProbing():
        return [_WorkingNote(tokens: tokens, label: 'looking for ${s.server}')];
      case ServerFailed():
        return [
          LoafButton(
            label: 'try again',
            icon: LucideIcons.refreshCw,
            onTap: _c.retry,
          ),
        ];
      case ServerFound(:final flows):
        if (!flows.sso && !flows.password) {
          return [
            ErrorNote(message: '${s.server} offers no sign-in loaf can use'),
            const SizedBox(height: LoafSpace.x3),
            LoafButton(
              label: 'try again',
              icon: LucideIcons.refreshCw,
              onTap: _c.retry,
            ),
          ];
        }
        if (s.activity == SignInActivity.finishingSso) {
          return [_WorkingNote(tokens: tokens, label: 'signing in…')];
        }
        if (flows.password && (_showingPassword || !flows.sso)) {
          return _passwordForm(s, flows);
        }
        if (s.activity == SignInActivity.signedIn) {
          return [_WorkingNote(tokens: tokens, label: 'signing in…')];
        }
        return _ssoButtons(flows);
    }
  }

  List<Widget> _passwordForm(SignInState s, ServerFlows flows) {
    _formShown = true;
    final soft = s.softLogout != null;
    final busy =
        s.activity == SignInActivity.checkingPassword ||
        s.activity == SignInActivity.signedIn;
    final wait = s.retryIn;
    final label = wait != null
        ? 'try again in ${wait.inSeconds}s'
        : busy
        ? 'signing in…'
        : 'sign in';
    return [
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // A soft-logged-out device already knows whose it is.
          if (!soft) ...[
            LoafField(
              controller: _user,
              hint: 'username',
              icon: LucideIcons.atSign,
              exact: true,
              autofillHints: const [AutofillHints.username],
              textInputAction: TextInputAction.next,
              onChanged: _usernameChanged,
            ),
            const SizedBox(height: LoafSpace.x2),
          ],
          LoafField(
            controller: _password,
            hint: 'password',
            icon: LucideIcons.keyRound,
            obscure: true,
            autofillHints: const [AutofillHints.password],
            textInputAction: TextInputAction.done,
            onSubmit: _submitPassword,
          ),
        ],
      ),
      if (s.wrongPassword) ...[
        const SizedBox(height: LoafSpace.x3),
        ErrorNote(
          message: soft
              ? "that password didn't match"
              : "that username and password didn't match",
        ),
      ],
      if (wait != null) ...[
        const SizedBox(height: LoafSpace.x3),
        const ErrorNote(message: 'too many tries'),
      ],
      const SizedBox(height: LoafSpace.x3),
      LoafButton(
        label: label,
        onTap: busy || wait != null ? null : _submitPassword,
      ),
      if (flows.sso)
        Padding(
          padding: const EdgeInsets.only(top: LoafSpace.x3),
          child: LoafButton(
            label: flows.providers.length == 1
                ? 'back to ${flows.providers.single.name}'
                : 'back to other ways in',
            onTap: busy ? null : () => setState(() => _showingPassword = false),
            emphasis: LoafButtonEmphasis.quiet,
            size: LoafButtonSize.small,
          ),
        ),
    ];
  }

  List<Widget> _ssoButtons(ServerFlows flows) {
    final providers = flows.providers;
    return [
      if (providers.length == 1)
        LoafButton(
          label: 'continue with ${providers.single.name}',
          icon: LucideIcons.logIn,
          onTap: () => _c.continueWithSso(providers.single),
        )
      else
        // The server's order is not a preference, so no provider gets the
        // filled button.
        for (final (i, p) in providers.indexed) ...[
          if (i > 0) const SizedBox(height: LoafSpace.x2),
          LoafButton(
            label: 'continue with ${p.name}',
            leading: _ProviderMark(provider: p),
            emphasis: LoafButtonEmphasis.outlined,
            onTap: () => _c.continueWithSso(p),
          ),
        ],
      // Offered only where it leads somewhere: a server advertising no
      // m.login.password gets no link to a form it would reject.
      if (flows.password)
        Padding(
          padding: const EdgeInsets.only(top: LoafSpace.x3),
          child: LoafButton(
            label: 'use a username and password',
            onTap: () => setState(() => _showingPassword = true),
            emphasis: LoafButtonEmphasis.quiet,
            size: LoafButtonSize.small,
          ),
        ),
    ];
  }
}

/// An identity provider's initial, standing in for its mxc icon.
class _ProviderMark extends StatelessWidget {
  const _ProviderMark({required this.provider});

  final IdentityProvider provider;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Container(
      width: 20,
      height: 20,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: tokens.sunken, shape: BoxShape.circle),
      child: Text(
        provider.initial,
        style: loafBody(11, 600).copyWith(color: tokens.textStrong),
      ),
    );
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
  const _Heading({
    required this.tokens,
    this.softLogout,
    this.editingServer = false,
  });

  final LoafTokens tokens;

  /// Set when the screen is locked to an expired account: it welcomes that
  /// person back rather than inviting anyone in.
  final SoftLogout? softLogout;
  final bool editingServer;

  @override
  Widget build(BuildContext context) {
    final soft = softLogout;
    return Column(
      children: [
        // One italic red word as the flourish, per the brand.
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: soft == null ? 'come on ' : 'welcome ',
                style: loafDisplay(30, 600).copyWith(color: tokens.textStrong),
              ),
              TextSpan(
                text: soft == null ? 'in' : 'back',
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
          soft != null
              ? 'sign in again as ${soft.userId}'
              : editingServer
              ? 'where does your account live?'
              : 'sign in to pick up where you left off',
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: loafBody(15, 400).copyWith(color: tokens.textMuted),
        ),
      ],
    );
  }
}

/// The homeserver, as a quiet line under the sign-in controls. Most people
/// never touch it, so it does not get to look like a form until tapped.
class _ServerRow extends StatelessWidget {
  const _ServerRow({
    required this.tokens,
    required this.server,
    required this.looking,
    required this.onEdit,
  });

  final LoafTokens tokens;
  final String server;

  /// A full id in the username named this server and it is being checked.
  final bool looking;

  /// Null while nothing should come of tapping the row: it is then plain
  /// text, with no tap handler and no click cursor.
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final row = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (looking) ...[
          SizedBox(
            width: 11,
            height: 11,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: tokens.textMuted,
            ),
          ),
          const SizedBox(width: LoafSpace.x2),
        ],
        Text(
          looking ? 'looking for ' : 'on ',
          style: loafBody(13, 400).copyWith(color: tokens.textMuted),
        ),
        Flexible(
          child: Text(
            server,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: loafBody(13, 600).copyWith(color: tokens.textBody),
          ),
        ),
        if (!looking) ...[
          const SizedBox(width: LoafSpace.x1),
          Icon(LucideIcons.pencil, size: 13, color: tokens.textMuted),
        ],
      ],
    );
    final edit = onEdit;
    if (edit == null) return row;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: edit,
        behavior: HitTestBehavior.opaque,
        child: row,
      ),
    );
  }
}

class _WorkingNote extends StatelessWidget {
  const _WorkingNote({required this.tokens, required this.label});

  final LoafTokens tokens;
  final String label;

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
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: loafBody(13, 400).copyWith(color: tokens.textMuted),
          ),
        ),
      ],
    ),
  );
}

/// Soft logout leads with who you are, since the screen is locked to them.
class _Avatar extends StatelessWidget {
  const _Avatar({required this.member});

  final Member member;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Center(
      child: LoafAvatar(
        label: member.initials,
        color: member.color,
        size: 64,
        image: member.avatar,
        boxShadow: tokens.shadowMd,
        textStyle: loafBody(24, 600),
      ),
    );
  }
}

class _SignOutInstead extends StatelessWidget {
  const _SignOutInstead({required this.userId});

  final String userId;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(LoafSpace.x5),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'sign out of $userId?',
            style: loafBody(17, 600).copyWith(color: tokens.textStrong),
          ),
          const SizedBox(height: LoafSpace.x2),
          Text(
            "this device's encryption keys go with it. anything only this "
            "device could read stays unreadable unless it's in key backup.",
            style: loafBody(14, 400).copyWith(color: tokens.textMuted),
          ),
          const SizedBox(height: LoafSpace.x5),
          LoafButton(
            label: 'sign out',
            onTap: () => Navigator.pop(context, true),
          ),
          const SizedBox(height: LoafSpace.x2),
          LoafButton(
            label: 'keep signing in',
            onTap: () => Navigator.pop(context, false),
            emphasis: LoafButtonEmphasis.quiet,
            size: LoafButtonSize.small,
          ),
        ],
      ),
    );
  }
}
