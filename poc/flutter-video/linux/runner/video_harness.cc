// The Dart app's WebRTC video path on Linux, fed synthetic frames.
//
// This reproduces flutter_webrtc (Loaf-moe fork 5462125) exactly where it
// costs anything: an FlPixelBufferTexture per renderer whose copy_pixels runs
// RTCVideoFrame::ConvertToARGB(kABGR) on the latest frame under the
// renderer's mutex (common/cpp/src/flutter_video_renderer.cc,
// CopyPixelBuffer), and fl_texture_registrar_mark_texture_frame_available
// called straight from the thread that delivers the frame (OnFrame). The
// libwebrtc is the same prebuilt libwebrtc.so (m150.7871.03) the fork bundles.
//
// The frames are the GPUI PoC's: BT.709 limited-range colour bars over a
// luma ramp with a moving white bar, rows padded by 32 bytes. They are built
// once as RTCVideoFrames and shared, so producing a frame costs nothing and
// what the process spends is the display path alone.

#include "video_harness.h"

#include <rtc_video_frame.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

using libwebrtc::RTCVideoFrame;
using libwebrtc::scoped_refptr;

namespace {

constexpr int kLoop = 60;
constexpr int kStridePad = 32;

struct Bar {
  uint8_t y, u, v;
};

// 100% colour bars, BT.709 limited range: white, yellow, cyan, green,
// magenta, red, blue, black.
constexpr Bar kBars[8] = {{235, 128, 128}, {219, 16, 138}, {188, 154, 16},
                          {173, 42, 26},   {78, 214, 230}, {63, 102, 240},
                          {32, 240, 118},  {16, 128, 128}};

scoped_refptr<RTCVideoFrame> Synth(int width, int height, int step) {
  const int cw = width / 2, ch = height / 2;
  const int ys = width + kStridePad, cs = cw + kStridePad;
  std::vector<uint8_t> y(size_t(ys) * height), u(size_t(cs) * ch),
      v(size_t(cs) * ch);

  const int bar_x = (step * width / kLoop) & ~1;
  const int bar_w = std::max(width / 32, 2) & ~1;
  const int bars_end = height * 2 / 3;
  auto sample = [&](int x, int row) -> Bar {
    if (row < bars_end) return kBars[x * 8 / width];
    if (x >= bar_x && x < bar_x + bar_w) return kBars[0];
    return Bar{uint8_t(16 + x * 219 / width), 128, 128};
  };

  for (int row = 0; row < height; row++)
    for (int x = 0; x < width; x++) y[size_t(row) * ys + x] = sample(x, row).y;
  for (int row = 0; row < ch; row++)
    for (int x = 0; x < cw; x++) {
      Bar b = sample(x * 2, row * 2);
      u[size_t(row) * cs + x] = b.u;
      v[size_t(row) * cs + x] = b.v;
    }
  return RTCVideoFrame::Create(width, height, y.data(), ys, u.data(), cs,
                               v.data(), cs);
}

std::atomic<uint64_t> g_delivered{0};
std::atomic<uint64_t> g_copies{0};

// One renderer: FlutterVideoRenderer's state, minus the event channel.
struct Renderer {
  std::mutex mutex;
  scoped_refptr<RTCVideoFrame> frame;
  std::unique_ptr<uint8_t[]> rgb;
  uint32_t width = 0, height = 0;
};

}  // namespace

// --- HarnessTexture: FlPixelBufferTexture over a Renderer ------------------

struct HarnessTexture {
  FlPixelBufferTexture parent_instance;
  Renderer* renderer;
};

struct HarnessTextureClass {
  FlPixelBufferTextureClass parent_class;
};

G_DEFINE_TYPE(HarnessTexture, harness_texture, fl_pixel_buffer_texture_get_type())

#define HARNESS_TEXTURE(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), harness_texture_get_type(), HarnessTexture))

// flutter_webrtc's CopyPixelBuffer, step for step.
static gboolean harness_texture_copy_pixels(FlPixelBufferTexture* texture,
                                            const uint8_t** out_buffer,
                                            uint32_t* width, uint32_t* height,
                                            GError** error) {
  Renderer* r = reinterpret_cast<HarnessTexture*>(texture)->renderer;
  std::lock_guard<std::mutex> lock(r->mutex);
  if (!r->frame.get()) return TRUE;
  if (r->width != uint32_t(r->frame->width()) ||
      r->height != uint32_t(r->frame->height())) {
    r->rgb.reset(new uint8_t[size_t(r->frame->width()) * r->frame->height() * 4]);
    r->width = r->frame->width();
    r->height = r->frame->height();
  }
  r->frame->ConvertToARGB(RTCVideoFrame::Type::kABGR, r->rgb.get(), 0,
                          int(r->width), int(r->height));
  g_copies.fetch_add(1, std::memory_order_relaxed);
  *out_buffer = r->rgb.get();
  *width = r->width;
  *height = r->height;
  return TRUE;
}

