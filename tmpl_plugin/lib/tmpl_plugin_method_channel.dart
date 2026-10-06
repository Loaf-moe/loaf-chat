import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'tmpl_plugin_platform_interface.dart';

/// An implementation of [TmplPluginPlatform] that uses method channels.
class MethodChannelTmplPlugin extends TmplPluginPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('tmpl_plugin');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
