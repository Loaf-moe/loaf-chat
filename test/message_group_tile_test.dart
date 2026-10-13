import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/channel/link_preview_card.dart';
import 'package:loaf_native/ui/channel/message_group_tile.dart';
import 'package:loaf_native/ui/members/role_colors.dart';
import 'package:loaf_native/ui/mock/fixtures.dart';
import 'package:loaf_native/ui/model/link_previews.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

class _Ready implements LinkPreviews {
  final _state = ValueNotifier<LinkPreviewState>(
    LinkPreviewReady(LinkPreview.of(title: 'Bake day')!),
  );

  @override
  ValueListenable<LinkPreviewState> of(Uri link) => _state;
}

Future<void> _pumpMessage(WidgetTester tester, {Uri? previewLink}) =>
    tester.pumpWidget(
      MaterialApp(
        theme: loafDarkTheme(),
        home: LinkPreviewsScope(
          previews: _Ready(),
          child: Scaffold(
            body: MessageGroupTile(
              group: MessageGroup([
                Message(
                  id: '1',
                  author: const Member('@x', 'Pat Rye', Color(0xFF00FF00)),
                  sentAt: DateTime(2026, 9, 24, 10),
                  body: 'read this',
                  reactions: const [Reaction('🍞', 2)],
                  previewLink: previewLink,
                ),
              ]),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('a link\'s preview sits between the words and the reactions', (
    tester,
  ) async {
    await _pumpMessage(tester, previewLink: Uri.parse('https://loaf.moe/bake'));
    final card = tester.getRect(find.byKey(LinkPreviewCard.cardKey));
    expect(
      card.top,
      greaterThanOrEqualTo(tester.getBottomLeft(find.text('read this')).dy),
    );
    expect(
      card.bottom,
      lessThanOrEqualTo(tester.getTopLeft(find.text('🍞 2')).dy),
    );
  });

  testWidgets('a file with a link in its caption draws both', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: loafDarkTheme(),
        home: LinkPreviewsScope(
          previews: _Ready(),
          child: Scaffold(
            body: MessageGroupTile(
              group: MessageGroup([
                Message(
                  id: '1',
                  author: const Member('@x', 'Pat Rye', Color(0xFF00FF00)),
                  sentAt: DateTime(2026, 9, 24, 10),
                  body: 'from https://loaf.moe/bake',
                  media: const Media(
                    kind: MediaKind.file,
                    name: 'recipe.pdf',
                    ref: 'recipe',
                  ),
                  previewLink: Uri.parse('https://loaf.moe/bake'),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('recipe.pdf'), findsOneWidget);
    expect(find.byKey(LinkPreviewCard.cardKey), findsOneWidget);
  });

  testWidgets('a message that offers no link has no preview', (tester) async {
    await _pumpMessage(tester);
    expect(find.byType(LinkPreviewCard), findsNothing);
  });

  // Name colour means power level everywhere — see "Name colour" in the
  // design spec. The per-member colour is only an avatar fallback.
  for (final (label, powerLevel, role) in [
    ('admin', 100, Role.admin),
    ('moderator', 50, Role.moderator),
    ('member', 0, Role.member),
  ]) {
    testWidgets('a $label\'s name in the timeline wears the $label colour', (
      tester,
    ) async {
      final author = Member(
        '@x',
        'Pat Rye',
        const Color(0xFF00FF00),
        powerLevel: powerLevel,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: loafDarkTheme(),
          home: Scaffold(
            body: MessageGroupTile(
              group: MessageGroup([
                Message(
                  id: '1',
                  author: author,
                  sentAt: DateTime(2026, 9, 24, 10),
                  body: 'hello',
                ),
              ]),
            ),
          ),
        ),
      );

      final tokens = loafDarkTheme().extension<LoafTokens>()!;
      final name = tester.widget<Text>(find.text('Pat Rye'));
      expect(name.style?.color, tokens.nameColor(role));
      expect(
        name.style?.color,
        isNot(author.color),
        reason: 'the avatar colour must not leak into the name',
      );
    });
  }
}
