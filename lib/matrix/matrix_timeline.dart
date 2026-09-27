/// One room's conversation read from the SDK: [ui.Timeline] over the SDK's
/// own room timeline. Messages are mapped from its events each time they
/// change; nothing is kept but that snapshot, since the SDK is the store.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
// The SDK's own Timeline is the one wrapped here; the UI's is `ui.Timeline`.
import 'package:matrix/matrix.dart';

import '../ui/channel/timeline.dart' as ui;
import '../ui/model/models.dart' as ui;
import '../ui/spaces/add_space.dart' show spaceColorFor;

/// How many events one page of history asks for.
const historyPage = 50;

class MatrixTimeline extends ChangeNotifier
    with ui.ComposerAiming
    implements ui.Timeline {
  /// Opens [room]'s timeline straight away; until it has, the conversation
  /// is empty and [loadingOlder]. [member] maps a user id to a person as
  /// the rest of the app draws them.
  MatrixTimeline(this.room, {required this.you, required this.member}) {
    unawaited(_open());
  }

  final Room room;

  @override
  final ui.Member you;

  final ui.Member Function(String userId) member;

  Timeline? _timeline;
  var _opening = true;
  var _paging = false;
  var _pageFailed = false;
  var _disposed = false;
  List<ui.Message>? _messages;
  final _failures = StreamController<String>.broadcast();

  /// Transactions this session sent and has not heard back about. The SDK
  /// keeps an echo "sending" across a relaunch, but nothing sends it then:
  /// a sending echo that is not one of these reads as failed, so it can be
  /// retried or discarded rather than dimmed for ever.
  final _inFlight = <String>{};

  /// Reactions being added or taken back, by message and emoji. A second
  /// tap while one is on its way would otherwise add it twice: its echo is
  /// not in the timeline yet.
  final _reacting = <(String, String)>{};

  Future<void> _open() async {
    _opening = true;
    _pageFailed = false;
    _changed();
    try {
      final timeline = await room.getTimeline(
        limit: historyPage,
        onUpdate: _changed,
      );
      if (_disposed) {
        timeline.cancelSubscriptions();
        return;
      }
      _timeline = timeline;
    } on Object {
      // Offline, or the database had nothing to give: loading older
      // messages is how to try again.
      _pageFailed = true;
    }
    _opening = false;
    _changed();
  }

  void _changed() {
    _messages = null;
    if (!_disposed) notifyListeners();
  }

  // ── Reading ────────────────────────────────────────────────────────────

  @override
  List<ui.Message> get messages {
    final timeline = _timeline;
    if (timeline == null) return const [];
    return _messages ??= [
      // The SDK keeps its events newest first.
      for (final event in timeline.events.reversed) ?_message(event, timeline),
    ];
  }

  @override
  bool get writable => !room.encrypted;

  @override
  bool get canLoadOlder => _timeline?.canRequestHistory ?? false;

  @override
  bool get loadingOlder => _opening || _paging;

  @override
  bool get loadOlderFailed => _pageFailed;

  @override
  Stream<String> get failures => _failures.stream;

  static const _fileTypes = {
    MessageTypes.File,
    MessageTypes.Image,
    MessageTypes.Audio,
    MessageTypes.Video,
  };

  /// The row [event] draws as, or null for an event that draws none: state,
  /// reactions and edits (folded into what they relate to), a deleted
  /// message, anything unknown. A quote ([quoting]) never quotes in turn.
  ui.Message? _message(Event event, Timeline timeline, {bool quoting = false}) {
    if (event.redacted) return null;
    final author = member(event.senderId);
    final status = _unsent(event)
        ? ui.MessageStatus.failed
        : event.status.isSending
        ? ui.MessageStatus.sending
        : ui.MessageStatus.sent;
    if (event.type == EventTypes.Encrypted) {
      return ui.Message(
        id: event.eventId,
        author: author,
        sentAt: event.originServerTs,
        body: '',
        locked: true,
        status: status,
      );
    }
    if (event.type != EventTypes.Message ||
        event.relationshipType == RelationshipTypes.edit) {
      return null;
    }
    final display = _display(event, timeline);
    final text = display.calcUnlocalizedBody(
      hideReply: true,
      hideEdit: true,
      plaintextBody: true,
    );
    final body = switch (display.messageType) {
      MessageTypes.Emote => '${author.name} $text',
      final type when _fileTypes.contains(type) => '📎 $text',
      _ => text,
    };
    return ui.Message(
      id: event.eventId,
      author: author,
      sentAt: event.originServerTs,
      body: body,
      edited: !identical(display, event),
      reactions: quoting ? const [] : _reactions(event, timeline),
      replyTo: quoting ? null : _replyTo(event, timeline),
      status: status,
    );
  }

  /// [event] as its author last edited it. Only the author's own edits
  /// count, and only those the server has: a failed edit snaps back.
  Event _display(Event event, Timeline timeline) {
    final edits =
        event
            .aggregatedEvents(timeline, RelationshipTypes.edit)
            .where(
              (e) =>
                  e.senderId == event.senderId &&
                  e.type == EventTypes.Message &&
                  !_unsent(e),
            )
            .toList()
          ..sort((a, b) => a.originServerTs.compareTo(b.originServerTs));
    if (edits.isEmpty) return event;
    final json = edits.last.toJson();
    final content = json['content'];
    if (content is Map && content['m.new_content'] is Map) {
      json['content'] = content['m.new_content'];
    }
    return Event.fromJson(json, room);
  }

  /// One pill per emoji, counting each person once. A reaction that failed
  /// to send is not one.
  List<ui.Reaction> _reactions(Event event, Timeline timeline) {
    final byKey = <String, Set<String>>{};
    for (final r in event.aggregatedEvents(
      timeline,
      RelationshipTypes.reaction,
    )) {
      if (_unsent(r)) continue;
      final key = _reactionKey(r);
      if (key == null) continue;
      (byKey[key] ??= {}).add(r.senderId);
    }
    return [
      for (final MapEntry(:key, :value) in byKey.entries)
        ui.Reaction(key, value.length, mine: value.contains(you.id)),
    ];
  }

  static String? _reactionKey(Event reaction) => reaction.content
      .tryGetMap<String, Object?>('m.relates_to')
      ?.tryGet<String>('key');

  ui.Message? _replyTo(Event event, Timeline timeline) {
    final id = event.inReplyToEventId();
    if (id == null) return null;
    final target = timeline.events.where((e) => e.eventId == id).firstOrNull;
    if (target == null) {
      return ui.Message.stub(id: id, author: _someone);
    }
    return _message(target, timeline, quoting: true) ??
        ui.Message.stub(id: id, author: member(target.senderId));
  }

  static final _someone = ui.Member('', 'someone', spaceColorFor(''));

  // ── Writing ────────────────────────────────────────────────────────────

  /// Failed, or left sending by an app that has since quit.
  bool _unsent(Event event) =>
      event.status.isError ||
      (event.status.isSending && !_inFlight.contains(event.eventId));

  /// Sends under a transaction id this session knows it has in flight. The
  /// SDK throws only for a 403 or an event too large; any other failure it
  /// gives up on marks the echo failed and answers null, so null is a
  /// failure here too.
  Future<String> _send(Future<String?> Function(String txid) send) {
    final txid = room.client.generateUniqueTransactionId();
    _inFlight.add(txid);
    return send(txid)
        .then((id) => id ?? (throw StateError('not sent: $txid')))
        .whenComplete(() {
          _inFlight.remove(txid);
          _changed();
        });
  }

  Event? _event(String id) =>
      _timeline?.events.where((e) => e.eventId == id).firstOrNull;

  /// Runs [action], and on failure says [failure] as a toast.
  void _attempt(Future<Object?> Function() action, String failure) {
    unawaited(
      Future.sync(action).then<void>(
        (_) {},
        onError: (Object _) {
          if (!_disposed) _failures.add(failure);
        },
      ),
    );
  }

  @override
  void send(String text) {
    final body = text.trim();
    if (body.isEmpty) return;
    final target = this.target;
    final replyTo = target?.mode == ui.ComposerMode.reply
        ? _event(target!.message.id)
        : null;
    // A failure shows on the message itself, which stays to retry.
    unawaited(
      _send(
        (txid) => room.sendTextEvent(
          body,
          txid: txid,
          inReplyTo: replyTo,
          parseMarkdown: false,
          parseCommands: false,
        ),
      ).then<void>((_) {}, onError: (Object _) {}),
    );
    aim(null);
  }

  @override
  void saveEdit(String messageId, String text) {
    final body = text.trim();
    final current = messages.where((m) => m.id == messageId).firstOrNull;
    if (current != null && body.isNotEmpty && body != current.body) {
      _attempt(
        () => _send(
          (txid) => room.sendTextEvent(
            body,
            txid: txid,
            editEventId: messageId,
            parseMarkdown: false,
            parseCommands: false,
          ),
        ),
        "couldn't save that edit",
      );
    }
    aim(null);
  }

  @override
  void toggleReaction(String messageId, String emoji) {
    final event = _event(messageId);
    final timeline = _timeline;
    if (event == null || timeline == null) return;
    final key = (messageId, emoji);
    if (_reacting.contains(key)) return;
    final mine = event
        .aggregatedEvents(timeline, RelationshipTypes.reaction)
        .where(
          (r) =>
              r.senderId == you.id && !_unsent(r) && _reactionKey(r) == emoji,
        )
        .firstOrNull;
    // Still on its way, a reaction has no event id to take back yet.
    if (mine != null && !mine.status.isSent) return;
    _reacting.add(key);
    _attempt(
      () =>
          (mine == null
                  ? _send(
                      (txid) => room.sendReaction(messageId, emoji, txid: txid),
                    )
                  : room.redactEvent(mine.eventId))
              .whenComplete(() => _reacting.remove(key)),
      "couldn't react",
    );
  }

  @override
  void delete(String messageId) {
    _attempt(() => room.redactEvent(messageId), "couldn't delete that");
    if (target?.message.id == messageId) aim(null);
  }

  @override
  void retry(String messageId) {
    final event = _event(messageId);
    if (event == null || !_unsent(event)) return;
    // The SDK resends only what it has marked failed; one left sending by
    // a quit app is failed in all but name.
    event.status = EventStatus.error;
    _inFlight.add(event.eventId);
    unawaited(
      event.sendAgain().then<void>((_) {}, onError: (Object _) {}).whenComplete(
        () {
          _inFlight.remove(event.eventId);
          _changed();
        },
      ),
    );
  }

  @override
  void discard(String messageId) {
    final event = _event(messageId);
    if (event == null || !_unsent(event)) return;
    unawaited(event.cancelSend());
  }

  // ── History ────────────────────────────────────────────────────────────

  @override
  void loadOlder() {
    if (_opening || _paging) return;
    final timeline = _timeline;
    if (timeline == null) {
      unawaited(_open());
      return;
    }
    if (!timeline.canRequestHistory) return;
    _paging = true;
    _pageFailed = false;
    _changed();
    unawaited(
      timeline
          .requestHistory(historyCount: historyPage)
          .then<void>(
            (_) {},
            onError: (Object _) {
              _pageFailed = true;
            },
          )
          .whenComplete(() {
            _paging = false;
            _changed();
          }),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _timeline?.cancelSubscriptions();
    unawaited(_failures.close());
    super.dispose();
  }
}
