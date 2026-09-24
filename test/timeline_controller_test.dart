import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/channel/message_actions.dart';
import 'package:loaf_native/ui/channel/timeline_controller.dart';
import 'package:loaf_native/ui/mock/fixtures.dart';

const _you = Member('@you', 'you', Colors.red);
const _them = Member('@them', 'them', Colors.blue);

Message _msg(String id, Member author, {List<Reaction> reactions = const []}) =>
    Message(
      id: id,
      author: author,
      sentAt: DateTime(2026, 9, 24, 10),
      body: 'body $id',
      reactions: reactions,
    );

void main() {
  group('actionsFor', () {
    test('your own messages can be edited and deleted', () {
      expect(actionsFor(_msg('1', _you), _you), [
        MessageAction.reply,
        MessageAction.copy,
        MessageAction.edit,
        MessageAction.delete,
      ]);
    });

    test('other people\'s messages can only be replied to and copied', () {
      // Deleting someone else's message is moderation, deferred to v2.
      expect(actionsFor(_msg('1', _them), _you), [
        MessageAction.reply,
        MessageAction.copy,
      ]);
    });
  });

  group('toggleReaction', () {
    List<Reaction> reactionsAfter(List<Reaction> start, String emoji) {
      final c = TimelineController([
        _msg('1', _them, reactions: start),
      ], you: _you);
      c.toggleReaction('1', emoji);
      return c.messages.single.reactions;
    }

    String describe(List<Reaction> rs) =>
        rs.map((r) => '${r.emoji}${r.count}${r.mine ? '*' : ''}').join(' ');

    test('a new emoji appends a pill of one, marked yours', () {
      expect(describe(reactionsAfter([], '🥖')), '🥖1*');
    });

    test('joining someone else\'s reaction increments it', () {
      expect(describe(reactionsAfter([const Reaction('🔥', 3)], '🔥')), '🔥4*');
    });

    test('taking back your reaction decrements it', () {
      expect(
        describe(reactionsAfter([const Reaction('🔥', 3, mine: true)], '🔥')),
        '🔥2',
      );
    });

    test('the pill disappears when its count reaches zero', () {
      expect(
        describe(
          reactionsAfter([
            const Reaction('😍', 7),
            const Reaction('🥖', 1, mine: true),
          ], '🥖'),
        ),
        '😍7',
      );
    });
  });

  group('composer target', () {
    test('reply and edit set the target; clearing resets it', () {
      final message = _msg('1', _you);
      final c = TimelineController([message], you: _you);

      c.startReply(message);
      expect(c.target?.mode, ComposerMode.reply);
      c.startEdit(message);
      expect(c.target?.mode, ComposerMode.edit);
      expect(c.target?.message.id, '1');
      c.clearTarget();
      expect(c.target, isNull);
    });

    test('deleting the targeted message clears the target', () {
      final message = _msg('1', _you);
      final c = TimelineController([message, _msg('2', _them)], you: _you);

      c.startEdit(message);
      c.delete('1');

      expect(c.messages.map((m) => m.id), ['2']);
      expect(c.target, isNull);
    });
  });

  group('sending', () {
    test('a sent message is yours, at the end, and clears the target', () {
      final target = _msg('1', _them);
      final c = TimelineController([target], you: _you);

      c.startReply(target);
      c.send('  hot out of the oven  ');

      final sent = c.messages.last;
      expect(sent.author.id, _you.id);
      expect(sent.body, 'hot out of the oven');
      expect(sent.replyTo?.id, '1', reason: 'the reply carries its quote');
      expect(c.target, isNull);
    });

    test('blank text never sends', () {
      final c = TimelineController([], you: _you);
      c.send('   ');
      expect(c.messages, isEmpty);
    });

    test('saving an edit replaces the text and marks it edited', () {
      final mine = _msg('1', _you);
      final c = TimelineController([mine], you: _you);

      c.startEdit(mine);
      c.saveEdit('1', 'a better crumb');

      expect(c.messages.single.body, 'a better crumb');
      expect(c.messages.single.edited, isTrue);
      expect(c.target, isNull);
    });

    test('an unchanged edit is not marked edited', () {
      final mine = _msg('1', _you);
      final c = TimelineController([mine], you: _you);

      c.startEdit(mine);
      c.saveEdit('1', mine.body);

      expect(c.messages.single.edited, isFalse);
      expect(c.target, isNull);
    });
  });
}
