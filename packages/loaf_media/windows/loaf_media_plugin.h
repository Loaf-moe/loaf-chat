#ifndef FLUTTER_PLUGIN_LOAF_MEDIA_PLUGIN_H_
#define FLUTTER_PLUGIN_LOAF_MEDIA_PLUGIN_H_

#include <windows.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/texture_registrar.h>

#include <atomic>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <optional>

namespace loaf_media {

using Channel = flutter::MethodChannel<flutter::EncodableValue>;
using Result = flutter::MethodResult<flutter::EncodableValue>;

class LoafMediaPlugin;

// One inline video, by the view id Dart knows it by. Freed by the texture
// registrar's unregister callback, after Flutter has let go of it.
struct VideoView {
  int64_t view = 0;
  int64_t texture_id = -1;
  LoafMediaPlugin* plugin = nullptr;  // Outlives every player.
  std::unique_ptr<flutter::TextureVariant> texture;
  // Guards [player] against the raster thread taking a frame while it is
  // freed.
  std::mutex lock;
  void* player = nullptr;
  // Coalesces status checks posted to the platform thread.
  std::atomic<bool> check_posted{false};
  // What Dart has been told, so each is said once. Platform thread only.
  bool ready = false;
  bool failed = false;
};

class LoafMediaPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  LoafMediaPlugin(flutter::PluginRegistrarWindows* registrar,
                  std::unique_ptr<Channel> channel);
  ~LoafMediaPlugin() override;

  LoafMediaPlugin(const LoafMediaPlugin&) = delete;
  LoafMediaPlugin& operator=(const LoafMediaPlugin&) = delete;

  // From the player's threads.
  void FrameArrived(VideoView* view);

 private:
  void HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                        std::unique_ptr<Result> result);
  std::optional<LRESULT> HandleWindowProc(HWND hwnd, UINT message,
                                          WPARAM wparam, LPARAM lparam);

  void StreamCall(const std::string& method,
                  const flutter::EncodableMap& args, Result& result);
  void VideoCreate(const flutter::EncodableMap& args, Result& result);
  void VideoCall(const std::string& method, const flutter::EncodableMap& args,
                 Result& result);
  void DecodeImage(const flutter::EncodableMap& args,
                   std::unique_ptr<Result> result);
  void CheckStatus(int64_t view_id);
  void Dispose(int64_t view_id);

  flutter::PluginRegistrarWindows* registrar_;
  flutter::TextureRegistrar* textures_;
  std::unique_ptr<Channel> channel_;
  HWND window_ = nullptr;
  int proc_id_ = 0;
  // Media Foundation starts with the first video, not with the app.
  bool video_tried_ = false;
  bool video_ = false;
  std::map<int64_t, VideoView*> views_;
  int64_t next_view_ = 0;
};

}  // namespace loaf_media

#endif  // FLUTTER_PLUGIN_LOAF_MEDIA_PLUGIN_H_
