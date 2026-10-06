/// The channel reading surface: header, timeline and composer.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/loaf_session.dart' show DeviceTrust;
import '../mock/fixtures.dart';
import '../theme/loaf_theme.dart';
import '../theme/sakura.dart';
import '../widgets/loaf_button.dart';
import '../widgets/toast.dart';
import 'composer.dart';
import 'message_group_tile.dart';
import 'timeline.dart';

const _narrowTopicWidth = 480.0;

const _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

String _formatDay(DateTime day) {
  final today = DateUtils.dateOnly(DateTime.now());
  final yesterday = today.subtract(const Duration(days: 1));
  if (day == today) return 'Today';
  if (day == yesterday) return 'Yesterday';
  return '${day.day} ${_monthNames[day.month - 1]}';
}

/// The channel a user is currently reading: header, message timeline and the
/// composer to reply with. Fake data, but [timeline] is live: reactions,
/// deletions and the composer's reply or edit target all go through it.
class ChannelView extends StatelessWidget {
  const ChannelView({
    super.key,
    required this.channel,
    required this.timeline,
    this.onOpenNavigation,
    this.onToggleMembers,
    this.callBar,
    this.navigationAttention = false,
    this.onStartCall,
    this.callPanel,
    this.callPanelExpanded = false,
    this.onRead,
    this.trust = DeviceTrust.verified,
    this.onVerify,
    this.people = const [],
    this.channels = const [],
  });

  final Channel channel;

  /// Someone else's message arrived while you were looking: you have read
  /// it. Only heard while the app is in front.
  final VoidCallback? onRead;

  /// DMs only: rings everyone in the chat. Null while a call here is already
  /// running: the panel is right there, so the header's buttons step aside.
  final void Function({required bool video})? onStartCall;

  /// A DM's call, docked above the timeline.
  final Widget? callPanel;

  /// The call fills the conversation: no timeline, no composer.
  final bool callPanelExpanded;

  /// Null while the backend cannot read messages yet: the conversation
  /// says so, and offers no composer to write into nowhere.
  final Timeline? timeline;

  /// This device's trust, which a room that can't be written in yet waits
  /// on; [onVerify] opens the panel that changes it.
  final DeviceTrust trust;
  final VoidCallback? onVerify;

  /// Marks the menu button when a notice that must not be missed is waiting
  /// in the rail. Only matters on a phone, where the rail hides in the drawer.
  final bool navigationAttention;

  /// The connected-voice bar, when the user is in a voice channel. It sits
  /// between the timeline and the composer rather than below the composer,
  /// so the composer stays the last thing above the keyboard.
  final Widget? callBar;

  /// Opens the navigation drawer. Only passed on the phone layout — when
  /// null, the caller is showing the space/channel rail permanently, so no
  /// menu button is drawn at all.
  final VoidCallback? onOpenNavigation;

  final VoidCallback? onToggleMembers;

