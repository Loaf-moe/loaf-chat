/// Something went wrong, said once in the brand's one red. Used under forms,
/// never as a banner.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/loaf_theme.dart';

class ErrorNote extends StatelessWidget {
  const ErrorNote({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(LoafSpace.x3),
      decoration: BoxDecoration(
        color: tokens.accentSoft,
        borderRadius: BorderRadius.circular(LoafRadius.md),
        border: Border.all(color: tokens.accent),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.triangleAlert, size: 16, color: tokens.accent),
          const SizedBox(width: LoafSpace.x2),
          Expanded(
            child: Text(
              message,
              style: loafBody(13, 400).copyWith(color: tokens.textBody),
            ),
          ),
        ],
      ),
    );
  }
}
