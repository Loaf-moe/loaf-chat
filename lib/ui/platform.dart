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

/// Whether SSO goes to the real browser. Apple platforms have a system
/// sign-in window (ASWebAuthenticationSession) that closes itself and
/// hands back to the app; only desktops without one use a browser tab.
bool get ssoInBrowser => switch (defaultTargetPlatform) {
  TargetPlatform.linux || TargetPlatform.windows => true,
  _ => false,
};
