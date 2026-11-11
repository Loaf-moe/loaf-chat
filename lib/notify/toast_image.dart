/// The pictures a notification can carry.
library;

import 'package:mime/mime.dart';

/// What Windows can show in a toast, which it tells apart by extension.
const _toastTypes = {'image/png', 'image/jpeg', 'image/gif', 'image/webp'};

/// The extension a notification's picture is saved under, from what its
/// first bytes say it is; null for anything a toast can't show.
String? toastImageExtension(List<int> bytes) =>
    switch (lookupMimeType('', headerBytes: bytes)) {
      final type? when _toastTypes.contains(type) => extensionFromMime(type),
      _ => null,
    };
