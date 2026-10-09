#include "loaf_notify_plugin.h"

#include <shellapi.h>

#include <flutter/standard_method_codec.h>

#include <string>
#include <utility>

#include "include/loaf_notify/loaf_notify_win.h"

// The Windows half of package:loaf_notify. Dart's
// `lib/notify/channel_notifications.dart` is the other end of
// `moe.loaf.chat/notify`; the Rust is `rust/src/ffi.rs`.

namespace loaf_notify {

namespace {

constexpr char kFailed[] = "notify-failed";

// Posted to the top-level window to reach the platform thread, where
// channels may be used. LPARAM is an owned ClickIds*.
const UINT kClickMessage = RegisterWindowMessageW(L"moe.loaf.chat.notify.click");

using flutter::EncodableMap;
using flutter::EncodableValue;
using ClickIds = std::pair<std::string, std::string>;

const std::string* StringArg(const EncodableMap& args, const char* key) {
  auto it = args.find(EncodableValue(key));
  return it == args.end() ? nullptr : std::get_if<std::string>(&it->second);
}

void Status(Result& result, int32_t status, const std::string& what) {
  if (status == 0) {
    result.Success();
  } else {
    result.Error(kFailed, what + " failed (" + std::to_string(status) + ")");
  }
}

}  // namespace

// static
void LoafNotifyPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel = std::make_unique<Channel>(
      registrar->messenger(), "moe.loaf.chat/notify",
      &flutter::StandardMethodCodec::GetInstance());
  auto plugin =
      std::make_unique<LoafNotifyPlugin>(registrar, std::move(channel));
  registrar->AddPlugin(std::move(plugin));
}

LoafNotifyPlugin::LoafNotifyPlugin(flutter::PluginRegistrarWindows* registrar,
                                   std::unique_ptr<Channel> channel)
    : registrar_(registrar), channel_(std::move(channel)) {
  if (flutter::FlutterView* view = registrar->GetView()) {
    window_ = GetAncestor(view->GetNativeWindow(), GA_ROOT);
  }
  proc_id_ = registrar->RegisterTopLevelWindowProcDelegate(
      [this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
        return HandleWindowProc(hwnd, message, wparam, lparam);
      });
  notifier_ = loaf_notify_new(&LoafNotifyPlugin::OnClick, this);
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
}

LoafNotifyPlugin::~LoafNotifyPlugin() {
  // The notifier first: no click reaches this plugin once it is freed.
  loaf_notify_free(notifier_);
  notifier_ = nullptr;
  registrar_->UnregisterTopLevelWindowProcDelegate(proc_id_);
}

// static
// On a WinRT thread: copy the ids and post them to the platform thread,
// where the channel may be used.
void LoafNotifyPlugin::OnClick(void* context, const char* room_id,
                               const char* event_id) {
  auto* plugin = static_cast<LoafNotifyPlugin*>(context);
  auto* click = new ClickIds(room_id, event_id);
  if (plugin->window_ == nullptr ||
      !PostMessageW(plugin->window_, kClickMessage, 0,
                    reinterpret_cast<LPARAM>(click))) {
    delete click;
  }
}

std::optional<LRESULT> LoafNotifyPlugin::HandleWindowProc(HWND, UINT message,
                                                          WPARAM,
                                                          LPARAM lparam) {
  if (message != kClickMessage) return std::nullopt;
  std::unique_ptr<ClickIds> click(reinterpret_cast<ClickIds*>(lparam));
  channel_->InvokeMethod(
      "click", std::make_unique<EncodableValue>(EncodableMap{
                   {EncodableValue("roomId"), EncodableValue(click->first)},
                   {EncodableValue("eventId"), EncodableValue(click->second)},
               }));
  return 0;
}

void LoafNotifyPlugin::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<Result> result) {
  const std::string& method = call.method_name();
  static const EncodableMap kNoArgs;
  const EncodableMap* args = std::get_if<EncodableMap>(call.arguments());
  if (args == nullptr) args = &kNoArgs;

  if (method == "prepare") {
    // Without the name and icon the toasts still show; log and carry on.
    int32_t status = loaf_notify_register();
    if (status != 0) {
      OutputDebugStringA(("[loaf notify] register failed (" +
                          std::to_string(status) + ")\n")
                             .c_str());
    }
    result->Success();
  } else if (method == "show") {
    const std::string* title = StringArg(*args, "title");
    const std::string* body = StringArg(*args, "body");
    const std::string* room = StringArg(*args, "roomId");
    const std::string* event = StringArg(*args, "eventId");
    const std::string* avatar = StringArg(*args, "avatarPath");
    if (title == nullptr || body == nullptr || room == nullptr ||
        event == nullptr) {
      result->Error(kFailed, "show needs title, body, roomId and eventId");
      return;
    }
    int32_t status = loaf_notify_show(notifier_, title->c_str(), body->c_str(),
                                      room->c_str(), event->c_str(),
                                      avatar == nullptr ? nullptr
                                                        : avatar->c_str());
    if (status != 0) {
      Status(*result, status, "show");
    } else {
      // false: the platform made no sound, so Dart plays the chime.
      result->Success(EncodableValue(false));
    }
  } else if (method == "withdraw") {
    const std::string* room = StringArg(*args, "roomId");
    if (room == nullptr) {
      result->Error(kFailed, "withdraw needs a roomId");
      return;
    }
    Status(*result, loaf_notify_withdraw(notifier_, room->c_str()),
           "withdraw");
  } else if (method == "blocked") {
    result->Success(EncodableValue(loaf_notify_blocked() == 1));
  } else if (method == "openSettings") {
    ShellExecuteW(nullptr, L"open", L"ms-settings:notifications", nullptr,
                  nullptr, SW_SHOWNORMAL);
    result->Success();
  } else if (method == "ready") {
    // A toast's click arrives only in a running app: nothing is ever held.
    result->Success();
  } else {
    result->NotImplemented();
  }
}

}  // namespace loaf_notify
