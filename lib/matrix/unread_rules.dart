import 'package:matrix/matrix.dart';

/// Whether [event] is a message the timeline draws as a row of its own, and
/// so one that can be unread. The same test as `MatrixTimeline._message`:
/// deleted messages, edits, reactions and state are not messages. An
/// encrypted event counts before it is read, since its relation stays in
/// the clear and tells an edit or a reaction apart.
bool countsAsMessage(Event event) {
  if (event.redacted) return false;
  if (event.type == EventTypes.Encrypted) {
    return !const {
      RelationshipTypes.reaction,
      RelationshipTypes.edit,
    }.contains(event.relationshipType);
  }
  return const {EventTypes.Message, EventTypes.Sticker}.contains(event.type) &&
      event.relationshipType != RelationshipTypes.edit;
}

/// Whether [event] mentions you. `m.mentions` decides alone when a sender
/// includes it (intentional mentions); a message without it comes from an
/// older client, and falls back to your name or id in the body, the way
/// the default push rules do. A message still encrypted mentions no one
/// until it can be read.
bool mentionsMe(Event event, {required String userId, String? displayName}) {
  if (!const {EventTypes.Message, EventTypes.Sticker}.contains(event.type)) {
    return false;
  }
  final content = event.content;
  final mentions = content['m.mentions'];
  if (mentions is Map) {
    final ids = mentions['user_ids'];
    if (ids is List && ids.contains(userId)) return true;
    return mentions['room'] == true && _mayNotifyRoom(event);
  }
  final body = content.tryGet<String>('body') ?? '';
  if (_containsWord(body, '@room') && _mayNotifyRoom(event)) return true;
  final name = displayName?.trim();
  return _containsWord(body, userId) ||
      (name != null && name.isNotEmpty && _containsWord(body, name));
}

/// Whether the sender has the power level the room asks of `@room`, 50
/// unless the room says otherwise.
bool _mayNotifyRoom(Event event) {
  final room = event.room;
  final levels = room.getState(EventTypes.RoomPowerLevels)?.content;
  final notifications = levels?['notifications'];
  final needed = notifications is Map && notifications['room'] is int
      ? notifications['room'] as int
      : 50;
  return room.getPowerLevelByUserId(event.senderId).level >= needed;
}

/// [word] in [text] on its own, ignoring case: "Ada" is in "hi Ada!" but
/// not in "Adamant".
bool _containsWord(String text, String word) => RegExp(
  '(^|[^\\p{L}\\p{N}_])${RegExp.escape(word)}(\$|[^\\p{L}\\p{N}_])',
  caseSensitive: false,
  unicode: true,
).hasMatch(text);
