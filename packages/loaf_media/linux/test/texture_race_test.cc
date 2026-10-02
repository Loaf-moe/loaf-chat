// Hammers copy_pixels from a thread standing in for the embedder's raster
// thread, while the main thread attaches and detaches players under it, as
// rows come and go during playback. Built with AddressSanitizer, so a frame
// or player freed under copy_pixels is a crash rather than luck.
//
// Opt-in, after `flutter build linux --debug`:
//   cmake -DLOAF_MEDIA_TESTS=ON build/linux/<arch>/debug
//   cmake --build build/linux/<arch>/debug --target loaf_media_texture_race_test
//   ASAN_OPTIONS=detect_leaks=0 G_SLICE=always-malloc \
//     LD_LIBRARY_PATH=linux/flutter/ephemeral \
//     build/linux/<arch>/debug/plugins/loaf_media/loaf_media_texture_race_test \
//     assets/mock/media/proof.mp4

#include <glib/gstdio.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <random>
#include <thread>

#include "../include/loaf_media/loaf_media_rs.h"
#include "../video_texture.h"

// A registrar that accepts everything: the embedder's needs an engine.
G_DECLARE_FINAL_TYPE(FakeRegistrar, fake_registrar, FAKE, REGISTRAR, GObject)

struct _FakeRegistrar {
  GObject parent_instance;
  int marks;
};

static gboolean fake_register(FlTextureRegistrar*, FlTexture*) {
  return TRUE;
}

static FlTexture* fake_lookup(FlTextureRegistrar*, int64_t) {
  return nullptr;
}

static gboolean fake_mark(FlTextureRegistrar* registrar, FlTexture*) {
  FAKE_REGISTRAR(registrar)->marks++;
  return TRUE;
}

static gboolean fake_unregister(FlTextureRegistrar*, FlTexture*) {
  return TRUE;
}

static void fake_shutdown(FlTextureRegistrar*) {}

static void fake_registrar_iface_init(FlTextureRegistrarInterface* iface) {
  iface->register_texture = fake_register;
  iface->lookup_texture = fake_lookup;
  iface->mark_texture_frame_available = fake_mark;
  iface->unregister_texture = fake_unregister;
  iface->shutdown = fake_shutdown;
}

G_DEFINE_TYPE_WITH_CODE(FakeRegistrar,
                        fake_registrar,
                        G_TYPE_OBJECT,
                        G_IMPLEMENT_INTERFACE(fl_texture_registrar_get_type(),
                                              fake_registrar_iface_init))

static void fake_registrar_class_init(FakeRegistrarClass*) {}
static void fake_registrar_init(FakeRegistrar* self) {
  self->marks = 0;
}

int main(int argc, char** argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s <video file>\n", argv[0]);
    return 2;
  }
  GStatBuf info;
  if (g_stat(argv[1], &info) != 0) {
    fprintf(stderr, "can't read %s\n", argv[1]);
    return 2;
  }
  if (loaf_rs_init() != 0) {
    fprintf(stderr, "GStreamer did not start\n");
    return 1;
  }
  // The whole file, already downloaded.
  loaf_rs_stream_begin("race", argv[1], info.st_size, info.st_size);
  loaf_rs_stream_progress("race", info.st_size, info.st_size, 1, 0);

  FakeRegistrar* registrar =
      FAKE_REGISTRAR(g_object_new(fake_registrar_get_type(), nullptr));
  LoafVideoTexture* texture =
      loaf_video_texture_new(FL_TEXTURE_REGISTRAR(registrar));
  FlPixelBufferTextureClass* klass = FL_PIXEL_BUFFER_TEXTURE_GET_CLASS(texture);

  std::atomic<bool> stop{false};
  std::atomic<long> copies{0}, frames{0};
  std::atomic<uint64_t> sink{0};
  // The raster thread is sometimes held up, by the scheduler or a slow GL
  // upload, with the texture found or its buffer in hand: the embedder
  // promises nothing about how long.
  std::mt19937 jitter(11);
  auto stall = [&jitter] {
    if (jitter() % 64 == 0) {
      std::this_thread::sleep_for(std::chrono::milliseconds(jitter() % 25));
    }
  };
  std::thread raster([&] {
    while (!stop.load()) {
      stall();
      const uint8_t* buffer = nullptr;
      uint32_t width = 0, height = 0;
      klass->copy_pixels(FL_PIXEL_BUFFER_TEXTURE(texture), &buffer, &width,
                         &height, nullptr);
      stall();
      // Read the buffer as the GL upload would, after copy_pixels returned.
      size_t len = static_cast<size_t>(width) * height * 4;
      uint64_t sum = buffer[len - 1];
      for (size_t i = 0; i < len; i += 61) {
        sum += buffer[i];
      }
      sink += sum;
      copies++;
      if (width > 1) {
        frames++;
      }
    }
  });

  std::mt19937 random(7);
  const int rounds = 30;
  for (int round = 0; round < rounds; round++) {
    if (!loaf_video_texture_attach(texture, "race", nullptr, nullptr)) {
      fprintf(stderr, "no player in round %d\n", round);
      return 1;
    }
    void* player = loaf_video_texture_get_player(texture);
    loaf_rs_player_set_muted(player, 1);
    loaf_rs_player_play(player);
    auto until = std::chrono::steady_clock::now() +
                 std::chrono::milliseconds(20 + random() % 150);
    while (std::chrono::steady_clock::now() < until) {
      // The main loop's marks, as in the app.
      while (g_main_context_iteration(nullptr, FALSE)) {
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    // Mid-playback, with copy_pixels running.
    loaf_video_texture_detach(texture);
  }
  stop.store(true);
  raster.join();
  while (g_main_context_iteration(nullptr, FALSE)) {
  }

  printf("rounds %d, copies %ld, with a frame %ld, marks %d\n", rounds,
         copies.load(), frames.load(), registrar->marks);
  g_object_unref(texture);
  g_object_unref(registrar);
  loaf_rs_stream_end("race");
  return frames.load() > 0 ? 0 : 1;
}
