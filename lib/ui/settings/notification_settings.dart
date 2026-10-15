/// What loaf chat does when a message arrives somewhere you aren't looking.
/// The chime, desktop notifications, and how much a notification says.
///
/// Saved to a small JSON file beside `appearance.json` in the support
/// directory. Like appearance, this is per device, not per account: a laptop
/// on a desk and a phone in a pocket want different answers.
library;

import 'package:flutter/widgets.dart';

import '../model/chime.dart';
import '../model/desktop_notifications.dart';
import '../../util/json_store.dart';

@immutable
class NotificationSettings implements Jsonable {
  const NotificationSettings({
    this.sound = true,
    this.notifications = true,
    this.showText = true,
  });

  /// Anything unreadable falls back to that field's default, so a
  /// hand-edited file degrades instead of failing.
  factory NotificationSettings.fromJson(Object? json) {
    if (json is! Map) return const NotificationSettings();
    bool flag(String key) => switch (json[key]) {
      final bool on => on,
      _ => true,
    };
    return NotificationSettings(
      sound: flag('sound'),
      notifications: flag('notifications'),
      showText: flag('showText'),
    );
  }

  /// The chime, in the app and on notifications.
  final bool sound;

  /// Desktop notifications while the app isn't in front.
  final bool notifications;

  /// Off, a notification says who wrote but not what.
  final bool showText;

  NotificationSettings copyWith({
    bool? sound,
    bool? notifications,
    bool? showText,
  }) => NotificationSettings(
    sound: sound ?? this.sound,
    notifications: notifications ?? this.notifications,
    showText: showText ?? this.showText,
  );

  @override
  Map<String, Object> toJson() => {
    'sound': sound,
    'notifications': notifications,
    'showText': showText,
  };

  @override
  bool operator ==(Object other) =>
      other is NotificationSettings &&
      other.sound == sound &&
      other.notifications == notifications &&
      other.showText == showText;

  @override
  int get hashCode => Object.hash(sound, notifications, showText);
}

class NotificationController extends ChangeNotifier {
  NotificationController({
    required this._store,
    required this.chime,
    this.desktop,
    this._settings = const NotificationSettings(),
  });

  static Future<NotificationController> load(
    Store<NotificationSettings> store, {
    required Chime chime,
    DesktopNotifications? desktop,
  }) async => NotificationController(
    store: store,
    chime: chime,
    desktop: desktop,
    settings: await store.load() ?? const NotificationSettings(),
  );

  final Store<NotificationSettings> _store;
  NotificationSettings _settings;

  /// What plays the sound, here so Settings can preview it and the shell can
  /// play it from the same place.
  final Chime chime;

  /// The desktop's notifications, for the shell to show and Settings to ask
  /// after; null on phones, in the mock, and in tests that leave it out.
  final DesktopNotifications? desktop;

  bool get sound => _settings.sound;

  bool get notifications => _settings.notifications;
  bool get showText => _settings.showText;

  void setSound(bool on) => _update(_settings.copyWith(sound: on));
  void setNotifications(bool on) =>
      _update(_settings.copyWith(notifications: on));
  void setShowText(bool on) => _update(_settings.copyWith(showText: on));

  void _update(NotificationSettings next) {
    if (next == _settings) return;
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
