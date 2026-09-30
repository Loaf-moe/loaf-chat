import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'matrix/matrix_rooms.dart';
import 'matrix/matrix_session.dart';
import 'ui/auth/loaf_session.dart';
import 'ui/auth/session_root.dart';
import 'ui/model/updater.dart';
import 'ui/mock/mock_session.dart';
import 'ui/platform.dart';
import 'ui/rooms/rooms.dart';
import 'ui/theme/loaf_theme.dart';
import 'update/pick_updater.dart';

/// Dark is the default. The brand defines no dark palette, but a community
/// chat client is read in the evening, so the derived navy palette leads and
/// cream is the alternative.
final themeMode = ValueNotifier<ThemeMode>(ThemeMode.dark);

/// The app talks to a real homeserver; `--dart-define=LOAF_BACKEND=mock`
/// plays the mock instead, for previews and the debug levers.
const backend = String.fromEnvironment('LOAF_BACKEND', defaultValue: 'matrix');

/// The app's one account. Lives as long as the app, like [themeMode].
late final LoafSession session;

/// Makes the account's rooms each time the app opens onto them; null plays
/// the mock's.
Rooms Function()? newRooms;

/// What replaces this copy of the app with a newer one; null plays the
/// mock's. Lives as long as the app.
Updater? updater;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The stored session restores from disk before the first frame, so a
  // signed-in app never flashes the sign-in screen.
  if (backend == 'mock') {
    session = MockSession();
  } else {
    final matrix = await MatrixSession.open(desktop: isDesktop);
    session = matrix;
    newRooms = () => MatrixRooms(matrix.client);
    updater = pickUpdater();
  }
  runApp(const LoafApp());
}

class LoafApp extends StatelessWidget {
  const LoafApp({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: themeMode,
    builder: (context, mode, _) => MaterialApp(
      title: 'Loaf Chat',
      debugShowCheckedModeBanner: false,
      theme: loafLightTheme(),
      darkTheme: loafDarkTheme(),
      themeMode: mode,
      home: CallbackShortcuts(
        bindings: {
          // Ctrl+T flips the palette. This exists so both themes get looked
          // at during design; it is not a product feature.
          const SingleActivator(LogicalKeyboardKey.keyT, control: true): () {
            themeMode.value = mode == ThemeMode.dark
                ? ThemeMode.light
                : ThemeMode.dark;
          },
        },
        // Sign-in or the app, as the session says. The debug menu's levers
        // move between them.
        child: Focus(
          autofocus: true,
          child: SessionRoot(session: session, rooms: newRooms, updater: updater),
        ),
      ),
    ),
  );
}
