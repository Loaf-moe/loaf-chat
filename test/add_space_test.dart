import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:loaf_native/ui/model/models.dart';
import 'package:loaf_native/ui/shell/app_shell.dart';
import 'package:loaf_native/ui/shell/channel_list.dart';
import 'package:loaf_native/ui/shell/spaces_rail.dart';
import 'package:loaf_native/ui/rooms/rooms.dart' show PartlyDone;
import 'package:loaf_native/ui/spaces/add_space.dart';
import 'package:loaf_native/ui/spaces/space_directory.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/widgets/loaf_button.dart';

final _mobile = TargetPlatformVariant.only(TargetPlatform.iOS);
final _desktop = TargetPlatformVariant.only(TargetPlatform.macOS);

const _phone = Size(390, 844);
const _wide = Size(1440, 900);

Future<void> _pumpShell(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: loafLightTheme(),
      darkTheme: loafDarkTheme(),
      themeMode: ThemeMode.dark,
      home: const AppShell(),
    ),
  );
  await tester.pumpAndSettle();
  if (size == _phone) {
    await tester.tap(find.byIcon(LucideIcons.menu));
    await tester.pumpAndSettle();
  }
}

Finder _panel() => find.byType(AddSpacePanel);
Finder _inPanel(Finder f) => find.descendant(of: _panel(), matching: f);
Finder _inList(String text) =>
    find.descendant(of: find.byType(ChannelList), matching: find.text(text));
Finder _inRail(String text) =>
    find.descendant(of: find.byType(SpacesRail), matching: find.text(text));

Future<void> _openAdd(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Add a space'));
  await tester.pumpAndSettle();
}

Future<void> _tapIn(WidgetTester tester, String text) async {
  await tester.tap(_inPanel(find.text(text)).first);
  await tester.pumpAndSettle();
}

/// Like [_tapIn], but a single `pump()`: for a tap that leaves a spinner
/// on screen, where `pumpAndSettle` would never return.
Future<void> _tapInNoSettle(WidgetTester tester, String text) async {
  await tester.tap(_inPanel(find.text(text)).first);
  await tester.pump();
}

Future<void> _typeAddress(WidgetTester tester, String address) async {
  await _tapIn(tester, 'join with a link');
  await tester.enterText(_inPanel(find.byType(TextField)), address);
  await tester.pumpAndSettle();
}

const _somePreview = SpacePreview(
  alias: '#test:loaf.moe',
  space: Space(id: 'test-space', name: 'Test Space', color: Colors.blue),
  topic: 'a space for testing',
  memberCount: 1,
);

const _previewA = SpacePreview(
  alias: '#a:loaf.moe',
  space: Space(id: 'space-a', name: 'Space A', color: Colors.blue),
  memberCount: 1,
);

const _previewB = SpacePreview(
  alias: '#b:loaf.moe',
  space: Space(id: 'space-b', name: 'Space B', color: Colors.green),
  memberCount: 2,
);

/// A [SpaceDirectory] whose answers the test drives by hand, one
/// [Completer] per call, so loading, failure and staleness can be observed.
class _SlowDirectory implements SpaceDirectory {
  final publicSpacesCalls = <String>[];
  Completer<List<SpacePreview>>? _publicSpaces;

  final lookUpCalls = <String>[];
  final _lookUps = <String, Completer<SpacePreview>>{};

  @override
  Future<List<SpacePreview>> publicSpaces(String server) {
    publicSpacesCalls.add(server);
    final completer = Completer<List<SpacePreview>>();
    _publicSpaces = completer;
    return completer.future;
  }

  void completePublicSpaces(List<SpacePreview> spaces) =>
      _publicSpaces!.complete(spaces);

  void failPublicSpaces(Object error) => _publicSpaces!.completeError(error);

  @override
  Future<SpacePreview> lookUp(String address) {
    lookUpCalls.add(address);
    final completer = Completer<SpacePreview>();
    _lookUps[address] = completer;
    return completer.future;
  }

  void completeLookUp(String address, SpacePreview preview) =>
      _lookUps[address]!.complete(preview);

  void failLookUp(String address, Object error) =>
      _lookUps[address]!.completeError(error);
}

Future<void> _pumpPanel(
  WidgetTester tester,
  SpaceDirectory directory, {
  Set<String> joined = const {},
  Future<String> Function(String name)? onCreate,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: loafDarkTheme(),
      home: Scaffold(
        body: AddSpacePanel(
          joined: joined,
          directory: directory,
          onCreate: onCreate,
        ),
      ),
    ),
  );
}

