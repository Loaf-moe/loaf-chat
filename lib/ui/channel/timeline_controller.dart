/// The channel's messages plus what the composer is currently aimed at.
///
/// A mockup stand-in for the room timeline matrix-dart-sdk will provide: the
/// actions really change what is on screen, but nothing leaves the device.
library;

import 'package:flutter/foundation.dart';

import '../mock/fixtures.dart';

enum ComposerMode { reply, edit }

/// A message the composer is replying to or editing.
@immutable
class ComposerTarget {
  const ComposerTarget(this.mode, this.message);

  final ComposerMode mode;
  final Message message;
}

class TimelineController extends ChangeNotifier {
  TimelineController(List<Message> messages, {required this.you})
    : _messages = [...messages];

  /// Whose reactions are "mine", and whose messages may be edited.
  final Member you;

  final List<Message> _messages;
  ComposerTarget? _target;

  List<Message> get messages => List.unmodifiable(_messages);
  ComposerTarget? get target => _target;

  /// Adds your [emoji] to the message, or takes it back if it is already
  /// yours. A pill nobody is left holding disappears.
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

  void delete(String messageId) {
    _messages.removeWhere((m) => m.id == messageId);
    if (_target?.message.id == messageId) _target = null;
    notifyListeners();
  }

  void startReply(Message message) =>
      _aim(ComposerTarget(ComposerMode.reply, message));

  void startEdit(Message message) =>
      _aim(ComposerTarget(ComposerMode.edit, message));

  void clearTarget() => _aim(null);

  void _aim(ComposerTarget? target) {
    _target = target;
    notifyListeners();
  }
}
