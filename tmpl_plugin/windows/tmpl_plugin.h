#ifndef FLUTTER_PLUGIN_TMPL_PLUGIN_H_
#define FLUTTER_PLUGIN_TMPL_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace tmpl_plugin {

class TmplPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  TmplPlugin();

  virtual ~TmplPlugin();

  // Disallow copy and assign.
  TmplPlugin(const TmplPlugin&) = delete;
  TmplPlugin& operator=(const TmplPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

}  // namespace tmpl_plugin

#endif  // FLUTTER_PLUGIN_TMPL_PLUGIN_H_
