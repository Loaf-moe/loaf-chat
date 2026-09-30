import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/emoji/emoji.dart';
import 'package:loaf_native/ui/emoji/shortcodes.dart';

final _index = ShortcodeIndex(const [
  EmojiGroup('Smileys & Emotion', [
    Emoji('😄', 'grinning face with smiling eyes', [
      'smile',
      'grinning_face_with_smiling_eyes',
    ]),
    Emoji('😃', 'grinning face with big eyes', ['smiley']),
    Emoji('😇', 'smiling face with halo', [
      'innocent',
      'smiling_face_with_halo',
    ]),
    Emoji('😏', 'smirking face', ['smirk']),
    Emoji('🙂', 'slightly smiling face', ['slightly_smiling_face']),
  ]),
  EmojiGroup('People & Body', [
    Emoji('👍', 'thumbs up', ['+1', 'thumbsup']),
  ]),
]);

TextEditingValue _typed(String text, [int? cursor]) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: cursor ?? text.length),
);

void main() {
  group('expand', () {
    test('turns known shortcodes into their emoji', () {
      expect(_index.expand('hi :smile: :+1:'), 'hi 😄 👍');
      expect(_index.expand(':smile::smirk:'), '😄😏');
    });

    test('leaves unknown ones, and times, as written', () {
      expect(_index.expand('at 12:30:45 :nope:'), 'at 12:30:45 :nope:');
    });

    test('leaves code alone', () {
      expect(
        _index.expand('type `:smile:` for :smile:'),
        'type `:smile:` for 😄',
      );
      expect(
        _index.expand('```\n:smile:\n```\n:smile:'),
        '```\n:smile:\n```\n😄',
      );
    });

    test('the real table knows the usual names', () {
      expect(
        shortcodes.expand(':smile: :joy: :thumbsup: :heart:'),
        '😄 😂 👍 ❤️',
      );
      expect(shortcodes['melting_face']?.char, '🫠');
    });
  });

  group('search', () {
    List<String> codes(String q) =>
        _index.search(q).map((m) => m.code).toList();

    test('an exact match, then shortcodes it starts, shortest first', () {
      expect(codes('smi'), [
        'smile',
        'smirk',
        'smiley',
        'smiling_face_with_halo',
        // Where it starts a later word.
        'slightly_smiling_face',
      ]);
    });

    test('then codes where it starts a later word', () {
      expect(codes('smiling').first, 'smiling_face_with_halo');
      expect(codes('smiling'), contains('slightly_smiling_face'));
    });

    test('each emoji once, under its best code', () {
      final matches = _index.search('grinning');
      expect(matches.map((m) => m.emoji.char), ['😄']);
    });

    test('ignores case, and stops at the limit', () {
      expect(codes('SMILE').first, 'smile');
      expect(_index.search('s', limit: 2), hasLength(2));
    });
  });

  group('shortcodeAt', () {
    test('a colon and two letters at the cursor', () {
      expect(shortcodeAt(_typed('hello :sm')), (start: 6, query: 'sm'));
      expect(shortcodeAt(_typed(':Smi')), (start: 0, query: 'smi'));
    });

    test('not yet at one letter, and never for a smiley', () {
      expect(shortcodeAt(_typed('hello :s')), isNull);
      expect(shortcodeAt(_typed('hello :)')), isNull);
    });

    test('not in the middle of a word or a time', () {
      expect(shortcodeAt(_typed('https://example')), isNull);
      expect(shortcodeAt(_typed('at 12:30')), isNull);
    });

    test('not once the code is closed, or the cursor has moved on', () {
      expect(shortcodeAt(_typed('hi :smile:')), isNull);
      expect(shortcodeAt(_typed('hi :smile there', 3)), isNull);
    });

    test('not across a selection', () {
      expect(
        shortcodeAt(
          const TextEditingValue(
            text: ':smile',
            selection: TextSelection(baseOffset: 0, extentOffset: 6),
          ),
        ),
        isNull,
      );
    });
  });
}
