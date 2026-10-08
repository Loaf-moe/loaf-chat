/// What loaf chat does when a message arrives somewhere you aren't looking.
/// For now that is one switch: the chime.
///
/// Saved to a small JSON file beside `appearance.json` in the support
/// directory. Like appearance, this is per device, not per account: a laptop
/// on a desk and a phone in a pocket want different answers.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../model/chime.dart';

@immutable
class NotificationSettings {
  const NotificationSettings({this.sound = true});

  /// Anything unreadable falls back to that field's default, so a
  /// hand-edited file degrades instead of failing.
  factory NotificationSettings.fromJson(Object? json) {
    if (json is! Map) return const NotificationSettings();
    final sound = json['sound'];
    return NotificationSettings(sound: sound is bool ? sound : true);
  }

  final bool sound;

  NotificationSettings copyWith({bool? sound}) =>
      NotificationSettings(sound: sound ?? this.sound);

  Map<String, Object> toJson() => {'sound': sound};
}

abstract interface class NotificationStore {
  /// Null when nothing has been saved, or what was saved can't be read.
  Future<NotificationSettings?> load();

  Future<void> save(NotificationSettings settings);
}

/// Forgets on exit: for tests and the mock backend.
class MemoryNotificationStore implements NotificationStore {
  MemoryNotificationStore([this.saved]);

  NotificationSettings? saved;

  @override
  Future<NotificationSettings?> load() async => saved;

  @override
  Future<void> save(NotificationSettings settings) async => saved = settings;
}

class FileNotificationStore implements NotificationStore {
  FileNotificationStore(this.file);

  static Future<FileNotificationStore> inSupportDirectory() async =>
      FileNotificationStore(
        File(
          '${(await getApplicationSupportDirectory()).path}'
          '${Platform.pathSeparator}notifications.json',
        ),
      );

  final File file;

  @override
  Future<NotificationSettings?> load() async {
    try {
      return NotificationSettings.fromJson(
        jsonDecode(await file.readAsString()),
      );
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> save(NotificationSettings settings) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(settings.toJson()));
  }
}

class NotificationController extends ChangeNotifier {
  NotificationController({
    required this._store,
    required this.chime,
    this._settings = const NotificationSettings(),
  });

  static Future<NotificationController> load(
    NotificationStore store, {
    required Chime chime,
  }) async => NotificationController(
    store: store,
    chime: chime,
    settings: await store.load() ?? const NotificationSettings(),
  );

  final NotificationStore _store;
  NotificationSettings _settings;

  /// What plays the sound, here so Settings can preview it and the shell can
  /// play it from the same place.
  final Chime chime;

  bool get sound => _settings.sound;

  void setSound(bool on) => _update(_settings.copyWith(sound: on));

  void _update(NotificationSettings next) {
    if (next.sound == sound) return;
    _settings = next;
    notifyListeners();
    // A pick that can't be saved still applies for this run; losing it at
    // the next launch beats crashing over a chime.
    _store.save(next).then((_) {}, onError: (Object _) {});
  }
}

/// Sits above `MaterialApp`, so routes on the root navigator — the settings
/// dialog among them — can reach the controller.
class NotificationScope extends InheritedNotifier<NotificationController> {
  const NotificationScope({
    super.key,
    required NotificationController controller,
    required super.child,
  }) : super(notifier: controller);

  /// The controller without depending on the scope: the caller is not
  /// rebuilt when a setting changes. For code that reads the controller
  /// live, as the shell's notifier does.
  static NotificationController? find(BuildContext context) =>
      context.getInheritedWidgetOfExactType<NotificationScope>()?.notifier;

  static NotificationController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NotificationScope>()?.notifier;
}
