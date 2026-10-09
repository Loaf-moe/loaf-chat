#ifndef FLUTTER_PLUGIN_LOAF_NOTIFY_PLUGIN_H_
#define FLUTTER_PLUGIN_LOAF_NOTIFY_PLUGIN_H_

#include <windows.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>
#include <optional>

namespace loaf_notify {

using Channel = flutter::MethodChannel<flutter::EncodableValue>;
using Result = flutter::MethodResult<flutter::EncodableValue>;

class LoafNotifyPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  LoafNotifyPlugin(flutter::PluginRegistrarWindows* registrar,
                   std::unique_ptr<Channel> channel);
  ~LoafNotifyPlugin() override;

  LoafNotifyPlugin(const LoafNotifyPlugin&) = delete;
  LoafNotifyPlugin& operator=(const LoafNotifyPlugin&) = delete;

 private:
  // From a WinRT thread: posts the click to the platform thread.
  static void OnClick(void* context, const char* room_id,
                      const char* event_id);

  void HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                        std::unique_ptr<Result> result);
  std::optional<LRESULT> HandleWindowProc(HWND hwnd, UINT message,
                                          WPARAM wparam, LPARAM lparam);

  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<Channel> channel_;
  HWND window_ = nullptr;
  int proc_id_ = 0;
  void* notifier_ = nullptr;
};

}  // namespace loaf_notify

#endif  // FLUTTER_PLUGIN_LOAF_NOTIFY_PLUGIN_H_
