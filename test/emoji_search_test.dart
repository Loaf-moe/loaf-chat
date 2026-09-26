import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/emoji/emoji.dart';

const _groups = [
  EmojiGroup('Food & Drink', [
    Emoji('🍞', 'bread'),
    Emoji('🥖', 'baguette bread'),
    Emoji('🔥', 'fire'),
    Emoji('🫓', 'flatbread'),
  ]),
  EmojiGroup('Smileys & Emotion', [Emoji('😀', 'grinning face')]),
];

void main() {
  group('searchEmoji', () {
    test('matches words in the name, whole words first', () {
      expect(searchEmoji('bread', _groups).map((e) => e.char), [
        '🍞',
        '🥖',
        '🫓',
      ]);
    });

    test('ignores case and surrounding space', () {
      expect(searchEmoji('  FIRE ', _groups).map((e) => e.char), ['🔥']);
    });

    test('an empty search finds nothing', () {
      expect(searchEmoji('', _groups), isEmpty);
    });
  });

  group('EmojiRecents', () {
    test('keeps the newest first, once each, up to a limit', () {
      final recents = EmojiRecents(limit: 3)
        ..use('🍞')
        ..use('🔥')
        ..use('🍞')
        ..use('😀')
        ..use('🥖');

      expect(recents.emoji, ['🥖', '😀', '🍞']);
    });
  });
}
