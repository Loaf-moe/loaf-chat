import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'matrix/matrix_session.dart';
import 'ui/auth/loaf_session.dart';
import 'ui/auth/session_root.dart';
import 'ui/mock/mock_session.dart';
import 'ui/platform.dart';
import 'ui/theme/loaf_theme.dart';

/// Dark is the default. The brand defines no dark palette, but a community
/// chat client is read in the evening, so the derived navy palette leads and
/// cream is the alternative.
final themeMode = ValueNotifier<ThemeMode>(ThemeMode.dark);

/// `--dart-define=LOAF_BACKEND=matrix` talks to a real homeserver; anything
/// else plays the mock, which stays the default until the rooms are real.
const backend = String.fromEnvironment('LOAF_BACKEND', defaultValue: 'mock');

/// The app's one account. Lives as long as the app, like [themeMode].
late final LoafSession session;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The stored session restores from disk before the first frame, so a
  // signed-in app never flashes the sign-in screen.
  session = backend == 'matrix'
      ? await MatrixSession.open(desktop: isDesktop)
      : MockSession();
  runApp(const LoafApp());
}

class LoafApp extends StatelessWidget {
  const LoafApp({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: themeMode,
    builder: (context, mode, _) => MaterialApp(
      title: 'Loaf',
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
        child: Focus(autofocus: true, child: SessionRoot(session: session)),
      ),
    ),
  );
}
