/// A small floating pill for quick confirmations and "coming later" notes.
library;

import 'package:flutter/material.dart';

import '../theme/loaf_theme.dart';

void showToast(BuildContext context, String text) {
  final tokens = LoafTokens.of(context);
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          text,
          style: loafBody(14, 500).copyWith(color: tokens.textStrong),
        ),
        backgroundColor: tokens.card,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 1500),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LoafRadius.full),
          side: BorderSide(color: tokens.border),
        ),
      ),
    );
}
