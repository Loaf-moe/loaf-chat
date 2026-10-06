import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'tmpl_plugin_method_channel.dart';

abstract class TmplPluginPlatform extends PlatformInterface {
  /// Constructs a TmplPluginPlatform.
  TmplPluginPlatform() : super(token: _token);

  static final Object _token = Object();

  static TmplPluginPlatform _instance = MethodChannelTmplPlugin();

  /// The default instance of [TmplPluginPlatform] to use.
  ///
  /// Defaults to [MethodChannelTmplPlugin].
  static TmplPluginPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [TmplPluginPlatform] when
  /// they register themselves.
  static set instance(TmplPluginPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
