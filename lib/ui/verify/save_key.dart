/// Saving a new recovery key where the person chooses: the system's save
/// panel on a computer, the share sheet on a phone (Save to Files, or a
/// password manager).
library;

import 'dart:convert';
import 'dart:ui';

import 'package:file_selector/file_selector.dart';
import 'package:share_plus/share_plus.dart'
    show ShareParams, SharePlus, ShareResultStatus;

import '../platform.dart';

/// True only once the key went somewhere: a save panel put away, or a share
/// sheet dismissed, keeps nothing. [origin] is where the share sheet points
/// from on an iPad.
typedef KeySaver = Future<bool> Function(String recoveryKey, {Rect? origin});

const _fileName = 'loaf recovery key.txt';

Future<bool> saveRecoveryKey(String recoveryKey, {Rect? origin}) async {
  final file = XFile.fromData(
    utf8.encode('$recoveryKey\n'),
    mimeType: 'text/plain',
    name: _fileName,
  );
  if (isDesktop) {
    final where = await getSaveLocation(
      suggestedName: _fileName,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'text', extensions: ['txt']),
      ],
    );
    if (where == null) return false;
    await file.saveTo(where.path);
    return true;
  }
  final shared = await SharePlus.instance.share(
    ShareParams(
      files: [file],
      fileNameOverrides: const [_fileName],
      sharePositionOrigin: origin,
    ),
  );
  // "Unavailable" means the platform can't say whether it went anywhere;
  // losing this key is the one mistake nothing recovers, so it doesn't count.
  return shared.status == ShareResultStatus.success;
}
