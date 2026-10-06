/// Which theme loaf chat wears: the one picked in settings, unless a season
/// is on and easter eggs are allowed to dress the app up anyway.
///
/// The pick and the flag are saved to a small JSON file beside the account's
/// database, and restored before the first frame so the app never flashes
/// the wrong palette.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

enum LoafThemeId {
  loafDark('Loaf Dark'),
  nihon('日本');

  const LoafThemeId(this.label);

  final String label;
}

/// Oct 16 through Nov 6, every year, by the device's own calendar: the trip
/// the 日本 theme was made for.
bool inNihonSeason(DateTime local) {
  final monthDay = local.month * 100 + local.day;
  return monthDay >= 1016 && monthDay <= 1106;
}

@immutable
class AppearanceSettings {
  const AppearanceSettings({
    this.theme = LoafThemeId.loafDark,
    this.easterEggs = true,
    this.externalMedia = true,
  });

  /// Anything unreadable falls back to that field's default, so a
  /// hand-edited file degrades instead of failing.
  factory AppearanceSettings.fromJson(Object? json) {
    if (json is! Map) return const AppearanceSettings();
    final eggs = json['easterEggs'];
    final external = json['externalMedia'];
    return AppearanceSettings(
      theme:
          LoafThemeId.values
              .where((t) => t.name == json['theme'])
              .firstOrNull ??
          LoafThemeId.loafDark,
      easterEggs: eggs is bool ? eggs : true,
      externalMedia: external is bool ? external : true,
    );
  }

  final LoafThemeId theme;
  final bool easterEggs;

  /// Whether pictures, video and files a bridge links to on other sites are
  /// fetched and shown. Never in an encrypted room, whatever this says.
  final bool externalMedia;

  AppearanceSettings copyWith({
    LoafThemeId? theme,
    bool? easterEggs,
    bool? externalMedia,
  }) => AppearanceSettings(
    theme: theme ?? this.theme,
    easterEggs: easterEggs ?? this.easterEggs,
    externalMedia: externalMedia ?? this.externalMedia,
  );

  Map<String, Object> toJson() => {
    'theme': theme.name,
    'easterEggs': easterEggs,
    'externalMedia': externalMedia,
  };
}

abstract interface class AppearanceStore {
  /// Null when nothing has been saved, or what was saved can't be read.
  Future<AppearanceSettings?> load();

  Future<void> save(AppearanceSettings settings);
}

/// Forgets on exit: for tests and the mock backend.
class MemoryAppearanceStore implements AppearanceStore {
  MemoryAppearanceStore([this.saved]);

  AppearanceSettings? saved;

  @override
  Future<AppearanceSettings?> load() async => saved;

  @override
  Future<void> save(AppearanceSettings settings) async => saved = settings;
}

class FileAppearanceStore implements AppearanceStore {
  FileAppearanceStore(this.file);

  static Future<FileAppearanceStore> inSupportDirectory() async =>
      FileAppearanceStore(
        File(
          '${(await getApplicationSupportDirectory()).path}'
          '${Platform.pathSeparator}appearance.json',
        ),
      );

  final File file;

  @override
  Future<AppearanceSettings?> load() async {
    try {
      return AppearanceSettings.fromJson(jsonDecode(await file.readAsString()));
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> save(AppearanceSettings settings) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(settings.toJson()));
  }
}

class AppearanceController extends ChangeNotifier with WidgetsBindingObserver {
  AppearanceController({
    required this._store,
    this._settings = const AppearanceSettings(),
    this._clock = DateTime.now,
  }) {
    _lastEffective = effective;
    externalMediaListenable = ValueNotifier(_settings.externalMedia);
    _armMidnight();
    WidgetsBinding.instance.addObserver(this);
  }

  static Future<AppearanceController> load(
    AppearanceStore store, {
    DateTime Function() clock = DateTime.now,
  }) async => AppearanceController(
    store: store,
    settings: await store.load() ?? const AppearanceSettings(),
    clock: clock,
  );

  final AppearanceStore _store;
  final DateTime Function() _clock;
  AppearanceSettings _settings;
  Timer? _midnight;
  late LoafThemeId _lastEffective;

  LoafThemeId get chosen => _settings.theme;
  bool get easterEggs => _settings.easterEggs;
  bool get externalMedia => _settings.externalMedia;

  /// [externalMedia] for the Matrix side, which reads it without knowing
  /// about themes.
  late final ValueNotifier<bool> externalMediaListenable;

  LoafThemeId get effective =>
      easterEggs && inNihonSeason(_clock()) ? LoafThemeId.nihon : chosen;

  /// The season is changing what the pick alone would show — settings says
  /// so, or the picker would look broken.
  bool get seasonOverrides => effective != chosen;

  void choose(LoafThemeId theme) => _update(_settings.copyWith(theme: theme));

  void setEasterEggs(bool on) => _update(_settings.copyWith(easterEggs: on));

  void setExternalMedia(bool on) =>
      _update(_settings.copyWith(externalMedia: on));

  void _update(AppearanceSettings next) {
    if (next.theme == chosen &&
        next.easterEggs == easterEggs &&
        next.externalMedia == externalMedia) {
      return;
    }
    _settings = next;
    _lastEffective = effective;
    externalMediaListenable.value = next.externalMedia;
    notifyListeners();
    // A pick that can't be saved still applies for this run; losing it at
    // the next launch beats crashing over a theme.
    _store.save(next).then((_) {}, onError: (Object _) {});
  }

  /// The season starts and ends at midnight, so an app left open re-checks
  /// then rather than waiting for a restart.
  void _armMidnight() {
    final now = _clock();
    final next = DateTime(now.year, now.month, now.day + 1);
    _midnight = Timer(next.difference(now), () {
      _lastEffective = effective;
      notifyListeners();
      _armMidnight();
    });
  }

  /// Timers stand still while the machine sleeps, so a laptop closed across
  /// a season edge wakes with a stale midnight timer. Resuming re-arms it and
  /// repaints only if the theme really changed.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _midnight?.cancel();
    _armMidnight();
    if (effective != _lastEffective) {
      _lastEffective = effective;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _midnight?.cancel();
    externalMediaListenable.dispose();
    super.dispose();
  }
}

/// Sits above `MaterialApp`, so routes on the root navigator — the settings
/// dialog among them — can reach the controller.
class AppearanceScope extends InheritedNotifier<AppearanceController> {
  const AppearanceScope({
    super.key,
    required AppearanceController controller,
    required super.child,
  }) : super(notifier: controller);

  static AppearanceController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppearanceScope>()?.notifier;
}
