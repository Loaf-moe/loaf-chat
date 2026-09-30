import 'package:flutter_test/flutter_test.dart';

import '../tool/gen_emoji.dart';

const _sample = '''
# group: Smileys & Emotion

# subgroup: face-smiling
1F600                                                  ; fully-qualified     # 😀 E1.0 grinning face
263A FE0F                                              ; fully-qualified     # ☺️ E0.6 smiling face
263A                                                   ; unqualified         # ☺ E0.6 smiling face

# group: People & Body

# subgroup: hand-fingers-open
1F44B                                                  ; fully-qualified     # 👋 E0.6 waving hand
1F44B 1F3FB                                            ; fully-qualified     # 👋🏻 E1.0 waving hand: light skin tone

# group: Component

1F3FB                                                  ; component           # 🏻 E1.0 light skin tone

# group: Food & Drink

1F956                                                  ; fully-qualified     # 🥖 E3.0 baguette bread
1FAE9                                                  ; fully-qualified     # 🫩 E99.0 face from the future
''';

void main() {
  final groups = parseEmojiTest(_sample, maxVersion: 17.0);

  test('keeps the groups in order, without Component', () {
    expect(groups.map((g) => g.name), [
      'Smileys & Emotion',
      'People & Body',
      'Food & Drink',
    ]);
  });

  test('keeps fully-qualified emoji only, with their names', () {
    expect(groups.first.emoji.map((e) => (e.char, e.name)), [
      ('😀', 'grinning face'),
      ('☺️', 'smiling face'),
    ]);
  });

  test('leaves skin-tone variants for later', () {
    expect(groups[1].emoji.map((e) => e.char), ['👋']);
  });

  test("drops emoji newer than the platforms' fonts", () {
    expect(groups.last.emoji.map((e) => e.name), ['baguette bread']);
  });

  test('writes a Dart table', () {
    final dart = renderEmojiTable(groups);

    expect(dart, contains("EmojiGroup('Food & Drink'"));
    expect(dart, contains("Emoji('🥖', 'baguette bread')"));
    expect(dart, contains('GENERATED'));
  });

  group('shortcodes', () {
    List<ParsedGroup> attached(Map<String, String> github) {
      final fresh = parseEmojiTest(_sample, maxVersion: 17.0);
      attachShortcodes(fresh, github);
      return fresh;
    }

    List<String> codesOf(List<ParsedGroup> groups, String char) => groups
        .expand((g) => g.emoji)
        .firstWhere((e) => e.char == char)
        .shortcodes;

    test("GitHub's names first, then one from the CLDR name", () {
      final groups = attached({'grinning': '😀', 'wave': '👋'});
      expect(codesOf(groups, '😀'), ['grinning', 'grinning_face']);
      expect(codesOf(groups, '👋'), ['wave', 'waving_hand']);
      expect(codesOf(groups, '🥖'), ['baguette_bread']);
    });

    test('matches GitHub emoji written without the variation selector', () {
      final groups = attached({'relaxed': '☺'});
      expect(codesOf(groups, '☺️'), ['relaxed', 'smiling_face']);
    });

    test('drops GitHub names for emoji the picker does not have', () {
      final groups = attached({'future': '🫩'});
      expect(
        groups.expand((g) => g.emoji).expand((e) => e.shortcodes),
        isNot(contains('future')),
      );
    });

    test('a CLDR code GitHub already uses, or two names share, is left '
        'out', () {
      // GitHub gives "grinning_face" to the wave: the grin keeps only its
      // own GitHub name.
      final groups = attached({'grin': '😀', 'grinning_face': '👋'});
      expect(codesOf(groups, '😀'), ['grin']);
      expect(cldrShortcode('keycap: *'), cldrShortcode('keycap: #'));
    });

    test('CLDR names become lower snake case', () {
      expect(cldrShortcode('flag: Japan'), 'flag_japan');
      expect(
        cldrShortcode('smiling face with heart-eyes'),
        'smiling_face_with_heart_eyes',
      );
      expect(cldrShortcode("man’s shoe"), 'mans_shoe');
    });

    test('are written into the table', () {
      final dart = renderEmojiTable(attached({'grinning': '😀'}));
      expect(
        dart,
        contains("Emoji('😀', 'grinning face', ['grinning', 'grinning_face'])"),
      );
    });
  });
}
