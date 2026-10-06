#include "loaf_media_plugin.h"

#include <flutter/standard_method_codec.h>

#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "include/loaf_media/loaf_media_win.h"

// The Windows half of package:loaf_media. Dart reports each download's
// progress (`stream.*`) to the Rust byte stream reading it, drives the
// players drawn into Flutter textures (`video.*`), opens files in their
// default app, and hands WIC the pictures Flutter can't decode. The other
// ends are `lib/src/streams.dart`, `lib/src/texture_video.dart` and
// `lib/src/native.dart`; the Rust is `rust/src/ffi.rs`.

namespace loaf_media {

namespace {

constexpr char kFailed[] = "video-failed";

// Posted to the top-level window to reach the platform thread, where
// channels may be used. WPARAM is the view id, or an ImageJob*.
const UINT kStatusMessage = RegisterWindowMessageW(L"moe.loaf.chat.media.status");
const UINT kImageMessage = RegisterWindowMessageW(L"moe.loaf.chat.media.image");

using flutter::EncodableMap;
using flutter::EncodableValue;

const EncodableValue* Lookup(const EncodableMap& args, const char* key) {
  auto it = args.find(EncodableValue(key));
  return it == args.end() ? nullptr : &it->second;
}

const std::string* StringArg(const EncodableMap& args, const char* key) {
  const EncodableValue* value = Lookup(args, key);
  return value == nullptr ? nullptr : std::get_if<std::string>(value);
}

// [fallback] when absent or null, as Dart sends an unknown total. Dart's
// ints arrive as 32 or 64 bits depending on their size.
int64_t IntArg(const EncodableMap& args, const char* key, int64_t fallback) {
  const EncodableValue* value = Lookup(args, key);
  if (value == nullptr) return fallback;
  if (auto* v = std::get_if<int32_t>(value)) return *v;
  if (auto* v = std::get_if<int64_t>(value)) return *v;
  return fallback;
}

bool BoolArg(const EncodableMap& args, const char* key) {
  const EncodableValue* value = Lookup(args, key);
  const bool* b = value == nullptr ? nullptr : std::get_if<bool>(value);
  return b != nullptr && *b;
}

void Status(Result& result, int32_t status, const std::string& what) {
  if (status == 0) {
    result.Success();
  } else {
    result.Error(kFailed, what + " failed (" + std::to_string(status) + ")");
  }
}

// The container Media Foundation's source resolver should expect.
std::string ExtensionFor(const std::string* mime) {
  if (mime == nullptr) return "mp4";
  if (*mime == "video/quicktime") return "mov";
  if (*mime == "video/webm") return "webm";
  if (*mime == "video/x-matroska") return "mkv";
  if (*mime == "video/3gpp") return "3gp";
  if (*mime == "video/x-msvideo") return "avi";
  if (*mime == "video/x-ms-wmv") return "wmv";
  return "mp4";
}

// A frame lent to Flutter until it has opened the handle.
struct Lent {
  FlutterDesktopGpuSurfaceDescriptor descriptor{};
  const void* frame = nullptr;
};

void ReleaseLent(void* context) {
  Lent* lent = static_cast<Lent*>(context);
  loaf_win_frame_release(lent->frame);
  delete lent;
}

void OnFrame(void* user) {
  VideoView* view = static_cast<VideoView*>(user);
  view->plugin->FrameArrived(view);
}

// A WIC decode on its own thread, answered on the platform thread.
struct ImageJob {
  std::unique_ptr<Result> result;
  std::vector<uint8_t> bytes;
  uint32_t max_width = 0;
  void* image = nullptr;
  uint32_t width = 0;
  uint32_t height = 0;
  const uint8_t* pixels = nullptr;
};

}  // namespace

// static
void LoafMediaPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel = std::make_unique<Channel>(
      registrar->messenger(), "moe.loaf.chat/media",
      &flutter::StandardMethodCodec::GetInstance());
  auto plugin = std::make_unique<LoafMediaPlugin>(registrar, std::move(channel));
  registrar->AddPlugin(std::move(plugin));
}

