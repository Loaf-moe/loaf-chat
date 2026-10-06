#include "include/tmpl_plugin/tmpl_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "tmpl_plugin.h"

void TmplPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  tmpl_plugin::TmplPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
