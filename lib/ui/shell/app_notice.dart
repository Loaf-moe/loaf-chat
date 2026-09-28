/// Things the app needs to tell you about itself — a session waiting to be
/// verified, an update ready to install — shown as tiles at the bottom of the
/// spaces rail rather than as banners across the channel you are reading.
///
/// Two tones, because these are not equally urgent. [NoticeTone.quiet] is
/// news you can act on whenever. [NoticeTone.attention] spends the brand's one
/// red moment, and is reserved for things that leave you worse off if ignored
/// — which, for a Matrix client, means encryption.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../platform.dart';
import '../theme/loaf_theme.dart';
import '../widgets/loaf_button.dart';

enum NoticeTone { quiet, attention }

class AppNotice {
  const AppNotice({
    required this.icon,
    required this.title,
    required this.body,
    required this.actionLabel,
    this.onAction,
    this.onDismiss,
    this.tone = NoticeTone.quiet,
  });

  /// An update is ready to install. Desktop only — on a phone the App Store
  /// or TestFlight owns updates, so the shell never creates this there.
  factory AppNotice.update({
    required String version,
    VoidCallback? onAction,
    VoidCallback? onDismiss,
  }) => AppNotice(
    icon: LucideIcons.arrowDownToLine,
    title: 'loaf $version is ready',
    body: 'restart to pick up the new version',
    actionLabel: 'restart',
    onAction: onAction,
    onDismiss: onDismiss,
  );

  /// This session is not verified, so it cannot read encrypted history.
  /// Deliberately has no dismiss: ignoring it silently loses messages.
  factory AppNotice.verify({VoidCallback? onAction}) => AppNotice(
    icon: LucideIcons.shieldAlert,
    title: 'verify this session',
    body: 'until you do, encrypted messages sent before now stay unreadable',
    actionLabel: 'verify',
    tone: NoticeTone.attention,
    onAction: onAction,
  );

  /// A fresh account has no identity yet, so nothing protects its encrypted
  /// history. No dismiss, for the same reason as [AppNotice.verify].
  factory AppNotice.setUpRecovery({VoidCallback? onAction}) => AppNotice(
    icon: LucideIcons.keyRound,
    title: 'set up recovery',
    body: 'so you never lose your encrypted messages',
    actionLabel: 'set up',
    tone: NoticeTone.attention,
    onAction: onAction,
  );

  /// A new identity's recovery key, made or being made while its panel was
  /// put away. No dismiss: it is shown once, and only through here.
  factory AppNotice.newKey({VoidCallback? onAction, required bool making}) =>
      AppNotice(
        icon: LucideIcons.keyRound,
        title: 'your new recovery key',
        body: making
            ? "it's being made — you'll need to save it"
            : "it's shown once. save it before anything else",
        actionLabel: 'show',
        tone: NoticeTone.attention,
        onAction: onAction,
      );

  final IconData icon;
  final String title;
  final String body;
  final String actionLabel;
  final VoidCallback? onAction;

  /// Omitted when the notice must not be put off.
  final VoidCallback? onDismiss;
  final NoticeTone tone;

  bool get loud => tone == NoticeTone.attention;
}

/// A notice as a rail tile: the same footprint as a space, so it reads as
/// part of the rail rather than something bolted onto it.
class NoticeTile extends StatelessWidget {
  const NoticeTile({super.key, required this.notice});

  final AppNotice notice;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final loud = notice.loud;
    return Tooltip(
      message: notice.title,
      preferBelow: false,
      child: GestureDetector(
        onTap: () => _open(context),
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: loud ? tokens.accentSoft : tokens.card,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: loud ? tokens.accent : tokens.border),
          ),
          child: Icon(
            notice.icon,
            size: 20,
            color: loud ? tokens.accent : tokens.textMuted,
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    final choice = isDesktop
        ? await _showPopover(context)
        : await _showSheet(context);
    switch (choice) {
      case _Choice.act:
        notice.onAction?.call();
      case _Choice.later:
        notice.onDismiss?.call();
      case null:
        break;
    }
  }