LoafMediaPlugin::LoafMediaPlugin(flutter::PluginRegistrarWindows* registrar,
                                 std::unique_ptr<Channel> channel)
    : registrar_(registrar),
      textures_(registrar->texture_registrar()),
      channel_(std::move(channel)) {
  if (flutter::FlutterView* view = registrar->GetView()) {
    window_ = GetAncestor(view->GetNativeWindow(), GA_ROOT);
  }
  proc_id_ = registrar->RegisterTopLevelWindowProcDelegate(
      [this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
        return HandleWindowProc(hwnd, message, wparam, lparam);
      });
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
}

LoafMediaPlugin::~LoafMediaPlugin() {
  registrar_->UnregisterTopLevelWindowProcDelegate(proc_id_);
  // Players first: no callback reaches this plugin once they are freed.
  std::vector<int64_t> ids;
  for (const auto& [id, view] : views_) ids.push_back(id);
  for (int64_t id : ids) Dispose(id);
}

void LoafMediaPlugin::FrameArrived(VideoView* view) {
  textures_->MarkTextureFrameAvailable(view->texture_id);
  // Readiness and failure are told on the platform thread, once a batch.
  if (window_ != nullptr && !view->check_posted.exchange(true)) {
    PostMessageW(window_, kStatusMessage, static_cast<WPARAM>(view->view), 0);
  }
}

std::optional<LRESULT> LoafMediaPlugin::HandleWindowProc(HWND, UINT message,
                                                         WPARAM wparam,
                                                         LPARAM) {
  if (message == kStatusMessage) {
    CheckStatus(static_cast<int64_t>(wparam));
    return 0;
  }
  if (message == kImageMessage) {
    std::unique_ptr<ImageJob> job(reinterpret_cast<ImageJob*>(wparam));
    if (job->image == nullptr) {
      job->result->Error(kFailed, "WIC could not decode this picture");
      return 0;
    }
    std::vector<uint8_t> pixels(
        job->pixels, job->pixels + size_t{job->width} * job->height * 4);
    loaf_win_image_free(job->image);
    job->result->Success(EncodableValue(EncodableMap{
        {EncodableValue("width"), EncodableValue(static_cast<int64_t>(job->width))},
        {EncodableValue("height"), EncodableValue(static_cast<int64_t>(job->height))},
        {EncodableValue("pixels"), EncodableValue(std::move(pixels))},
    }));
    return 0;
  }
  return std::nullopt;
}

void LoafMediaPlugin::CheckStatus(int64_t view_id) {
  auto it = views_.find(view_id);
  if (it == views_.end()) return;  // Disposed since.
  VideoView* view = it->second;
  view->check_posted = false;
  if (view->failed) return;
  int32_t ready = 0, error = 0;
  if (loaf_win_player_status(view->player, &ready, &error) != 0 || error) {
    view->failed = true;
    channel_->InvokeMethod("video.failed",
                           std::make_unique<EncodableValue>(EncodableMap{
                               {EncodableValue("view"), EncodableValue(view_id)}}));
    return;
  }
  if (ready && !view->ready) {
    view->ready = true;
    channel_->InvokeMethod("video.ready",
                           std::make_unique<EncodableValue>(EncodableMap{
                               {EncodableValue("view"), EncodableValue(view_id)}}));
  }
}

