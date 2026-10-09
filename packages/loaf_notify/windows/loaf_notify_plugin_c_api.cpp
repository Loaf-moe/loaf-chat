#include "include/loaf_notify/loaf_notify_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "loaf_notify_plugin.h"

void LoafNotifyPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  loaf_notify::LoafNotifyPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
