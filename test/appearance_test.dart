import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/theme/appearance.dart';

class _BrokenStore implements AppearanceStore {
  @override
  Future<AppearanceSettings?> load() async => null;
  @override
  Future<void> save(AppearanceSettings settings) =>
      Future.error(const FileSystemException('read-only'));
}

void main() {
  group('inNihonSeason', () {
    test('opens at the start of Oct 16 and closes after Nov 6', () {
      expect(inNihonSeason(DateTime(2026, 10, 15, 23, 59)), isFalse);
      expect(inNihonSeason(DateTime(2026, 10, 16)), isTrue);
      expect(inNihonSeason(DateTime(2026, 11, 6, 23, 59)), isTrue);
      expect(inNihonSeason(DateTime(2026, 11, 7)), isFalse);
    });

    test('comes back every year', () {
      expect(inNihonSeason(DateTime(2031, 10, 30)), isTrue);
      expect(inNihonSeason(DateTime(2031, 3, 1)), isFalse);
    });
  });

  group('AppearanceController', () {
    AppearanceController make({
      required DateTime now,
      AppearanceSettings settings = const AppearanceSettings(),
      AppearanceStore? store,
    }) {
      final c = AppearanceController(
        store: store ?? MemoryAppearanceStore(),
        settings: settings,
        clock: () => now,
      );
      addTearDown(c.dispose);
      return c;
    }

    final inSeason = DateTime(2026, 10, 20);
    final offSeason = DateTime(2026, 12, 1);

    test('defaults to Loaf Dark with easter eggs on', () {
      final c = make(now: offSeason);
      expect(c.chosen, LoafThemeId.loafDark);
      expect(c.easterEggs, isTrue);
      expect(c.effective, LoafThemeId.loafDark);
      expect(c.seasonOverrides, isFalse);
    });

    test('the season wins over the pick while easter eggs are on', () {
      final c = make(now: inSeason);
      expect(c.effective, LoafThemeId.nihon);
      expect(c.seasonOverrides, isTrue);
    });

    test('with easter eggs off, the pick applies in season', () {
      final c = make(
        now: inSeason,
        settings: const AppearanceSettings(easterEggs: false),
      );
      expect(c.effective, LoafThemeId.loafDark);
      expect(c.seasonOverrides, isFalse);
    });

    test('picking 日本 in season is not an override', () {
      final c = make(now: inSeason);
      c.choose(LoafThemeId.nihon);
      expect(c.seasonOverrides, isFalse);
    });

    test('changes notify and save', () async {
      final store = MemoryAppearanceStore();
      final c = make(now: offSeason, store: store);
      var heard = 0;
      c.addListener(() => heard++);

      c.choose(LoafThemeId.nihon);
      c.setEasterEggs(false);
      await Future<void>.delayed(Duration.zero);

      expect(heard, 2);
      expect(c.effective, LoafThemeId.nihon);
      expect(store.saved?.theme, LoafThemeId.nihon);
      expect(store.saved?.easterEggs, isFalse);
    });

    test('choosing what is already chosen changes nothing', () {
      final c = make(now: offSeason);
      var heard = 0;
      c.addListener(() => heard++);
      c.choose(LoafThemeId.loafDark);
      c.setEasterEggs(true);
      expect(heard, 0);
    });

    test('a store that cannot save still applies the pick', () async {
      final c = make(now: offSeason, store: _BrokenStore());
      c.choose(LoafThemeId.nihon);
      await Future<void>.delayed(Duration.zero);
      expect(c.effective, LoafThemeId.nihon);
    });

    test('load restores what was saved', () async {
      final c = await AppearanceController.load(
        MemoryAppearanceStore(
          const AppearanceSettings(theme: LoafThemeId.nihon, easterEggs: false),
        ),
        clock: () => offSeason,
      );
      addTearDown(c.dispose);
      expect(c.chosen, LoafThemeId.nihon);
      expect(c.easterEggs, isFalse);
    });
  });

  testWidgets('an app left open crosses into the season at midnight', (
    tester,
  ) async {
    var now = DateTime(2026, 10, 15, 23);
    final c = AppearanceController(
      store: MemoryAppearanceStore(),
      clock: () => now,
    );
    var heard = 0;
    c.addListener(() => heard++);
    expect(c.effective, LoafThemeId.loafDark);

    now = DateTime(2026, 10, 16, 0, 0, 1);
    await tester.pump(const Duration(hours: 1));

    expect(heard, 1);
    expect(c.effective, LoafThemeId.nihon);
    c.dispose();
  });

  testWidgets('waking from sleep re-checks the season without a timer tick', (
    tester,
  ) async {
    // Timers don't run while the machine sleeps, so the midnight timer alone
    // can leave a woken laptop on yesterday's theme.
    var now = DateTime(2026, 10, 15, 23);
    final c = AppearanceController(
      store: MemoryAppearanceStore(),
      clock: () => now,
    );
    var heard = 0;
    c.addListener(() => heard++);
    expect(c.effective, LoafThemeId.loafDark);

    now = DateTime(2026, 10, 16, 8);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    expect(heard, 1);
    expect(c.effective, LoafThemeId.nihon);

    // Nothing changed since: resuming again stays quiet.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(heard, 1);
    c.dispose();
  });

  group('FileAppearanceStore', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('appearance'));
    tearDown(() => dir.deleteSync(recursive: true));

    File file() => File('${dir.path}/appearance.json');

    test('round-trips', () async {
      final store = FileAppearanceStore(file());
      await store.save(
        const AppearanceSettings(theme: LoafThemeId.nihon, easterEggs: false),
      );
      final back = await FileAppearanceStore(file()).load();
      expect(back?.theme, LoafThemeId.nihon);
      expect(back?.easterEggs, isFalse);
    });

    test('a missing file loads as nothing', () async {
      expect(await FileAppearanceStore(file()).load(), isNull);
    });

    test('a garbage file loads as nothing', () async {
      file().writeAsStringSync('{not json');
      expect(await FileAppearanceStore(file()).load(), isNull);
    });

    test('unknown or mistyped fields fall back to the defaults', () async {
      file().writeAsStringSync('{"theme": "vaporwave", "easterEggs": "yes"}');
      final back = await FileAppearanceStore(file()).load();
      expect(back?.theme, LoafThemeId.loafDark);
      expect(back?.easterEggs, isTrue);
    });
  });
}
