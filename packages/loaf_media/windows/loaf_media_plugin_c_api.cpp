#include "include/loaf_media/loaf_media_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "loaf_media_plugin.h"

void LoafMediaPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  loaf_media::LoafMediaPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
