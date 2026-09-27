/// A conversation's messages, as the channel view draws them, and what you
/// can do to them. `TimelineController` plays them from fixtures;
/// `MatrixTimeline` maps them from the SDK's room timeline.
library;

import 'package:flutter/foundation.dart';

import '../model/models.dart';

enum ComposerMode { reply, edit }

/// A message the composer is replying to or editing.
@immutable
class ComposerTarget {
  const ComposerTarget(this.mode, this.message);

  final ComposerMode mode;
  final Message message;
}

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

  /// What went wrong with an action that has no row of its own to show it
  /// on: a reaction, an edit or a delete the server refused. Each is a
  /// short line for a toast.
  Stream<String> get failures;

  ComposerTarget? get target;
  void startReply(Message message);
  void startEdit(Message message);
  void clearTarget();

  /// Posts [text], quoting the reply target if there is one. Blank text
  /// never sends.
  void send(String text);

  /// Adds your [emoji] to the message, or takes it back if it is already
  /// yours.
  void toggleReaction(String messageId, String emoji);

  /// Replaces a message's text. Blank or unchanged text is not an edit.
  void saveEdit(String messageId, String text);

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
