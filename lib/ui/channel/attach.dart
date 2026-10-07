/// Choosing files to send, with each platform's own picker: the open panel
/// on a computer (NSOpenPanel on macOS; GTK's native chooser on Linux, which
/// is the file chooser portal inside Flatpak), and on a phone a choice
/// between the photo library (PHPicker) and Files.
library;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:loaf_media/loaf_media.dart' show LoafMedia;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../platform.dart';
import '../widgets/action_menu.dart';

/// Asks for files to send. An empty list when nothing was chosen.
typedef AttachmentPicker = Future<List<XFile>> Function(BuildContext context);

/// Asks the clipboard for files to send. An empty list when it holds none,
/// which is a paste of text.
typedef ClipboardAttachments = Future<List<XFile>> Function();

/// Whether the clipboard holds files or a picture, without reading them.
typedef ClipboardHasAttachments = Future<bool> Function();

/// The platforms whose clipboard can be read for more than text. Windows and
/// Android have no native glue to do it with.
bool get _clipboardReadable => switch (defaultTargetPlatform) {
  TargetPlatform.linux || TargetPlatform.macOS || TargetPlatform.iOS => true,
  _ => false,
};

Future<bool> hasPastedAttachments() async {
  if (!_clipboardReadable) return false;
  try {
    return await LoafMedia.clipboardHasFiles();
  } on Object {
    return false;
  }
}

enum _Source { library, files }

/// What a paste carries that isn't text: files copied in a file manager, or
/// a picture (a screenshot, "copy image"). Flutter's own clipboard is text
/// alone, so this asks the plugin; where there is none, the paste is left to
/// the text field.
Future<List<XFile>> pastedAttachments() async {
  if (!_clipboardReadable) return const [];
  try {
    final paths = await LoafMedia.clipboardFiles();
    if (paths.isNotEmpty) return [for (final path in paths) XFile(path)];
    final png = await LoafMedia.clipboardImage();
    if (png != null) {
      // Off the web an XFile's name is the last part of its path, whatever
      // [name] says: so the name is the path as well.
      final name = _pastedName(DateTime.now());
      return [
        XFile.fromData(png, name: name, path: name, mimeType: 'image/png'),
      ];
    }
  } on Object catch (e) {
    // An unreadable clipboard is not worth a failed paste: fall back to text.
    debugPrint('[loaf] clipboard files unreadable: $e');
  }
  return const [];
}

/// `pasted-2026-10-06-113045.png`: a name that sorts, since a picture off
/// the clipboard has none of its own.
String _pastedName(DateTime at) {
  String two(int n) => n.toString().padLeft(2, '0');
  return 'pasted-${at.year}-${two(at.month)}-${two(at.day)}-'
      '${two(at.hour)}${two(at.minute)}${two(at.second)}.png';
}

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
