/// Whether the window draws through X11, where Flutter copies every frame
/// through the CPU: motion costs far more there than anywhere else.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Asks the Linux runner over `loaf/window`; false on any other platform.
Future<bool> drawsThroughX11({
  MethodChannel channel = const MethodChannel('loaf/window'),
}) async {
  if (defaultTargetPlatform != TargetPlatform.linux) return false;
  return await channel.invokeMethod<bool>('x11') == true;
}
