import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/channel/mentions.dart';
import 'package:loaf_native/ui/model/models.dart';

TextEditingValue _at(String text) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: text.length),
);

const _ada = Member('@ada:loaf.moe', 'Ada Lovelace', Color(0xFF000000));
const _adam = Member('@adam:loaf.moe', 'Adam', Color(0xFF000000));
const _sam = Member('@sourdough:loaf.moe', 'Sam', Color(0xFF000000));
const _kitchen = Channel(id: '!kitchen:loaf.moe', name: 'kitchen');

const _adaMention = Mention(
  kind: MentionKind.person,
  id: '@ada:loaf.moe',
  label: '@Ada Lovelace',
);
const _kitchenMention = Mention(
  kind: MentionKind.channel,
  id: '!kitchen:loaf.moe',
  label: '#kitchen',
);

void main() {
  group('mentionAt', () {
    test('a sigil at the start of a word starts one, even alone', () {
      expect(mentionAt(_at('@')), (
        start: 0,
        kind: MentionKind.person,
        query: '',
      ));
      expect(mentionAt(_at('hi #kit')), (
        start: 3,
        kind: MentionKind.channel,
        query: 'kit',
      ));
      expect(mentionAt(_at('(@ad')), (
        start: 1,
        kind: MentionKind.person,
        query: 'ad',
      ));
    });

    test('mid-word, or after a space, is not one', () {
      expect(mentionAt(_at('me@loaf.moe')), isNull);
      expect(mentionAt(_at('C#')), isNull);
      expect(mentionAt(_at('@ada ')), isNull);
      expect(mentionAt(_at('# heading')), isNull);
    });

    test('a selection is not typing', () {
      const value = TextEditingValue(
        text: '@ad',
        selection: TextSelection(baseOffset: 0, extentOffset: 3),
      );
      expect(mentionAt(value), isNull);
    });
  });

  group('searchMentions', () {
    final people = [
      for (final m in [_sam, _adam, _ada]) MentionCandidate.person(m),
    ];

    test('nothing typed yet lists them in the order given', () {
      expect(searchMentions('', people).map((c) => c.name), [
        'Sam',
        'Adam',
        'Ada Lovelace',
      ]);
    });

    test('names it starts come first, then later words, then user ids', () {
      expect(searchMentions('ad', people).map((c) => c.name), [
        'Adam',
        'Ada Lovelace',
      ]);
      expect(searchMentions('love', people).single.name, 'Ada Lovelace');
      expect(searchMentions('sour', people).single.name, 'Sam');
      expect(searchMentions('ADA', people).first.name, 'Adam');
    });

    test('channels match by name', () {
      expect(
        searchMentions('kit', [const MentionCandidate.channel(_kitchen)]).single
            .label,
        '#kitchen',
      );
    });
  });

  group('linkMentions', () {
    test('each mention becomes a link to its permalink', () {
      expect(
        linkMentions('hey @Ada Lovelace, see #kitchen', [
          _adaMention,
          _kitchenMention,
        ]),
        'hey [@Ada Lovelace](https://matrix.to/#/@ada:loaf.moe), see '
        '[#kitchen](https://matrix.to/#/!kitchen:loaf.moe)',
      );
    });

    test('code, and a label running on into a word, are left alone', () {
      expect(
        linkMentions('`#kitchen` #kitchens', [_kitchenMention]),
        '`#kitchen` #kitchens',
      );
    });

    test('brackets in a name do not break the link', () {
      const odd = Mention(
        kind: MentionKind.person,
        id: '@x:loaf.moe',
        label: '@[x]',
      );
      expect(
        linkMentions('@[x]', [odd]),
        r'[@\[x\]](https://matrix.to/#/@x:loaf.moe)',
      );
    });
  });

  test('mentionsIn keeps only what the text still holds, once each', () {
    expect(
      mentionsIn('hi @Ada Lovelace @Ada Lovelace', [
        _adaMention,
        _kitchenMention,
        _adaMention,
      ]),
      [_adaMention],
    );
  });

  test('mentionedUserIds tells people, not rooms', () {
    expect(mentionedUserIds([_adaMention, _kitchenMention]), [
      '@ada:loaf.moe',
    ]);
  });

  test('mentionsOf reads a sent message\'s mentions back for an edit', () {
    final message = Message(
      id: r'$1',
      author: _ada,
      sentAt: DateTime.utc(2026),
      body: 'hey @Ada Lovelace, see #kitchen',
      formatted:
          'hey <a href="https://matrix.to/#/@ada:loaf.moe">@Ada Lovelace</a>'
          ', see <a href="https://matrix.to/#/!kitchen:loaf.moe">#kitchen</a> '
          '<a href="https://matrix.to/#/!kitchen:loaf.moe/\$e">a message</a>',
    );
    expect(mentionsOf(message), [_adaMention, _kitchenMention]);
  });
}