static void harness_texture_class_init(HarnessTextureClass* klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels = harness_texture_copy_pixels;
}

static void harness_texture_init(HarnessTexture* self) {}

// --- The harness -----------------------------------------------------------

namespace {

struct Harness {
  FlTextureRegistrar* registrar = nullptr;
  FlMethodChannel* channel = nullptr;
  std::vector<std::unique_ptr<Renderer>> renderers;
  std::vector<FlTexture*> textures;
  std::vector<std::thread> producers;
  std::shared_ptr<const std::vector<scoped_refptr<RTCVideoFrame>>> frames;
  std::atomic<bool> stop{false};
};

Harness* g_harness = nullptr;

void Stop(Harness* h) {
  h->stop = true;
  for (auto& t : h->producers) t.join();
  h->producers.clear();
}

FlValue* Start(Harness* h, int tiles, int width, int height, int fps, bool idle) {
  auto frames = std::make_shared<std::vector<scoped_refptr<RTCVideoFrame>>>();
  for (int step = 0; step < kLoop; step++) frames->push_back(Synth(width, height, step));
  h->frames = frames;

  FlValue* ids = fl_value_new_list();
  for (int i = 0; i < tiles; i++) {
    auto renderer = std::make_unique<Renderer>();
    // Streams start out of phase, as real participants do.
    const int phase = i * kLoop / 4;
    renderer->frame = (*frames)[phase % kLoop];

    auto* texture = HARNESS_TEXTURE(g_object_new(harness_texture_get_type(), nullptr));
    texture->renderer = renderer.get();
    FlTexture* fl_texture = FL_TEXTURE(texture);
    fl_texture_registrar_register_texture(h->registrar, fl_texture);
    fl_texture_registrar_mark_texture_frame_available(h->registrar, fl_texture);
    fl_value_append_take(ids, fl_value_new_int(fl_texture_get_id(fl_texture)));

    if (!idle) {
      Renderer* r = renderer.get();
      FlTextureRegistrar* registrar = h->registrar;
      h->producers.emplace_back([h, r, registrar, fl_texture, frames, phase, fps] {
        using clock = std::chrono::steady_clock;
        const auto period = std::chrono::duration_cast<clock::duration>(
            std::chrono::duration<double>(1.0 / fps));
        auto next = clock::now() + period;
        int step = phase;
        while (!h->stop.load(std::memory_order_relaxed)) {
          std::this_thread::sleep_until(next);
          next += period;
          step = (step + 1) % kLoop;
          {
            // OnFrame: swap the frame under the mutex, then mark it available
            // from this (the decoder's) thread.
            std::lock_guard<std::mutex> lock(r->mutex);
            r->frame = (*frames)[step];
          }
          g_delivered.fetch_add(1, std::memory_order_relaxed);
          fl_texture_registrar_mark_texture_frame_available(registrar, fl_texture);
        }
      });
    }
    h->renderers.push_back(std::move(renderer));
    h->textures.push_back(fl_texture);
  }
  return ids;
}

int64_t IntArg(FlValue* args, const char* key, int64_t fallback) {
  FlValue* v = fl_value_lookup_string(args, key);
  return v && fl_value_get_type(v) == FL_VALUE_TYPE_INT ? fl_value_get_int(v) : fallback;
}

void OnCall(FlMethodChannel* channel, FlMethodCall* call, gpointer user_data) {
  auto* h = static_cast<Harness*>(user_data);
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (g_strcmp0(method, "start") == 0 && args &&
      fl_value_get_type(args) == FL_VALUE_TYPE_MAP && h->textures.empty()) {
    FlValue* idle = fl_value_lookup_string(args, "idle");
    FlValue* ids = Start(h, int(IntArg(args, "tiles", 4)), int(IntArg(args, "width", 1280)),
                         int(IntArg(args, "height", 720)), int(IntArg(args, "fps", 30)),
                         idle && fl_value_get_bool(idle));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(ids));
    fl_value_unref(ids);
  } else if (g_strcmp0(method, "stats") == 0) {
    g_autoptr(FlValue) stats = fl_value_new_list();
    fl_value_append_take(stats, fl_value_new_int(int64_t(g_delivered.load())));
    fl_value_append_take(stats, fl_value_new_int(int64_t(g_copies.load())));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(stats));
  } else if (g_strcmp0(method, "stop") == 0) {
    Stop(h);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

}  // namespace

void video_harness_register(FlView* view) {
  FlEngine* engine = fl_view_get_engine(view);
  g_harness = new Harness();
  g_harness->registrar = fl_engine_get_texture_registrar(engine);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_harness->channel = fl_method_channel_new(fl_engine_get_binary_messenger(engine),
                                             "poc/video", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_harness->channel, OnCall, g_harness, nullptr);
}
