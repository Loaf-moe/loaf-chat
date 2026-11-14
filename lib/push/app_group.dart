/// Where the data the iOS Notification Service Extension reads lives: the
/// App Group container, which the app and the extension share. Elsewhere,
/// Application Support, as before.
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:path_provider_foundation/path_provider_foundation.dart';

const appGroupId = 'group.moe.loaf.chat';

/// The database first, then its journal: SQLite treats a -wal beside the
/// wrong database as garbage, but one left behind is merely moved next run.
const _moved = [
  'loaf.sqlite',
  'loaf.sqlite-wal',
  'loaf.sqlite-shm',
  'notifications.json',
];

Future<Directory> dataDirectory() async {
  final support = await getApplicationSupportDirectory();
  if (!Platform.isIOS) return support;
  final group = await PathProviderFoundation().getContainerPath(
    appGroupIdentifier: appGroupId,
  );
  // Without the entitlement there is no container: carry on where the data
  // already is rather than lose it. The extension then falls back to the
  // gateway's alert.
  if (group == null) return support;
  final to = Directory(group);
  await moveIntoGroup(from: support, to: to);
  return to;
}

/// Each file moves on its own and only when the group lacks it, so a move
/// killed half way finishes on the next launch and never overwrites.
Future<void> moveIntoGroup({
  required Directory from,
  required Directory to,
}) async {
  // A database in both places: the group's is the live one, and the old
  // one's journal must never be laid beside it. A database only in the
  // group, with its journal still behind, is a move cut short: finish it.
  final both =
      File('${to.path}/loaf.sqlite').existsSync() &&
      File('${from.path}/loaf.sqlite').existsSync();
  for (final name in _moved) {
    final src = File('${from.path}/$name');
    final dst = File('${to.path}/$name');
    if (!src.existsSync() || dst.existsSync()) continue;
    if (both && name.startsWith('loaf.sqlite')) continue;
    try {
      await src.rename(dst.path);
    } on FileSystemException {
      // Another volume: copy, then remove the original only once it's there.
      await src.copy(dst.path);
      await src.delete();
    }
  }
}