  /// Who `@` offers in the composer, and what `#` offers.
  final List<Member> people;
  final List<Channel> channels;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    // The page colour runs edge to edge while the content sits inside the
    // insets, so the status bar and home indicator float over a continuous
    // surface instead of covering the header and composer.
    return ColoredBox(
      color: tokens.page,
      child: SafeArea(
        child: Column(
          children: [
            _ChannelHeader(
              channel: channel,
              onOpenNavigation: onOpenNavigation,
              onToggleMembers: onToggleMembers,
              navigationAttention: navigationAttention,
              onStartCall: onStartCall,
            ),
            if (timeline == null)
              Expanded(
                child: channel.kind == ChannelKind.voice
                    ? const _NoVoice()
                    : const _NoMessages(),
              )
            else if (callPanel != null && callPanelExpanded)
              Expanded(child: callPanel!)
            else ...[
              ?callPanel,
              Expanded(
                // Petals drift over the page colour, behind the messages;
                // the timeline paints no background of its own.
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const SakuraPetals(),
                    // Keyed by the conversation, so switching rooms starts a
                    // fresh list that listens to the room it shows.
                    _Timeline(
                      key: ObjectKey(timeline),
                      controller: timeline!,
                      onRead: onRead,
                    ),
                  ],
                ),
              ),
              if (channel.waitingFor.isNotEmpty)
                _WaitingLine(people: channel.waitingFor),
              ?callBar,
              // Heard live: a room becomes writable the moment this device
              // is verified, with the conversation open.
              ListenableBuilder(
                listenable: timeline!,
                builder: (context, _) => timeline!.writable
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const ShinkansenRail(),
                          Composer(
                            // Keyed like the list: a reply card or a draft
                            // belongs to the room it was started in, and must
                            // not send in the next.
                            key: ObjectKey(timeline),
                            channelName: channel.name,
                            timeline: timeline!,
                            people: people,
                            channels: channels,
                            prefix: switch (channel) {
                              Channel(kind: ChannelKind.direct, members: [_]) =>
                                '@',
                              Channel(kind: ChannelKind.direct) => '',
                              _ => '#',
                            },
                          ),
                        ],
                      )
                    : _EncryptedNote(trust: trust, onVerify: onVerify),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ChannelHeader extends StatelessWidget {
  const _ChannelHeader({
    required this.channel,
    required this.onOpenNavigation,
    required this.onToggleMembers,
    required this.navigationAttention,
    this.onStartCall,
  });

  final Channel channel;
  final VoidCallback? onOpenNavigation;
  final VoidCallback? onToggleMembers;
  final bool navigationAttention;
  final void Function({required bool video})? onStartCall;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final topic = channel.topic;
    final direct = channel.kind == ChannelKind.direct;
    final onStartCall = this.onStartCall;
    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: tokens.page,
        border: Border(bottom: BorderSide(color: tokens.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final showTopic =
              topic != null && constraints.maxWidth >= _narrowTopicWidth;
          return Row(
            children: [
              if (onOpenNavigation != null) ...[
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    _HeaderIconButton(
                      icon: LucideIcons.menu,
                      onTap: onOpenNavigation,
                    ),
                    if (navigationAttention)
                      Positioned(
                        right: 8,
                        top: 8,
                        child: IgnorePointer(
                          child: Container(
                            key: const ValueKey('navigation-attention'),
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: tokens.accent,
                              shape: BoxShape.circle,
                              border: Border.all(color: tokens.page, width: 2),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: LoafSpace.x2),
              ],
              Icon(
                switch (channel.kind) {
                  ChannelKind.direct when channel.members.length > 1 =>
                    LucideIcons.users,
                  ChannelKind.direct => LucideIcons.atSign,
                  ChannelKind.room => LucideIcons.messagesSquare,
                  ChannelKind.voice => LucideIcons.volume2,
                  _ => LucideIcons.hash,
                },
                size: 18,
                color: tokens.textMuted,
              ),
              const SizedBox(width: LoafSpace.x1),
              Flexible(
                flex: 0,
                child: Text(
                  channel.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: loafBody(15, 600).copyWith(color: tokens.textStrong),
                ),
              ),
              if (showTopic) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x3),
                  child: SizedBox(
                    height: 16,
                    child: VerticalDivider(color: tokens.border, width: 1),
                  ),
                ),
                Expanded(
                  child: Text(
                    topic,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: loafBody(13, 400).copyWith(color: tokens.textMuted),
                  ),
                ),
              ] else
                const Spacer(),
              if (direct && onStartCall != null) ...[
                _HeaderIconButton(
                  icon: LucideIcons.phone,
                  tooltip: 'Start a voice call',
                  onTap: () => onStartCall(video: false),
                ),
                _HeaderIconButton(
                  icon: LucideIcons.video,
                  tooltip: 'Start a video call',
                  onTap: () => onStartCall(video: true),
                ),
              ] else if (!direct)
                _HeaderIconButton(
                  icon: LucideIcons.users,
                  onTap: onToggleMembers,
                ),
              // No search button: message search is a v1 non-goal, and in
              // encrypted rooms it needs a client-side index (see the spec).
            ],
          );
        },
      ),
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      icon: Icon(icon, size: 20, color: tokens.textMuted),
    );
  }
}

class _Timeline extends StatefulWidget {
  const _Timeline({super.key, required this.controller, this.onRead});

  final Timeline controller;
  final VoidCallback? onRead;

  @override
  State<_Timeline> createState() => _TimelineState();
}

/// The "older messages" line at the top of the list.
const _olderKey = ValueKey('older');

/// Stable as the list grows: a group only ever gains messages at its end,
/// so its first message names it.
Key _keyOf(TimelineEntry entry) => switch (entry) {
  DaySeparator() => ValueKey(('day', entry.day)),
  CallEntry() => ValueKey(('call', entry.message.id)),
  MessageGroup() => ValueKey(('group', entry.messages.first.id)),
};

class _TimelineState extends State<_Timeline> {
  final _scroll = ScrollController();

  /// The newest message when last heard from, to tell a new one from
  /// older ones paging in above.
  String? _lastId;
  late final StreamSubscription<String> _failures;

