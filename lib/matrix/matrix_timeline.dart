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
    final status = switch (event.status) {
      EventStatus.sending => ui.MessageStatus.sending,
      EventStatus.error => ui.MessageStatus.failed,
      EventStatus.sent || EventStatus.synced => ui.MessageStatus.sent,
    };
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
                  !e.status.isError,
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
      if (r.status.isError) continue;
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

  // ── Not wired yet ──────────────────────────────────────────────────────

  Never _unwired(String what) =>
      throw UnsupportedError('$what is not wired to the SDK yet');

  @override
  void send(String text) => _unwired('sending');
  @override
  void saveEdit(String messageId, String text) => _unwired('editing');
  @override
  void toggleReaction(String messageId, String emoji) => _unwired('reacting');
  @override
  void delete(String messageId) => _unwired('deleting');
  @override
  void retry(String messageId) => _unwired('sending');
  @override
  void discard(String messageId) => _unwired('sending');

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