void LoafMediaPlugin::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<Result> result) {
  const std::string& method = call.method_name();
  const auto* args = std::get_if<EncodableMap>(call.arguments());
  if (args == nullptr) {
    result->NotImplemented();
    return;
  }
  if (method.rfind("stream.", 0) == 0) {
    StreamCall(method, *args, *result);
  } else if (method == "video.create") {
    VideoCreate(*args, *result);
  } else if (method.rfind("video.", 0) == 0) {
    VideoCall(method, *args, *result);
  } else if (method == "defaultAppName") {
    const std::string* extension = StringArg(*args, "extension");
    char name[512];
    int32_t length = extension == nullptr
                         ? -2
                         : loaf_win_default_app_name(extension->c_str(), name,
                                                     sizeof name);
    if (length < 0) {
      result->Success();
    } else {
      result->Success(EncodableValue(std::string(name, length)));
    }
  } else if (method == "openWithDefaultApp") {
    const std::string* path = StringArg(*args, "path");
    if (path == nullptr) {
      result->Error(kFailed, "no path");
      return;
    }
    Status(*result, loaf_win_open(path->c_str()), "open");
  } else if (method == "image.decode") {
    DecodeImage(*args, std::move(result));
  } else {
    result->NotImplemented();
  }
}

void LoafMediaPlugin::StreamCall(const std::string& method,
                                 const EncodableMap& args, Result& result) {
  const std::string* id = StringArg(args, "id");
  if (id == nullptr) {
    result.Error(kFailed, "no stream id");
    return;
  }
  if (method == "stream.end") {
    Status(result, loaf_win_stream_end(id->c_str()), method);
    return;
  }
  int64_t received = IntArg(args, "received", 0);
  int64_t total = IntArg(args, "total", -1);
  int32_t complete = BoolArg(args, "complete");
  int32_t failed = BoolArg(args, "failed");
  if (method == "stream.begin") {
    const std::string* path = StringArg(args, "path");
    if (path == nullptr) {
      result.Error(kFailed, "no path");
      return;
    }
    int32_t status =
        loaf_win_stream_begin(id->c_str(), path->c_str(), received, total);
    if (status != 0) {
      Status(result, status, method);
      return;
    }
    // Begin carries the whole progress, which may already be complete or
    // failed (a stream begun again after a retry).
  }
  Status(result,
         loaf_win_stream_progress(id->c_str(), received, total, complete, failed),
         "stream.progress");
}

void LoafMediaPlugin::VideoCreate(const EncodableMap& args, Result& result) {
  const std::string* id = StringArg(args, "id");
  if (id == nullptr) {
    result.Error(kFailed, "no file id");
    return;
  }
  if (!video_tried_) {
    video_tried_ = true;
    video_ = loaf_win_init() == 0;
  }
  if (!video_) {
    result.Error(kFailed, "Media Foundation did not start");
    return;
  }

  auto* view = new VideoView();
  view->plugin = this;
  view->view = ++next_view_;
  // The texture first, so the player's first frame has somewhere to go.
  view->texture = std::make_unique<flutter::TextureVariant>(
      flutter::GpuSurfaceTexture(
          kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
          [view](size_t, size_t) -> const FlutterDesktopGpuSurfaceDescriptor* {
            std::lock_guard<std::mutex> guard(view->lock);
            if (view->player == nullptr) return nullptr;
            void* handle = nullptr;
            uint32_t width = 0, height = 0;
            const void* frame = loaf_win_player_take_frame(view->player, &handle,
                                                           &width, &height);
            if (frame == nullptr) return nullptr;
            auto* lent = new Lent();
            lent->frame = frame;
            auto& d = lent->descriptor;
            d.struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
            d.handle = handle;
            d.width = d.visible_width = width;
            d.height = d.visible_height = height;
            d.format = kFlutterDesktopPixelFormatBGRA8888;
            d.release_callback = ReleaseLent;
            d.release_context = lent;
            return &lent->descriptor;
          }));
  view->texture_id = textures_->RegisterTexture(view->texture.get());
  if (view->texture_id < 0) {
    delete view;
    result.Error(kFailed, "the texture was refused");
    return;
  }

  std::string extension = ExtensionFor(StringArg(args, "mime"));
  void* player =
      loaf_win_player_new(id->c_str(), extension.c_str(), OnFrame, view);
  if (player == nullptr) {
    textures_->UnregisterTexture(view->texture_id, [view] { delete view; });
    result.Error(kFailed, "no player for this file");
    return;
  }
  {
    std::lock_guard<std::mutex> guard(view->lock);
    view->player = player;
  }
  views_[view->view] = view;
  result.Success(EncodableValue(EncodableMap{
      {EncodableValue("texture"), EncodableValue(view->texture_id)},
      {EncodableValue("view"), EncodableValue(view->view)},
  }));
}