LoafButton _button(WidgetTester tester, String label) =>
    tester.widget<LoafButton>(find.widgetWithText(LoafButton, label));

/// Opens [AddSpacePanel] through the real [showAddSpace] route (a dialog on
/// a computer here), so its popped result can be inspected.
class _AddSpaceHost extends StatefulWidget {
  const _AddSpaceHost({required this.directory, this.onCreate});

  final SpaceDirectory directory;
  final Future<String> Function(String name)? onCreate;

  @override
  State<_AddSpaceHost> createState() => _AddSpaceHostState();
}

class _AddSpaceHostState extends State<_AddSpaceHost> {
  AddSpaceResult? result;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        onPressed: () async {
          final r = await showAddSpace(
            context,
            joined: const {},
            directory: widget.directory,
            onCreate: widget.onCreate,
          );
          setState(() => result = r);
        },
        child: const Text('open'),
      ),
    ),
  );
}

Future<void> _openCreateStep(WidgetTester tester, String name) async {
  await tester.tap(find.text('create a space'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), name);
  await tester.pumpAndSettle();
}

void main() {
  group('the add-a-space panel', () {
    testWidgets('is a dialog on a computer', variant: _desktop, (tester) async {
      await _pumpShell(tester, _wide);
      await _openAdd(tester);

      expect(find.byType(Dialog), findsOneWidget);
      for (final path in [
        'join with a link',
        'explore public spaces',
        'create a space',
      ]) {
        expect(_inPanel(find.text(path)), findsOneWidget, reason: path);
      }
    });

    testWidgets('is a sheet on a phone', variant: _mobile, (tester) async {
      await _pumpShell(tester, _phone);
      await _openAdd(tester);

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('each step has a way back', (tester) async {
      await _pumpShell(tester, _wide);
      await _openAdd(tester);

      await _tapIn(tester, 'create a space');
      await tester.tap(_inPanel(find.byTooltip('Back')));
      await tester.pumpAndSettle();

      expect(_inPanel(find.text('explore public spaces')), findsOneWidget);
    });
  });

  group('joining with a link', () {
    testWidgets('previews the space before joining it', (tester) async {
      await _pumpShell(tester, _wide);
      await _openAdd(tester);

      await _typeAddress(tester, '#pizza:loaf.moe');

      expect(_inPanel(find.text('Pizza Night')), findsOneWidget);
      expect(_inPanel(find.text('23 members')), findsOneWidget);
      expect(_inPanel(find.text('dough-balls')), findsOneWidget);

      await _tapIn(tester, 'join');
      expect(_panel(), findsNothing);
      expect(_inRail('PN'), findsOneWidget);
      expect(_inList('Pizza Night'), findsOneWidget);
      expect(
        find.textContaining('who is bringing the good tomatoes'),
        findsOneWidget,
      );
    });

    testWidgets('understands a matrix.to link', (tester) async {
      await _pumpShell(tester, _wide);
      await _openAdd(tester);

      await _typeAddress(tester, 'https://matrix.to/#/%23pizza%3Aloaf.moe');

      expect(_inPanel(find.text('Pizza Night')), findsOneWidget);
    });

    testWidgets('says so when nothing is there', (tester) async {
      await _pumpShell(tester, _wide);
      await _openAdd(tester);

      await _typeAddress(tester, '#nope:loaf.moe');

      expect(_inPanel(find.text('no space at that address')), findsOneWidget);
    });

    testWidgets('an invite-only space offers no join', (tester) async {
      await _pumpShell(tester, _wide);
      await _openAdd(tester);

      await _typeAddress(tester, '#staff:loaf.moe');

      expect(_inPanel(find.textContaining('invite-only')), findsOneWidget);
      expect(_inPanel(find.text('join')), findsNothing);
    });
  });

  group('exploring', () {
    testWidgets("lists the server's public spaces, marking yours", (
      tester,
    ) async {
      await _pumpShell(tester, _wide);
      await _openAdd(tester);
      await _tapIn(tester, 'explore public spaces');

      expect(_inPanel(find.text('Pizza Night')), findsOneWidget);
      expect(_inPanel(find.text('Gluten-Free Crew')), findsOneWidget);
      final starter = find.byKey(const ValueKey('directory-starter'));
      expect(
        find.descendant(of: starter, matching: find.text('joined')),
        findsOneWidget,
      );
    });

    testWidgets(
      "on a phone the keyboard doesn't cover the list on arrival",
      variant: _mobile,
      (tester) async {
        await _pumpShell(tester, _phone);
        await _openAdd(tester);
        await _tapIn(tester, 'explore public spaces');

        final search = tester.state<EditableTextState>(
          _inPanel(find.byType(EditableText)),
        );
        expect(search.widget.focusNode.hasFocus, isFalse);
      },
    );

    testWidgets("a preview doesn't repeat the space's name", (tester) async {
      await _pumpShell(tester, _wide);
      await _openAdd(tester);
      await _tapIn(tester, 'explore public spaces');
      await _tapIn(tester, 'Pizza Night');

      expect(_inPanel(find.text('Pizza Night')), findsOneWidget);
      expect(_inPanel(find.text('explore')), findsOneWidget);
    });

    testWidgets('can look at another server', (tester) async {
      await _pumpShell(tester, _wide);
      await _openAdd(tester);
      await _tapIn(tester, 'explore public spaces');

      await tester.tap(_inPanel(find.text('loaf.moe')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('matrix.org').last);
      await tester.pumpAndSettle();

      expect(_inPanel(find.text('Open Bakers')), findsOneWidget);
      expect(_inPanel(find.text('Pizza Night')), findsNothing);
    });

    testWidgets('joining a space you were invited to clears the invite', (
      tester,
    ) async {
      await _pumpShell(tester, _wide);
      await _openAdd(tester);
      await _tapIn(tester, 'explore public spaces');
      await _tapIn(tester, 'Sourdough Society');
      await _tapIn(tester, 'join');

      expect(_inRail('SS'), findsOneWidget);
      await tester.tap(find.byKey(SpacesRail.homeKey));
      await tester.pumpAndSettle();
      expect(_inList('Sourdough Society'), findsNothing);
      expect(_inList('Rosa Brioche'), findsOneWidget);
    });
  });

  group('creating', () {
    testWidgets('makes a space with #general and a voice channel', (
      tester,
    ) async {
      await _pumpShell(tester, _wide);
      await _openAdd(tester);
      await _tapIn(tester, 'create a space');

      await tester.enterText(_inPanel(find.byType(TextField)), 'Crumb Club');
      await tester.pumpAndSettle();
      expect(_inPanel(find.text('CC')), findsOneWidget, reason: 'live avatar');

      await _tapIn(tester, 'create');

      expect(_inRail('CC'), findsOneWidget);
      expect(_inList('Crumb Club'), findsOneWidget);
      expect(_inList('hangout'), findsOneWidget);
      expect(find.text('Message #general'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(
        find.textContaining('ok that crumb is unreasonable'),
        findsNothing,
        reason: "a new space starts empty, not with another space's chat",
      );
    });

    testWidgets('needs a name', (tester) async {
      await _pumpShell(tester, _wide);
      await _openAdd(tester);
      await _tapIn(tester, 'create a space');

      await _tapIn(tester, 'create');

      expect(_panel(), findsOneWidget, reason: 'nothing to create yet');
    });
  });

  group('creating with the server', () {
    testWidgets('create reads creating and has no cancel while it works', (
      tester,
    ) async {
      final completer = Completer<String>();
      await _pumpPanel(
        tester,
        _SlowDirectory(),
        onCreate: (name) => completer.future,
      );
      await _openCreateStep(tester, 'Crumb Club');

      await tester.tap(find.text('create'));
      await tester.pump();

      expect(find.text('creating…'), findsOneWidget);
      expect(_button(tester, 'creating…').onTap, isNull);
      expect(
        find.byTooltip('Back'),
        findsNothing,
        reason: 'an unstoppable step draws no cancel',
      );

      completer.complete('made-1');
      await tester.pump();
    });

    testWidgets("a create in flight can't be dismissed", (tester) async {
      final completer = Completer<String>();
      await tester.pumpWidget(
        MaterialApp(
          theme: loafDarkTheme(),
          home: _AddSpaceHost(
            directory: _SlowDirectory(),
            onCreate: (name) => completer.future,
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await _openCreateStep(tester, 'Crumb Club');
      await tester.tap(find.text('create'));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_panel(), findsOneWidget, reason: 'escape does not cancel');
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(_panel(), findsOneWidget, reason: 'nor does the barrier');
      // The system back gesture asks the route the same way.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_panel(), findsOneWidget, reason: 'nor does back');

      completer.complete('made-1');
      await tester.pumpAndSettle();
      expect(_panel(), findsNothing);
      final host = tester.state<_AddSpaceHostState>(find.byType(_AddSpaceHost));
      expect((host.result as OpenSpace).id, 'made-1');
    });

    testWidgets("a refused create stays open and says so", (tester) async {
      await _pumpPanel(
        tester,
        _SlowDirectory(),
        onCreate: (name) async => throw Exception('refused'),
      );
      await _openCreateStep(tester, 'Crumb Club');

      await tester.tap(find.text('create'));
      await tester.pumpAndSettle();

      expect(_panel(), findsOneWidget);
      expect(find.text("couldn't create. try again?"), findsOneWidget);
      expect(_button(tester, 'create').onTap, isNotNull);
    });

    testWidgets(
      'a space made without its channels still opens, and says what is missing',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: loafDarkTheme(),
            home: _AddSpaceHost(
              directory: _SlowDirectory(),
              onCreate: (name) async => throw const PartlyDone(
                spaceId: 'made-1',
                missing: ['hangout'],
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await _openCreateStep(tester, 'Crumb Club');

        await tester.tap(find.text('create'));
        await tester.pumpAndSettle();

        expect(_panel(), findsNothing);
        final host = tester.state<_AddSpaceHostState>(
          find.byType(_AddSpaceHost),
        );
        final result = host.result;
        expect(result, isA<OpenSpace>());
        expect((result as OpenSpace).id, 'made-1');
        expect(result.missing, ['hangout']);
      },
    );
  });

  group('the directory', () {
    testWidgets('explore shows a loading row until the directory answers', (
      tester,
    ) async {
      final directory = _SlowDirectory();
      await _pumpPanel(tester, directory);
      await _tapInNoSettle(tester, 'explore public spaces');

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(_inPanel(find.text('Test Space')), findsNothing);

      directory.completePublicSpaces([_somePreview]);
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(_inPanel(find.text('Test Space')), findsOneWidget);
    });

    testWidgets("explore says so when a server can't be reached", (
      tester,
    ) async {
      final directory = _SlowDirectory();
      await _pumpPanel(tester, directory);
      await _tapInNoSettle(tester, 'explore public spaces');

      directory.failPublicSpaces(Exception('offline'));
      await tester.pump();

      expect(
        _inPanel(find.text("couldn't reach loaf.moe. try again?")),
        findsOneWidget,
      );

      await tester.tap(
        _inPanel(find.text("couldn't reach loaf.moe. try again?")),
      );
      await tester.pump();

      expect(directory.publicSpacesCalls, ['loaf.moe', 'loaf.moe']);
    });

    testWidgets('only a complete address is looked up', (tester) async {
      final directory = _SlowDirectory();
      await _pumpPanel(tester, directory);
      await _tapIn(tester, 'join with a link');

      await tester.enterText(_inPanel(find.byType(TextField)), '#bak');
      await tester.pump();
      expect(directory.lookUpCalls, isEmpty);

      await tester.enterText(
        _inPanel(find.byType(TextField)),
        '#bakers:loaf.moe',
      );
      await tester.pump();
      expect(directory.lookUpCalls, ['#bakers:loaf.moe']);
    });

    testWidgets("a stale lookup's answer is dropped", (tester) async {
      final directory = _SlowDirectory();
      await _pumpPanel(tester, directory);
      await _tapIn(tester, 'join with a link');

      await tester.enterText(_inPanel(find.byType(TextField)), '#a:loaf.moe');
      await tester.pump();
      await tester.enterText(_inPanel(find.byType(TextField)), '#b:loaf.moe');
      await tester.pump();
      expect(directory.lookUpCalls, ['#a:loaf.moe', '#b:loaf.moe']);

      directory.completeLookUp('#a:loaf.moe', _previewA);
      await tester.pump();
      expect(_inPanel(find.text('Space A')), findsNothing);

      directory.completeLookUp('#b:loaf.moe', _previewB);
      await tester.pump();
      expect(_inPanel(find.text('Space B')), findsOneWidget);
    });

    testWidgets("a link that can't be reached says so, apart from not found", (
      tester,
    ) async {
      final directory = _SlowDirectory();
      await _pumpPanel(tester, directory);
      await _tapIn(tester, 'join with a link');

      await tester.enterText(
        _inPanel(find.byType(TextField)),
        '#test:loaf.moe',
      );
      await tester.pump();

      directory.failLookUp('#test:loaf.moe', Exception('offline'));
      await tester.pump();

      expect(
        _inPanel(find.text("couldn't reach that server. try again?")),
        findsOneWidget,
      );
    });
  });
}
