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
        duration: _readingTime(text),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LoafRadius.full),
          side: BorderSide(color: tokens.border),
        ),
      ),
    );
}

/// Long enough to read: a quick note goes in a moment, a sentence saying
/// why something didn't send stays a few seconds.
Duration _readingTime(String text) =>
    Duration(milliseconds: (text.length * 70).clamp(1500, 5000));