  /// Someone else's message arrived while you were not looking. macOS
  /// reports a window without focus as inactive, so this is common: it is
  /// read when you come back instead.
  bool _unreadWhileAway = false;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lastId = widget.controller.messages.lastOrNull?.id;
    widget.controller.addListener(_onMessages);
    _scroll.addListener(_maybeLoadOlder);
    _failures = widget.controller.failures.listen((text) {
      if (mounted) showToast(context, text);
    });
    _lifecycle = AppLifecycleListener(onResume: _onResume);
    _checkFilled();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    widget.controller.removeListener(_onMessages);
    unawaited(_failures.cancel());
    _scroll.dispose();
    super.dispose();
  }

  /// A new newest message: yours brings you back down to it, even if you
  /// had scrolled up to reread something; someone else's does not yank you
  /// around, but is read if you are looking, or once you are back. Older
  /// messages paging in above change neither.
  void _onMessages() {
    final last = widget.controller.messages.lastOrNull;
    final arrived = last != null && last.id != _lastId;
    _lastId = last?.id;
    setState(() {});
    _checkFilled();
    if (!arrived) return;
    if (last.author.id == widget.controller.you.id) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          0,
          duration: LoafMotion.normal,
          curve: LoafMotion.ease,
        );
      }
    } else if (_looking) {
      widget.onRead?.call();
    } else {
      _unreadWhileAway = true;
    }
  }

  void _onResume() {
    if (!_unreadWhileAway) return;
    _unreadWhileAway = false;
    widget.onRead?.call();
  }

  /// In front and focused. A window behind another, or an app in the
  /// background, is not reading anything.
  bool get _looking {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  /// Within a screen of the oldest message loaded: fetch more. The list is
  /// reversed, so the oldest end is the far end of the scroll.
  void _maybeLoadOlder() {
    final timeline = widget.controller;
    if (!timeline.canLoadOlder ||
        timeline.loadingOlder ||
        timeline.loadOlderFailed ||
        !_scroll.hasClients) {
      return;
    }
    final position = _scroll.position;
    if (position.extentAfter < position.viewportDimension) {
      timeline.loadOlder();
    }
  }

  /// A short conversation never scrolls, so nothing would ask for more:
  /// check once each change has been laid out.
  void _checkFilled() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) _maybeLoadOlder();
  });

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final entries = groupTimeline(controller.messages).reversed.toList();
    final top = controller.loadingOlder
        ? const _OlderLine(failed: false)
        : controller.loadOlderFailed
        ? _OlderLine(failed: true, onRetry: controller.loadOlder)
        : null;
    // The list matches its children by key, not by place: a new message
    // shifts every entry along one, and each must keep its own State (a
    // video playing in it) rather than take its neighbour's.
    final indexOf = <Key, int>{
      for (var i = 0; i < entries.length; i++) _keyOf(entries[i]): i,
      if (top != null) _olderKey: entries.length,
    };
    return ListView.builder(
      controller: _scroll,
      reverse: true,
      padding: const EdgeInsets.symmetric(
        horizontal: LoafSpace.x4,
        vertical: LoafSpace.x2,
      ),
      itemCount: entries.length + (top == null ? 0 : 1),
      findChildIndexCallback: (key) => indexOf[key],
      itemBuilder: (context, index) {
        if (index == entries.length) {
          return KeyedSubtree(key: _olderKey, child: top!);
        }
        final entry = entries[index];
        return KeyedSubtree(
          key: _keyOf(entry),
          child: switch (entry) {
            DaySeparator() => _DaySeparatorTile(entry: entry),
            CallEntry() => _CallLineTile(message: entry.message),
            MessageGroup() => Padding(
              padding: const EdgeInsets.only(bottom: LoafSpace.x4),
              child: MessageGroupTile(group: entry, controller: controller),
            ),
          },
        );
      },
    );
  }
}

/// The top of a conversation while older messages are on their way, or
/// when fetching them failed.
class _OlderLine extends StatelessWidget {
  const _OlderLine({required this.failed, this.onRetry});

  final bool failed;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final quiet = loafBody(13, 400).copyWith(color: tokens.textMuted);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: LoafSpace.x4),
      child: Center(
        child: failed
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text("couldn't load older messages · ", style: quiet),
                  InkWell(
                    onTap: onRetry,
                    borderRadius: BorderRadius.circular(LoafRadius.sm),
                    child: Text(
                      'try again',
                      style: loafBody(13, 600).copyWith(color: tokens.accent),
                    ),
                  ),
                ],
              )
            : Text('loading older messages', style: quiet),
      ),
    );
  }
}

class _DaySeparatorTile extends StatelessWidget {
  const _DaySeparatorTile({required this.entry});

