import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/call/call_tile.dart';
import 'package:loaf_native/ui/model/models.dart';
import 'package:loaf_native/ui/shell/channel_list.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/widgets/speaking_ring.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

const _you = Member('@you:loaf.test', 'you', Color(0xFF888888));
const _ada = Member('@ada:loaf.test', 'ada', Color(0xFF884422));
const _bo = Member('@bo:loaf.test', 'bo', Color(0xFF228844));

/// A space with the oven, which you, ada and bo are in, and the kiln,
/// which ada is in on another device.
const _space = Space(
  id: '!bakery',
  name: 'Bakery',
  color: Color(0xFF884422),
  categories: [
    ChannelCategory('voice', [
      Channel(
        id: '!oven',
        name: 'oven',
        kind: ChannelKind.voice,
        occupants: [_you, _ada, _bo],
      ),
      Channel(
        id: '!kiln',
        name: 'kiln',
        kind: ChannelKind.voice,
        occupants: [_ada],
      ),
    ]),
  ],
);

/// The list while you are in the oven's call with [people] as they are, or
/// in no call.
Future<void> _pump(WidgetTester tester, {List<TileInfo>? people}) async {
  tester.view.physicalSize = const Size(400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: loafLightTheme(),
      home: Scaffold(
        body: ChannelList(
          space: _space,
          selectedChannelId: '',
          onSelect: (_) {},
          call: people == null ? null : (channelId: '!oven', people: people),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// [member]'s row under [channel].
Finder _row(String channel, Member member) =>
    find.byKey(ValueKey('occupant-$channel-${member.id}'));

bool _ringing(WidgetTester tester, String channel, Member member) => tester
    .widget<SpeakingRing>(
      find.descendant(
        of: _row(channel, member),
        matching: find.byType(SpeakingRing),
      ),
    )
    .speaking;

Finder _icon(String channel, Member member, IconData icon) =>
    find.descendant(of: _row(channel, member), matching: find.byIcon(icon));

void main() {
  testWidgets('someone talking in your call has the ring, someone silent '
      'has not', (tester) async {
    await _pump(
      tester,
      people: const [
        TileInfo(_you, you: true),
        TileInfo(_ada, speaking: true),
        TileInfo(_bo),
      ],
    );

    expect(_ringing(tester, '!oven', _ada), isTrue);
    expect(_ringing(tester, '!oven', _bo), isFalse);
  });

  testWidgets('you have the ring while you talk', (tester) async {
    await _pump(
      tester,
      people: const [
        TileInfo(_you, you: true, speaking: true),
        TileInfo(_ada),
        TileInfo(_bo),
      ],
    );

    expect(_ringing(tester, '!oven', _you), isTrue);
  });

  testWidgets('someone muted shows a struck microphone, someone unmuted '
      'does not', (tester) async {
    await _pump(
      tester,
      people: const [
        TileInfo(_you, you: true),
        TileInfo(_ada, muted: true),
        TileInfo(_bo),
      ],
    );

    expect(_icon('!oven', _ada, LucideIcons.micOff), findsOneWidget);
    expect(_icon('!oven', _bo, LucideIcons.micOff), findsNothing);
  });

  testWidgets('deafened, you show struck headphones in place of the '
      'microphone', (tester) async {
    await _pump(
      tester,
      people: const [
        TileInfo(_you, you: true, muted: true, deafened: true),
        TileInfo(_ada),
        TileInfo(_bo),
      ],
    );

    expect(_icon('!oven', _you, LucideIcons.headphoneOff), findsOneWidget);
    expect(_icon('!oven', _you, LucideIcons.micOff), findsNothing);
  });

  testWidgets('a voice channel you are not in shows neither, whoever is in '
      'it', (tester) async {
    await _pump(
      tester,
      people: const [
        TileInfo(_you, you: true),
        TileInfo(_ada, muted: true, speaking: true),
        TileInfo(_bo),
      ],
    );

    expect(_ringing(tester, '!kiln', _ada), isFalse);
    expect(_icon('!kiln', _ada, LucideIcons.micOff), findsNothing);
  });

  testWidgets('in no call, nobody has a ring or an icon', (tester) async {
    await _pump(tester);

    expect(_ringing(tester, '!oven', _ada), isFalse);
    expect(find.byIcon(LucideIcons.micOff), findsNothing);
    expect(find.byIcon(LucideIcons.headphoneOff), findsNothing);
  });

  testWidgets('someone in your call the list has no state for is drawn '
      'plain', (tester) async {
    await _pump(tester, people: const [TileInfo(_you, you: true)]);

    expect(_ringing(tester, '!oven', _ada), isFalse);
    expect(_icon('!oven', _ada, LucideIcons.micOff), findsNothing);
  });

  testWidgets('a row says aloud who it is and how they are heard', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      people: const [
        TileInfo(_you, you: true, muted: true, deafened: true),
        TileInfo(_ada, speaking: true),
        TileInfo(_bo, muted: true),
      ],
    );

    String said(Member member) =>
        tester.getSemantics(_row('!oven', member)).label;
    expect(said(_you), 'you, deafened');
    expect(said(_ada), 'ada, speaking');
    expect(said(_bo), 'bo, muted');
    semantics.dispose();
  });
}
