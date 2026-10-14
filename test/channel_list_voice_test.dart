import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/call/call_tile.dart';
import 'package:loaf_native/ui/members/person_card.dart';
import 'package:loaf_native/ui/mock/mock_audio_devices.dart';
import 'package:loaf_native/ui/model/models.dart';
import 'package:loaf_native/ui/settings/voice_settings.dart';
import 'package:loaf_native/ui/shell/channel_list.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/widgets/speaking_ring.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

const _you = Member('@you:loaf.test', 'you', Color(0xFF888888));
const _ada = Member('@ada:loaf.test', 'ada', Color(0xFF884422));
const _bo = Member('@bo:loaf.test', 'bo', Color(0xFF228844));

/// A moderator, and the oven where you are one too.
const _mo = Member('@mo:loaf.test', 'mo', Color(0xFF224488), powerLevel: 50);
const _moderated = Space(
  id: '!bakery',
  name: 'Bakery',
  color: Color(0xFF884422),
  categories: [
    ChannelCategory('voice', [
      Channel(
        id: '!oven',
        name: 'oven',
        kind: ChannelKind.voice,
        occupants: [_you, _ada, _mo],
        kickBelow: 50,
      ),
    ]),
  ],
);

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

const _computer = TargetPlatformVariant({TargetPlatform.linux});
const _phone = TargetPlatformVariant({TargetPlatform.iOS});