  final DaySeparator entry;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: LoafSpace.x4),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Divider(color: tokens.border, height: 1, thickness: 1),
          Container(
            color: tokens.page,
            padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x2),
            child: Text(
              _formatDay(entry.day),
              style: loafBody(11, 600).copyWith(color: tokens.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

/// A call's system line: small, centred and quiet, so a DM's history of
/// calls reads as punctuation between messages rather than as messages.
class _CallLineTile extends StatelessWidget {
  const _CallLineTile({required this.message});

  final Message message;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final missed = message.callLine == CallLine.missed;
    final at = message.sentAt;
    final time =
        '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.only(bottom: LoafSpace.x4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            missed ? LucideIcons.phoneMissed : LucideIcons.phone,
            size: 14,
            color: missed ? tokens.accent : tokens.textMuted,
          ),
          const SizedBox(width: LoafSpace.x2),
          Text(
            message.body,
            style: loafBody(13, 500).copyWith(color: tokens.textBody),
          ),
          const SizedBox(width: LoafSpace.x2),
          Text(
            time,
            style: loafBody(11, 400).copyWith(color: tokens.textMuted),
          ),
        ],
      ),
    );
  }
}

/// A DM you started, before the people you asked have joined. Messages
/// still send — they read them on joining — so it says so.
class _WaitingLine extends StatelessWidget {
  const _WaitingLine({required this.people});

  final List<Member> people;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final names = switch (people) {
      [final one] => one.name,
      [...final rest, final last] =>
        '${rest.map((m) => m.name).join(', ')} and ${last.name}',
      _ => '',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LoafSpace.x4,
        0,
        LoafSpace.x4,
        LoafSpace.x2,
      ),
      child: Row(
        children: [
          Icon(LucideIcons.hourglass, size: 14, color: tokens.textMuted),
          const SizedBox(width: LoafSpace.x2),
          Expanded(
            child: Text(
              'waiting for $names to join. you can already write.',
              style: loafBody(13, 400).copyWith(color: tokens.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

/// Where the timeline goes, before this backend can read one.
class _NoMessages extends StatelessWidget {
  const _NoMessages();

  @override
  Widget build(BuildContext context) => const _Placeholder(
    icon: LucideIcons.messagesSquare,
    title: "messages aren't available here yet",
  );
}

/// A voice channel, before this backend can join calls. Joining is the
/// channel's only next step, so it says plainly that voice isn't there
/// rather than drawing controls that would do nothing.
class _NoVoice extends StatelessWidget {
  const _NoVoice();

  @override
  Widget build(BuildContext context) => const _Placeholder(
    icon: LucideIcons.volumeOff,
    title: "voice chat isn't available yet",
    detail:
        "loaf can't connect to voice channels yet. "
        'text channels work as usual.',
  );
}

/// A quiet, centred line in place of a conversation.
class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.icon, required this.title, this.detail});

  final IconData icon;
  final String title;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final detail = this.detail;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(LoafSpace.x6),
        child: ConstrainedBox(
          // Keeps the detail line a readable measure on a wide window.
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 28, color: tokens.textMuted),
              const SizedBox(height: LoafSpace.x3),
              Text(
                title,
                textAlign: TextAlign.center,
                style:
                    loafBody(
                      detail == null ? 13 : 15,
                      detail == null ? 400 : 600,
                    ).copyWith(
                      color: detail == null
                          ? tokens.textMuted
                          : tokens.textStrong,
                    ),
              ),
              if (detail != null) ...[
                const SizedBox(height: LoafSpace.x1),
                Text(
                  detail,
                  textAlign: TextAlign.center,
                  style: loafBody(13, 400).copyWith(color: tokens.textMuted),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// In place of the composer in an encrypted room, until this device is
/// verified: nothing is sent there unencrypted, and the way forward is one
/// tap away.
class _EncryptedNote extends StatelessWidget {
  const _EncryptedNote({required this.trust, this.onVerify});

  final DeviceTrust trust;
  final VoidCallback? onVerify;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final (line, action) = switch (trust) {
      DeviceTrust.noIdentity => ('set up recovery to send here', 'set up'),
      DeviceTrust.unverified => ('verify this device to send here', 'verify'),
      DeviceTrust.verified => ('sending here waits for encryption', null),
    };
    final onVerify = this.onVerify;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LoafSpace.x4,
        LoafSpace.x3,
        LoafSpace.x4,
        LoafSpace.x4,
      ),
      child: Row(
        children: [
          Icon(LucideIcons.lock, size: 14, color: tokens.textMuted),
          const SizedBox(width: LoafSpace.x2),
          Expanded(
            child: Text(
              line,
              style: loafBody(13, 400).copyWith(color: tokens.textMuted),
            ),
          ),
          if (action != null && onVerify != null)
            LoafButton(
              label: action,
              onTap: onVerify,
              emphasis: LoafButtonEmphasis.outlined,
              size: LoafButtonSize.small,
            ),
        ],
      ),
    );
  }
}
