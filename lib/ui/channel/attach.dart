/// Choosing files to send, with each platform's own picker: the open panel
/// on a computer (NSOpenPanel on macOS; GTK's native chooser on Linux, which
/// is the file chooser portal inside Flatpak), and on a phone a choice
/// between the photo library (PHPicker) and Files.
library;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../platform.dart';
import '../widgets/action_menu.dart';

/// Asks for files to send. An empty list when nothing was chosen.
typedef AttachmentPicker = Future<List<XFile>> Function(BuildContext context);

enum _Source { library, files }

Future<List<XFile>> pickAttachments(BuildContext context) async {
  // A computer has one place files come from, so the panel opens at once.
  if (isDesktop) return openFiles();
  // A phone keeps photos apart from files, as its own apps do.
  final source = await showActionSheet<_Source>(
    context,
    items: const [
      ActionItem(
        value: _Source.library,
        icon: LucideIcons.image,
        label: 'Photos & videos',
      ),
      ActionItem(
        value: _Source.files,
        icon: LucideIcons.folder,
        label: 'Files',
      ),
    ],
  );
  return switch (source) {
    // PHPicker needs no permission; this keeps the plugin from asking.
    _Source.library => ImagePicker().pickMultipleMedia(
      requestFullMetadata: false,
    ),
    _Source.files => openFiles(),
    null => const [],
  };
}