  /// Mobile: from the bottom, action within thumb reach.
  Future<_Choice?> _showSheet(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return showModalBottomSheet<_Choice>(
      context: context,
      backgroundColor: tokens.card,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(LoafRadius.xxxl),
        ),
      ),
      builder: (context) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            LoafSpace.x5,
            0,
            LoafSpace.x5,
            LoafSpace.x5,
          ),
          child: _NoticeDetails(notice: notice, size: LoafButtonSize.large),
        ),
      ),
    );
  }

  /// Desktop: a card beside the tile, dismissed by clicking away or Escape.
  Future<_Choice?> _showPopover(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final tile = context.findRenderObject()! as RenderBox;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final rect = tile.localToGlobal(Offset.zero, ancestor: overlay) & tile.size;

    // showMenu's own future resolves the instant the route is popped, while
    // its card is still playing its exit fade — captured here so the choice
    // isn't handed back until that route is actually gone.
    TransitionRoute<_Choice>? route;
    final future = showMenu<_Choice>(
      context: context,
      color: tokens.card,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LoafRadius.lg),
        side: BorderSide(color: tokens.border),
      ),
      // Open to the right of the tile, level with it; showMenu slides it up
      // if it would run off the bottom, which it will near the rail's foot.
      position: RelativeRect.fromLTRB(
        rect.right + LoafSpace.x3,
        rect.top,
        overlay.size.width - rect.right - LoafSpace.x3,
        overlay.size.height - rect.top,
      ),
      items: [_NoticeMenuEntry(notice: notice, onRoute: (r) => route = r)],
    );
    return future.then((choice) async {
      await route?.completed;
      return choice;
    });
  }
}

enum _Choice { act, later }

class _NoticeMenuEntry extends PopupMenuEntry<_Choice> {
  const _NoticeMenuEntry({required this.notice, required this.onRoute});

  final AppNotice notice;

  /// Hands back the popup's own route, read from this entry's context once
  /// it's built inside it — the only place that context is reachable from.
  final ValueChanged<TransitionRoute<_Choice>> onRoute;

  @override
  double get height => 120;

  @override
  bool represents(_Choice? value) => false;

  @override
  State<_NoticeMenuEntry> createState() => _NoticeMenuEntryState();
}

class _NoticeMenuEntryState extends State<_NoticeMenuEntry> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of<_Choice>(context);
    if (route != null) widget.onRoute(route);
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 280,
    child: Padding(
      padding: const EdgeInsets.all(LoafSpace.x4),
      child: _NoticeDetails(notice: widget.notice, size: LoafButtonSize.small),
    ),
  );
}

/// Icon, title, explanation, and the action — shared by sheet and popover.
class _NoticeDetails extends StatelessWidget {
  const _NoticeDetails({required this.notice, required this.size});

  final AppNotice notice;
  final LoafButtonSize size;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final loud = notice.loud;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              notice.icon,
              size: 18,
              color: loud ? tokens.accent : tokens.textMuted,
            ),
            const SizedBox(width: LoafSpace.x2),
            Expanded(
              child: Text(
                notice.title,
                style: loafBody(15, 600).copyWith(color: tokens.textStrong),
              ),
            ),
          ],
        ),
        const SizedBox(height: LoafSpace.x2),
        Text(
          notice.body,
          style: loafBody(13, 400).copyWith(color: tokens.textMuted),
        ),
        const SizedBox(height: LoafSpace.x4),
        Row(
          children: [
            LoafButton(
              label: notice.actionLabel,
              onTap: () => Navigator.pop(context, _Choice.act),
              emphasis: loud
                  ? LoafButtonEmphasis.filled
                  : LoafButtonEmphasis.outlined,
              size: size,
            ),
            if (notice.onDismiss != null) ...[
              const SizedBox(width: LoafSpace.x2),
              LoafButton(
                label: 'later',
                onTap: () => Navigator.pop(context, _Choice.later),
                emphasis: LoafButtonEmphasis.quiet,
                size: size,
              ),
            ],
          ],
        ),
      ],
    );
  }
}
