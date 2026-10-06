/// The mock backend's [Timeline]: a channel's messages from fixtures.
///
/// The actions really change what is on screen, but nothing leaves the
/// device, so nothing is ever sending or failed and there is no history
/// further back.
library;

import 'package:flutter/foundation.dart';
import 'package:markdown/markdown.dart' as md;

import '../mock/fixtures.dart';
import 'media_row.dart';
import 'mentions.dart';
import 'timeline.dart';

export 'timeline.dart' show Attachment, ComposerMode, ComposerTarget, Timeline;

class TimelineController extends ChangeNotifier
    with ComposerAiming
    implements Timeline {
  TimelineController(
    List<Message> messages, {
    required this.you,
    this._uploadLimit,
  }) : _messages = [...messages];

  @override
  final Member you;

  final int? _uploadLimit;

  @override
  Future<int?> uploadLimit() async => _uploadLimit;

  final List<Message> _messages;

  @override
  List<Message> get messages => List.unmodifiable(_messages);

  @override
  bool get writable => true;
  @override
  bool get canLoadOlder => false;
  @override
  bool get loadingOlder => false;
  @override
  bool get loadOlderFailed => false;
  @override
  void loadOlder() {}
  @override
  Stream<String> get failures => const Stream.empty();

  /// Nothing the mock sends can fail.
  @override
  void retry(String messageId) {}
  @override
  void discard(String messageId) {}

  /// Adds your [emoji] to the message, or takes it back if it is already
  /// yours. A pill nobody is left holding disappears.
  @override
  void toggleReaction(String messageId, String emoji) {
    final index = _messages.indexWhere((m) => m.id == messageId);
    if (index < 0) return;
    final message = _messages[index];
    final reactions = [...message.reactions];
    final existing = reactions.indexWhere((r) => r.emoji == emoji);

    if (existing < 0) {
      reactions.add(Reaction(emoji, 1, mine: true));
    } else {
      final r = reactions[existing];
      final count = r.mine ? r.count - 1 : r.count + 1;
      if (count == 0) {
        reactions.removeAt(existing);
      } else {
        reactions[existing] = Reaction(emoji, count, mine: !r.mine);
      }
    }

    _messages[index] = message.copyWith(reactions: reactions);
    notifyListeners();
  }

  var _sent = 0;

  /// Posts [text] as a message from [you], quoting the reply target if there
  /// is one. Blank text never sends. The mock's stand-in for sending a room
  /// event: it lands locally and immediately.
  @override
  void send(String text, {List<Mention> mentions = const []}) {
    final body = text.trim();
    if (body.isEmpty) return;
    final target = this.target;
    _messages.add(
      Message(
        id: 'local-${_sent++}',
        author: you,
        sentAt: DateTime.now(),
        body: body,
        formatted: _formatted(body, mentions),
        replyTo: target?.mode == ComposerMode.reply ? target!.message : null,
      ),
    );
    aim(null);
  }

  /// Lands [file] as a message from [you]. Nothing is uploaded anywhere.
  @override
  void sendFile(Attachment file) {
    final target = this.target;
    _messages.add(
      Message(
        id: 'local-${_sent++}',
        author: you,
        sentAt: DateTime.now(),
        body: '',
        media: Media(
          kind: kindOf(file.mimeType),
          name: file.name,
          size: file.bytes.length,
          mimeType: file.mimeType,
          ref: file.bytes,
        ),
        replyTo: target?.mode == ComposerMode.reply ? target!.message : null,
      ),
    );
    aim(null);
  }

  /// Lands a call's system line, attributed to whoever the call was with.
  void addCall(String label, CallLine kind, {required Member from}) {
    _messages.add(
      Message(
        id: 'local-${_sent++}',
        author: from,
        sentAt: DateTime.now(),
        body: label,
        callLine: kind,
      ),
    );
    notifyListeners();
  }

  /// Replaces a message's text. Saving it unchanged is not an edit, so it is
  /// not marked as one.
  @override
  void saveEdit(
    String messageId,
    String text, {
    List<Mention> mentions = const [],
  }) {
    final index = _messages.indexWhere((m) => m.id == messageId);
    final body = text.trim();
    if (index >= 0 && body.isNotEmpty && body != _messages[index].body) {
      _messages[index] = _messages[index].copyWith(
        body: body,
        formatted: _formatted(body, mentions),
        edited: true,
      );
    }
    aim(null);
  }

  /// A message with mentions in it comes with HTML, as the server would see
  /// it, so they draw as pills. Without any, the plain body is enough.
  static String? _formatted(String body, List<Mention> mentions) {
    if (mentions.isEmpty) return null;
    // Typed tags are text, as the SDK treats them; a lone `>` still quotes.
    final escaped = body.replaceAllMapped(
      RegExp('<([^>]*)>'),
      (m) => '&lt;${m[1]}&gt;',
    );
    return md.markdownToHtml(
      linkMentions(escaped, mentions),
      extensionSet: md.ExtensionSet.gitHubFlavored,
    );
  }

  @override
  void delete(String messageId) {
    _messages.removeWhere((m) => m.id == messageId);
    if (target?.message.id == messageId) {
      aim(null);
    } else {
      notifyListeners();
    }
  }
}
