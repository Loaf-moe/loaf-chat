/// A conversation's messages, as the channel view draws them, and what you
/// can do to them. `TimelineController` plays them from fixtures;
/// `MatrixTimeline` maps them from the SDK's room timeline.
library;

import 'package:flutter/foundation.dart';

import '../model/models.dart';
import 'mentions.dart';

export 'mentions.dart' show Mention, MentionKind;

enum ComposerMode { reply, edit }

/// A file picked to send: what the platform's picker handed back, read into
/// memory, since a Matrix upload is one request of the whole thing.
@immutable
class Attachment {
  const Attachment({required this.name, required this.bytes, this.mimeType});

  final String name;
  final Uint8List bytes;

  /// As the picker reported it, when it did; otherwise worked out from
  /// [name] and the bytes at send time.
  final String? mimeType;
}

/// A message the composer is replying to or editing.
@immutable
class ComposerTarget {
  const ComposerTarget(this.mode, this.message);

  final ComposerMode mode;
  final Message message;
}

/// What a jump to a message says when the message can't be had: deleted,
/// never visible to you, in a room you are not in, or out of reach.
const messageUnavailable = "that message isn't available";

abstract interface class Timeline implements Listenable {
  /// Whose reactions are "mine", and whose messages may be edited.
  Member get you;

  /// Oldest first.
  List<Message> get messages;

  /// False where this device cannot write yet: an encrypted room, before
  /// this device is verified. The composer is replaced by a line saying so,
  /// and a locked message is one whose key has yet to come.
  bool get writable;

  /// Whether there is history further back to ask for.
  bool get canLoadOlder;

  /// True while older messages, or the first ones, are being fetched.
  bool get loadingOlder;

  /// The last fetch of older messages failed; [loadOlder] tries again.
  bool get loadOlderFailed;

  /// Fetches the next stretch of history. Does nothing while a fetch is
  /// already running or once [canLoadOlder] is false.
  void loadOlder();

  /// Whether there are messages newer than those loaded: the conversation
  /// was opened at an older message and has not caught up with the live
  /// end yet.
  bool get canLoadNewer;

  /// True while newer messages are being fetched.
  bool get loadingNewer;

  /// The last fetch of newer messages failed; [loadNewer] tries again.
  bool get loadNewerFailed;

  /// Fetches the next stretch towards the live end. Does nothing while a
  /// fetch is already running or once [canLoadNewer] is false.
  void loadNewer();

  /// Counts one up each time the conversation reopens on another stretch
  /// of history. The view starts its list over then, rather than keep a
  /// scroll position that belonged to other messages.
  int get stretch;

  /// The message to bring into view and light up, until the view has done
  /// so and called [jumpShown]. Set by [jumpTo] once the message is loaded.
  String? get jumpTarget;

  /// The view has shown [jumpTarget].
  void jumpShown();

  /// Brings [messageId] into view: at once when it is loaded, otherwise
  /// once the conversation has reopened around it. One that can't be had
  /// leaves the newest messages showing, and [failures] says so.
  void jumpTo(String messageId);

  /// Back to the newest messages, for a conversation opened further back.
  /// Does nothing at the live end.
  void showNewest();

  /// What went wrong with an action that has no row of its own to show it
  /// on: a reaction, an edit or a delete the server refused. Each is a
  /// short line for a toast.
  Stream<String> get failures;

  ComposerTarget? get target;
  void startReply(Message message);
  void startEdit(Message message);
  void clearTarget();

  /// Posts [text], quoting the reply target if there is one. Blank text
  /// never sends. [mentions] are the people and channels picked into it,
  /// already narrowed to the ones [text] still holds: each goes as a pill,
  /// and each person is told.
  void send(String text, {List<Mention> mentions = const []});

  /// The largest file the server takes, in bytes, or null where it can't
  /// be told. The composer checks a picked file against it before reading
  /// it, so a file that could never send is turned away at once.
  Future<int?> uploadLimit();

  /// Posts [file] as a media message — an image, a video, a sound or any
  /// other file, by its type — quoting the reply target if there is one.
  /// One the server refuses as too big leaves no row, and says why in
  /// [failures].
  void sendFile(Attachment file);

  /// Adds your [emoji] to the message, or takes it back if it is already
  /// yours.
  void toggleReaction(String messageId, String emoji);

  /// Replaces a message's text. Blank or unchanged text is not an edit.
  /// [mentions] are as for [send].
  void saveEdit(
    String messageId,
    String text, {
    List<Mention> mentions = const [],
  });

  void delete(String messageId);

  /// Sends a message that failed to send once more.
  void retry(String messageId);

  /// Gives up on a message that failed to send, and removes it.
  void discard(String messageId);
}

/// The composer's aim, which is the same whatever the backend: it is what
/// the person is doing, not anything the server knows.
mixin ComposerAiming on ChangeNotifier {
  ComposerTarget? _target;

  ComposerTarget? get target => _target;

  void startReply(Message message) =>
      aim(ComposerTarget(ComposerMode.reply, message));

  void startEdit(Message message) =>
      aim(ComposerTarget(ComposerMode.edit, message));

  void clearTarget() => aim(null);

  @protected
  void aim(ComposerTarget? target) {
    _target = target;
    notifyListeners();
  }
}