void LoafMediaPlugin::Dispose(int64_t view_id) {
  auto it = views_.find(view_id);
  if (it == views_.end()) return;
  VideoView* view = it->second;
  views_.erase(it);
  void* player;
  {
    std::lock_guard<std::mutex> guard(view->lock);
    player = view->player;
    view->player = nullptr;
  }
  // Joins the player's threads: no callback after this.
  loaf_win_player_free(player);
  textures_->UnregisterTexture(view->texture_id, [view] { delete view; });
}

void LoafMediaPlugin::VideoCall(const std::string& method,
                                const EncodableMap& args, Result& result) {
  int64_t id = IntArg(args, "view", -1);
  // Pausing or disposing a view that's already gone has nothing to do:
  // Dart may pause a row as it goes.
  if (method == "video.dispose") {
    Dispose(id);
    result.Success();
    return;
  }
  auto it = views_.find(id);
  if (it == views_.end()) {
    if (method == "video.pause") {
      result.Success();
    } else {
      result.Error(kFailed, "no such view");
    }
    return;
  }
  void* player = it->second->player;
  if (method == "video.play") {
    Status(result, loaf_win_player_play(player), method);
  } else if (method == "video.pause") {
    Status(result, loaf_win_player_pause(player), method);
  } else if (method == "video.seek") {
    Status(result, loaf_win_player_seek(player, IntArg(args, "ms", 0)), method);
  } else if (method == "video.mute") {
    Status(result, loaf_win_player_set_muted(player, BoolArg(args, "muted")),
           method);
  } else if (method == "video.state") {
    int64_t position = 0, duration = 0;
    int32_t playing = 0, error = 0;
    int32_t status =
        loaf_win_player_state(player, &position, &duration, &playing, &error);
    if (status != 0) {
      Status(result, status, method);
      return;
    }
    result.Success(EncodableValue(EncodableMap{
        {EncodableValue("position"), EncodableValue(position < 0 ? 0 : position)},
        {EncodableValue("duration"),
         duration < 0 ? EncodableValue() : EncodableValue(duration)},
        {EncodableValue("playing"), EncodableValue(playing != 0)},
        {EncodableValue("error"), EncodableValue(error != 0)},
    }));
  } else {
    result.NotImplemented();
  }
}

void LoafMediaPlugin::DecodeImage(const EncodableMap& args,
                                  std::unique_ptr<Result> result) {
  const EncodableValue* bytes = Lookup(args, "bytes");
  const auto* data =
      bytes == nullptr ? nullptr : std::get_if<std::vector<uint8_t>>(bytes);
  if (data == nullptr || window_ == nullptr) {
    result->Error(kFailed, "no picture to decode");
    return;
  }
  auto job = std::make_unique<ImageJob>();
  job->result = std::move(result);
  job->bytes = *data;
  job->max_width = static_cast<uint32_t>(IntArg(args, "maxWidth", 0));
  HWND window = window_;
  // Decoding a 12 MP HEIC takes long enough to drop frames; off the
  // platform thread, and back on it to answer.
  std::thread([job = std::move(job), window]() mutable {
    HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    job->image = loaf_win_decode_image(job->bytes.data(), job->bytes.size(),
                                       job->max_width, &job->width,
                                       &job->height, &job->pixels);
    if (SUCCEEDED(com)) CoUninitialize();
    ImageJob* raw = job.release();
    if (!PostMessageW(window, kImageMessage, reinterpret_cast<WPARAM>(raw), 0)) {
      loaf_win_image_free(raw->image);
      delete raw;  // The window is gone; so is whoever asked.
    }
  }).detach();
}

}  // namespace loaf_media
