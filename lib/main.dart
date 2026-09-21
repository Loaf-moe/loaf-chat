import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ui/auth/login_page.dart';
import 'ui/shell/app_shell.dart';
import 'ui/theme/loaf_theme.dart';

/// Dark is the default. The brand defines no dark palette, but a community
/// chat client is read in the evening, so the derived navy palette leads and
/// cream is the alternative.
final themeMode = ValueNotifier<ThemeMode>(ThemeMode.dark);

void main() => runApp(const LoafApp());

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
        child: Focus(
          autofocus: true,
          child: Builder(
            builder: (context) => LoginPage(
              onSignedIn: () => Navigator.of(
                context,
              ).push(MaterialPageRoute<void>(builder: (_) => const AppShell())),
            ),
          ),
        ),
      ),
    ),
  );
}
