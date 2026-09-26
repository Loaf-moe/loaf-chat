/// A single-line input in the app's shape: an icon, the text, and room for a
/// trailing control. Sign-in and recovery both use it.
library;

import 'package:flutter/material.dart';

import '../theme/loaf_theme.dart';

class LoafField extends StatelessWidget {
  const LoafField({
    super.key,
    required this.controller,
    required this.hint,
    required this.icon,
    this.obscure = false,
    this.autofocus = false,
    this.onSubmit,
    this.onChanged,
    this.autofillHints,
    this.textInputAction,
    this.trailing,
    this.exact = false,
    this.keyboardType,
  });

  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final bool obscure;
  final bool autofocus;
  final VoidCallback? onSubmit;
  final ValueChanged<String>? onChanged;
  final Iterable<String>? autofillHints;
  final TextInputAction? textInputAction;
  final Widget? trailing;

  /// Names, addresses and keys: typed exactly, so the keyboard neither
  /// corrects nor suggests.
  final bool exact;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x3),
      decoration: BoxDecoration(
        color: tokens.card,
        borderRadius: BorderRadius.circular(LoafRadius.lg),
        border: Border.all(color: tokens.border),
      ),
      child: Row(
        children: [
          Icon(icon, size: 17, color: tokens.textMuted),
          const SizedBox(width: LoafSpace.x2),
          Expanded(
            child: TextField(
              controller: controller,
              obscureText: obscure,
              autocorrect: !exact,
              enableSuggestions: !exact,
              keyboardType: keyboardType,
              autofocus: autofocus,
              autofillHints: autofillHints,
              textInputAction: textInputAction,
              onChanged: onChanged,
              onSubmitted: (_) => onSubmit?.call(),
              style: loafBody(
                15,
                400,
                height: 1.4,
              ).copyWith(color: tokens.textBody),
              decoration: InputDecoration(
                // Collapsed, so the field contributes exactly its line box and
                // the Row's centring does the vertical work. The composer needs
                // an asymmetric nudge because it bottom-aligns against taller
                // controls; that constant is specific to that layout and does
                // not transfer here.
                isCollapsed: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                hintText: hint,
                hintStyle: loafBody(
                  15,
                  400,
                  height: 1.4,
                ).copyWith(color: tokens.textMuted),
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
