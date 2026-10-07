
import 'tmpl_plugin_platform_interface.dart';

class TmplPlugin {
  Future<String?> getPlatformVersion() {
    return TmplPluginPlatform.instance.getPlatformVersion();
  }
}
