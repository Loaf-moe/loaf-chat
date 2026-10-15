import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart' show Logs;

import 'log_file.dart';

import 'matrix/matrix_rooms.dart';
import 'matrix/matrix_session.dart';
import 'platform/livekit_media.dart';
import 'platform/system_audio_devices.dart';
import 'ui/auth/loaf_session.dart';
import 'ui/auth/session_root.dart';
import 'ui/model/updater.dart';
import 'ui/mock/mock_audio_devices.dart';
import 'ui/mock/mock_session.dart';
import 'ui/platform.dart';
import 'ui/rooms/rooms.dart';
import 'notify/pick_notifications.dart';
import 'ui/shell/before_quit.dart';
import 'ui/model/chime.dart';
import 'ui/model/message_route.dart';
import 'ui/settings/notification_settings.dart';
import 'ui/settings/voice_settings.dart';
import 'ui/theme/appearance.dart';
import 'ui/theme/loaf_theme.dart';
import 'ui/window/window_chrome.dart';
import 'update/pick_updater.dart';
import 'util/json_store.dart';

/// Dark is the default. The brand defines no dark palette, but a community
/// chat client is read in the evening, so the derived navy palette leads and
/// cream is the alternative.
final themeMode = ValueNotifier<ThemeMode>(ThemeMode.dark);

/// Which theme the app wears. Lives as long as the app, like [themeMode].
late final AppearanceController appearance;
late final NotificationController notifications;

/// Where clicked notifications lead, for the app's life; null without them.
Stream<MessageRoute>? noticeRoutes;

/// Which microphone and speaker calls use; null where there are no calls.
/// Lives as long as the app, like [themeMode].
VoiceController? voice;

/// The app talks to a real homeserver; `--dart-define=LOAF_BACKEND=mock`
/// plays the mock instead, for previews and the debug levers.
const backend = String.fromEnvironment('LOAF_BACKEND', defaultValue: 'matrix');

/// The window's own controls, in place of the OS title bar. Lives as long
/// as the app, like [themeMode].
final windowChrome = WindowChromeController(runner: pickWindowRunner());

/// The app's one account. Lives as long as the app, like [themeMode].
late final LoafSession session;

/// Makes the account's rooms each time the app opens onto them; null plays
/// the mock's.
Rooms Function()? newRooms;

/// What replaces this copy of the app with a newer one; null plays the
/// mock's. Lives as long as the app.
Updater? updater;

/// What the app must do before it ends by a signal. Lives as long as the
/// app.
final beforeQuit = BeforeQuit();

/// Ends the app on SIGINT or SIGTERM once [beforeQuit] has run. Watching a
/// signal takes over from its default action, so nothing else would. A
/// second signal ends it at once.
void _quitOnSignals(BeforeQuit beforeQuit) {
  var quitting = false;
  for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    signal.watch().listen((_) async {
      if (quitting) exit(128 + signal.signalNumber);
      quitting = true;
      try {
        await beforeQuit.run();
      } on Object catch (e, s) {
        // The app ends either way; say what went wrong on the way out.
        stderr.writeln('before quitting: $e\n$s');
      }
      exit(0);
    });
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && (Platform.isLinux || Platform.isMacOS)) {
    _quitOnSignals(beforeQuit);
  }
  // An installed Windows build has no console, and the SDK's log is where
  // every notification failure goes: a file is the one way to see it.
  if (!kIsWeb && Platform.isWindows) {
    Logs().onLog = (await LogFile.inSupportDirectory()).write;
  }
  // Restored before the first frame, like the session, so the app never
  // flashes the wrong palette. The mock keeps nothing between runs.
  appearance = await AppearanceController.load(
    backend == 'mock'
        ? MemoryStore<AppearanceSettings>()
        : await JsonFileStore.inSupportDirectory(
            'appearance.json',
            AppearanceSettings.fromJson,
          ),
  );
  final chime = NativeChime();
  final desktop = backend == 'mock'
      ? null
      : pickDesktopNotifications(chime: chime);
  notifications = await NotificationController.load(
    backend == 'mock'
        ? MemoryStore<NotificationSettings>()
        : await JsonFileStore.inSupportDirectory(
            'notifications.json',
            NotificationSettings.fromJson,
          ),
    chime: chime,
    desktop: desktop,
  );
  noticeRoutes = desktop == null ? null : fronted(desktop.clicks);
  // The stored session restores from disk before the first frame, so a
  // signed-in app never flashes the sign-in screen.
  final calls = hasCalls;
  if (backend == 'mock') {
    session = MockSession();
    voice = await VoiceController.load(
      MemoryStore<VoiceSettings>(),
      devices: MemoryAudioDevices(),
    );
  } else {
    final matrix = await MatrixSession.open(desktop: isDesktop);
    session = matrix;
    // The Mac's own account of its devices; WebRTC's is used elsewhere.
    final system = defaultTargetPlatform == TargetPlatform.macOS
        ? SystemAudioDevices()
        : null;
    if (calls) {
      voice = await VoiceController.load(
        await JsonFileStore.inSupportDirectory(
          'voice.json',
          VoiceSettings.fromJson,
        ),
        devices: system ?? const LiveKitAudioDevices(),
      );
    }
    newRooms = () => MatrixRooms(
      matrix.client,
      externalMedia: appearance.externalMediaListenable,
      callMedia: calls
          ? LiveKitMedia(selectSpeaker: system?.selectSpeaker)
          : null,
      voice: voice?.settings,
      voiceApplying: voice?.applying,
    );
    updater = pickUpdater();
  }
  // Before the first frame, so the buttons are there from the start rather
  // than popping in.
  await windowChrome.start();
  runApp(const LoafApp());
}

class LoafApp extends StatelessWidget {
  const LoafApp({super.key});

  @override
  Widget build(BuildContext context) {
    final app = ListenableBuilder(
      listenable: Listenable.merge([appearance, themeMode]),
      builder: (context, _) {
        final mode = themeMode.value;
        // 日本 has one palette, so it fills both slots and Ctrl+T leaves it be.
        final nihon = appearance.effective == LoafThemeId.nihon;
        return MaterialApp(
          title: 'Loaf Chat',
          debugShowCheckedModeBanner: false,
          theme: nihon ? loafNihonTheme() : loafLightTheme(),
          darkTheme: nihon ? loafNihonTheme() : loafDarkTheme(),
          themeMode: mode,
          builder: (context, child) =>
              WindowChrome(controller: windowChrome, child: child!),
          home: CallbackShortcuts(
            bindings: {
              // Ctrl+T flips the palette. This exists so both themes get looked
              // at during design; it is not a product feature.
              const SingleActivator(
                LogicalKeyboardKey.keyT,
                control: true,
              ): () {
                themeMode.value = mode == ThemeMode.dark
                    ? ThemeMode.light
                    : ThemeMode.dark;
              },
            },
            // Sign-in or the app, as the session says. The debug menu's levers
            // move between them.
            child: Focus(
              autofocus: true,
              child: SessionRoot(
                session: session,
                rooms: newRooms,
                updater: updater,
                beforeQuit: beforeQuit,
                routes: noticeRoutes,
              ),
            ),
          ),
        );
      },
    );
    return AppearanceScope(
      controller: appearance,
      child: NotificationScope(
        controller: notifications,
        child: switch (voice) {
          final voice? => VoiceScope(controller: voice, child: app),
          null => app,
        },
      ),
    );
  }
}
