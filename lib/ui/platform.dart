/// Which family of idioms the app speaks on this platform.
library;

import 'package:flutter/foundation.dart';

/// Touch idioms on mobile, pointer idioms on desktop. The split is by
/// platform, not input device: long press has no business on a computer, a
/// computer must keep text selection, and only a computer updates itself.
/// See "Message actions" and "Platforms" in the design spec.
bool get isDesktop => switch (defaultTargetPlatform) {
  TargetPlatform.macOS ||
  TargetPlatform.linux ||
  TargetPlatform.windows => true,
  _ => false,
};