/// The list while you are in the oven's call with [people] as they are, or
/// in no call; under [voice] when the app has voice settings.
Future<void> _pump(
  WidgetTester tester, {
  List<TileInfo>? people,
  VoiceController? voice,
  Space space = _space,
  void Function(Channel channel, Member member)? onKick,
  void Function(Channel channel, Member member, CallSilence? silence)?
  onSilence,
}) async {
  tester.view.physicalSize = const Size(400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final Widget app = MaterialApp(
    theme: loafLightTheme(),
    home: Scaffold(
      body: ChannelList(
        space: space,
        selectedChannelId: '',
        onSelect: (_) {},
        myId: _you.id,
        onKick: onKick,
        onSilence: onSilence,
        call: people == null ? null : (channelId: '!oven', people: people),
      ),
    ),
  );
  await tester.pumpWidget(
    voice == null ? app : VoiceScope(controller: voice, child: app),
  );
  await tester.pumpAndSettle();
}

VoiceController _voice({VoiceSettings saved = const VoiceSettings()}) {
  final voice = VoiceController(
    store: MemoryVoiceStore(),
    devices: MemoryAudioDevices(),
    settings: saved,
  );
  addTearDown(voice.dispose);
  return voice;
}

Future<void> _rightClick(WidgetTester tester, Finder row) async {
  await tester.tap(row, buttons: kSecondaryButton);
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

  group("a moderator's silence", () {
    Space silenced(Map<String, CallSilence> who, {bool canSilence = false}) =>
        Space(
          id: '!bakery',
          name: 'Bakery',
          color: const Color(0xFF884422),
          categories: [
            ChannelCategory('voice', [
              Channel(
                id: '!oven',
                name: 'oven',
                kind: ChannelKind.voice,
                occupants: const [_you, _ada, _bo],
                silenced: who,
                canSilence: canSilence,
              ),
            ]),
          ],
        );

    Color? iconColor(WidgetTester tester, Finder icon) =>
        tester.widget<Icon>(icon).color;

    testWidgets('shows a struck microphone on someone muted, in a channel '
        'you are not in', (tester) async {
      await _pump(tester, space: silenced({_ada.id: CallSilence.muted}));

      expect(_icon('!oven', _ada, LucideIcons.micOff), findsOneWidget);
      expect(_icon('!oven', _bo, LucideIcons.micOff), findsNothing);
    });

    testWidgets('shows struck headphones on someone deafened', (tester) async {
      await _pump(tester, space: silenced({_ada.id: CallSilence.deafened}));

      expect(_icon('!oven', _ada, LucideIcons.headphoneOff), findsOneWidget);
      expect(_icon('!oven', _ada, LucideIcons.micOff), findsNothing);
    });

    testWidgets('is drawn apart from muting yourself', (tester) async {
      await _pump(
        tester,
        space: silenced({_ada.id: CallSilence.muted}),
        people: const [
          TileInfo(_you, you: true),
          TileInfo(_ada, muted: true),
          TileInfo(_bo, muted: true),
        ],
      );

      final theirs = iconColor(
        tester,
        _icon('!oven', _ada, LucideIcons.micOff),
      );
      final own = iconColor(tester, _icon('!oven', _bo, LucideIcons.micOff));
      expect(theirs, isNot(own));
    });

    testWidgets('is said aloud as a moderator\'s', (tester) async {
      final semantics = tester.ensureSemantics();
      await _pump(
        tester,
        space: silenced({
          _ada.id: CallSilence.muted,
          _bo.id: CallSilence.deafened,
        }),
      );

      String said(Member member) =>
          tester.getSemantics(_row('!oven', member)).label;
      expect(said(_ada), 'ada, muted by a moderator');
      expect(said(_bo), 'bo, deafened by a moderator');
      semantics.dispose();
    });

    group('from the menu', () {
      Future<List<(String, String, CallSilence?)>> open(
        WidgetTester tester,
        Map<String, CallSilence> who, {
        Member on = _ada,
        bool canSilence = true,
        bool wired = true,
      }) async {
        final asked = <(String, String, CallSilence?)>[];
        await _pump(
          tester,
          space: silenced(who, canSilence: canSilence),
          onSilence: wired
              ? (channel, member, silence) =>
                    asked.add((channel.id, member.id, silence))
              : null,
        );
        await _rightClick(tester, _row('!oven', on));
        return asked;
      }

      testWidgets(
        'offers muting and deafening someone left alone',
        variant: _computer,
        (tester) async {
          await open(tester, const {});

          expect(find.text('mute for everyone'), findsOneWidget);
          expect(find.text('deafen for everyone'), findsOneWidget);
        },
      );

      testWidgets('leads with their card', variant: _computer, (tester) async {
        await open(tester, const {});
        expect(find.byType(PersonCard), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(PersonCard),
            matching: find.text(_ada.id),
          ),
          findsOneWidget,
        );
      });

      testWidgets(
        'offers unmuting, and deafening, someone muted',
        variant: _computer,
        (tester) async {
          await open(tester, {_ada.id: CallSilence.muted});

          expect(find.text('unmute for everyone'), findsOneWidget);
          expect(find.text('deafen for everyone'), findsOneWidget);
          expect(find.text('mute for everyone'), findsNothing);
        },
      );

      testWidgets(
        'offers undeafening someone deafened, and nothing else',
        variant: _computer,
        (tester) async {
          await open(tester, {_ada.id: CallSilence.deafened});

          expect(find.text('undeafen for everyone'), findsOneWidget);
          expect(find.text('mute for everyone'), findsNothing);
          expect(find.text('unmute for everyone'), findsNothing);
          expect(find.text('deafen for everyone'), findsNothing);
        },
      );

      testWidgets('offers nothing where you may not', variant: _computer, (
        tester,
      ) async {
        await open(tester, const {}, canSilence: false);

        expect(find.text('mute for everyone'), findsNothing);
      });

      testWidgets(
        'offers nothing where the app does none of it',
        variant: _computer,
        (tester) async {
          await open(tester, const {}, wired: false);

          expect(find.text('mute for everyone'), findsNothing);
        },
      );

      testWidgets('offers nothing on your own row', variant: _computer, (
        tester,
      ) async {
        await open(tester, const {}, on: _you);

        expect(find.text('mute for everyone'), findsNothing);
      });

      final choices = <String, (Map<String, CallSilence>, CallSilence?)>{
        'mute for everyone': (const {}, CallSilence.muted),
        'deafen for everyone': (const {}, CallSilence.deafened),
        'unmute for everyone': ({_ada.id: CallSilence.muted}, null),
        'undeafen for everyone': ({_ada.id: CallSilence.deafened}, null),
      };
      for (final MapEntry(key: label, value: (who, wanted))
          in choices.entries) {
        testWidgets(
          '"$label" asks for that, of them, there',
          variant: _computer,
          (tester) async {
            final asked = await open(tester, who);

            await tester.tap(find.text(label));
            await tester.pumpAndSettle();

            expect(asked, [('!oven', _ada.id, wanted)]);
          },
        );
      }
    });
  });

  group('kicking, from the menu on someone listed,', () {
    testWidgets('is offered for someone below your level', variant: _computer, (
      tester,
    ) async {
      await _pump(tester, space: _moderated, onKick: (_, _) {});

      await _rightClick(tester, _row('!oven', _ada));

      expect(find.text('kick from oven'), findsOneWidget);
    });

    testWidgets(
      'is not offered for someone at your level',
      variant: _computer,
      (tester) async {
        await _pump(
          tester,
          space: _moderated,
          voice: _voice(),
          onKick: (_, _) {},
        );

        await _rightClick(tester, _row('!oven', _mo));

        expect(find.byType(Slider), findsOneWidget);
        expect(find.text('kick from oven'), findsNothing);
      },
    );

    testWidgets(
      'is not offered where the channel gives you no kick',
      variant: _computer,
      (tester) async {
        await _pump(tester, voice: _voice(), onKick: (_, _) {});

        await _rightClick(tester, _row('!oven', _ada));

        expect(find.byType(Slider), findsOneWidget);
        expect(find.text('kick from oven'), findsNothing);
      },
    );

    testWidgets(
      'is not offered where the app does no kicking',
      variant: _computer,
      (tester) async {
        await _pump(tester, space: _moderated, voice: _voice());

        await _rightClick(tester, _row('!oven', _ada));

        expect(find.text('kick from oven'), findsNothing);
      },
    );

    testWidgets('is not offered on your own row', variant: _computer, (
      tester,
    ) async {
      await _pump(tester, space: _moderated, onKick: (_, _) {});

      await _rightClick(tester, _row('!oven', _you));

      expect(find.text('kick from oven'), findsNothing);
    });

    testWidgets(
      'sits under their volume where there is one',
      variant: _computer,
      (tester) async {
        await _pump(
          tester,
          space: _moderated,
          voice: _voice(),
          onKick: (_, _) {},
        );

        await _rightClick(tester, _row('!oven', _ada));

        expect(find.byType(Slider), findsOneWidget);
        expect(find.text('kick from oven'), findsOneWidget);
      },
    );

    testWidgets('when chosen, says which channel and who', variant: _computer, (
      tester,
    ) async {
      final kicked = <(String, String)>[];
      await _pump(
        tester,
        space: _moderated,
        onKick: (channel, member) => kicked.add((channel.id, member.id)),
      );
      await _rightClick(tester, _row('!oven', _ada));

      await tester.tap(find.text('kick from oven'));
      await tester.pumpAndSettle();

      expect(kicked, [('!oven', _ada.id)]);
    });

    testWidgets('is not done by closing the menu', variant: _computer, (
      tester,
    ) async {
      final kicked = <(String, String)>[];
      await _pump(
        tester,
        space: _moderated,
        onKick: (channel, member) => kicked.add((channel.id, member.id)),
      );
      await _rightClick(tester, _row('!oven', _ada));

      await tester.tapAt(const Offset(390, 890));
      await tester.pumpAndSettle();

      expect(kicked, isEmpty);
    });

    testWidgets('is offered on a long press on a phone', variant: _phone, (
      tester,
    ) async {
      await _pump(tester, space: _moderated, onKick: (_, _) {});

      await tester.longPress(_row('!oven', _ada));
      await tester.pumpAndSettle();

      expect(find.text('kick from oven'), findsOneWidget);
    });
  });

  group('the menu on someone listed', () {
    testWidgets(
      'opens on a right-click, with their volume where it was '
      'set',
      variant: _computer,
      (tester) async {
        await _pump(
          tester,
          voice: _voice(saved: VoiceSettings(volumes: {_ada.id: 0.5})),
        );

        await _rightClick(tester, _row('!oven', _ada));

        expect(tester.widget<Slider>(find.byType(Slider)).value, 0.5);
      },
    );

    testWidgets('says whose it is', variant: _computer, (tester) async {
      await _pump(tester, voice: _voice());

      await _rightClick(tester, _row('!oven', _bo));

      // Once in the row, once heading the menu.
      expect(find.text('bo'), findsNWidgets(2));
    });

    testWidgets('sets their volume when dragged', variant: _computer, (
      tester,
    ) async {
      final voice = _voice();
      await _pump(tester, voice: voice);
      await _rightClick(tester, _row('!oven', _ada));

      await tester.drag(find.byType(Slider), const Offset(-60, 0));
      await tester.pumpAndSettle();

      expect(voice.volumeOf(_ada.id), lessThan(1));
      expect(voice.volumeOf(_bo.id), 1);
    });

    testWidgets('does not open on yourself', variant: _computer, (
      tester,
    ) async {
      await _pump(tester, voice: _voice());

      await _rightClick(tester, _row('!oven', _you));

      expect(find.byType(Slider), findsNothing);
    });

    testWidgets(
      'does not open where the app keeps no voice settings',
      variant: _computer,
      (tester) async {
        await _pump(tester);

        await _rightClick(tester, _row('!oven', _ada));

        expect(find.byType(Slider), findsNothing);
      },
    );

    testWidgets(
      'opens for someone in a voice channel you are not in',
      variant: _computer,
      (tester) async {
        await _pump(tester, voice: _voice());

        await _rightClick(tester, _row('!kiln', _ada));

        expect(find.byType(Slider), findsOneWidget);
      },
    );

    testWidgets('of a name and a slider has no divider', variant: _computer, (
      tester,
    ) async {
      await _pump(tester, voice: _voice());

      await _rightClick(tester, _row('!oven', _ada));

      expect(find.byType(PopupMenuDivider), findsNothing);
    });

    testWidgets('is offered to a screen reader, but not on your own row', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await _pump(tester, voice: _voice());

      bool offered(Member member) => tester
          .getSemantics(_row('!oven', member))
          .getSemanticsData()
          .hasAction(SemanticsAction.longPress);
      expect(offered(_ada), isTrue);
      expect(offered(_you), isFalse);
      semantics.dispose();
    });

    testWidgets('opens on a long press on a phone', variant: _phone, (
      tester,
    ) async {
      await _pump(tester, voice: _voice());

      await tester.longPress(_row('!oven', _ada));
      await tester.pumpAndSettle();

      expect(find.byType(Slider), findsOneWidget);
    });
  });
}
