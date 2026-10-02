#include "video_texture.h"

#include "include/loaf_media/loaf_media_rs.h"

struct _LoafVideoTexture {
  FlPixelBufferTexture parent_instance;

  // Owned. Freed in dispose, which stops GStreamer's threads, so no frame
  // callback comes after it.
  void* player;

  FlTextureRegistrar* registrar;

  // Set while a mark is queued on the main loop: frames arrive faster than
  // the main loop needs telling, and one queued mark covers them all.
  gint queued;

  LoafVideoChanged changed;
  gpointer changed_user;

  // Shown until the first frame: one transparent pixel.
  uint8_t empty[4];
};

G_DEFINE_TYPE(LoafVideoTexture, loaf_video_texture,
              fl_pixel_buffer_texture_get_type())

static gboolean mark_available(gpointer user_data) {
  LoafVideoTexture* self = LOAF_VIDEO_TEXTURE(user_data);
  g_atomic_int_set(&self->queued, 0);
  // Disposed while the mark was queued: nothing left to show.
  if (self->player == nullptr || self->registrar == nullptr) {
    return G_SOURCE_REMOVE;
  }
  if (self->changed != nullptr) {
    self->changed(self, self->changed_user);
  }
  fl_texture_registrar_mark_texture_frame_available(self->registrar,
                                                    FL_TEXTURE(self));
  return G_SOURCE_REMOVE;
}

// On GStreamer's threads. The texture is reffed for the queued mark and
// unreffed after it, so a view disposed meanwhile is never left dangling.
// g_idle_add rather than g_main_context_invoke: invoke runs the function
// right here when this thread can acquire the main context, and the mark
// and the channel calls behind it belong on the main thread.
static void on_frame(void* user) {
  LoafVideoTexture* self = LOAF_VIDEO_TEXTURE(user);
  if (!g_atomic_int_compare_and_exchange(&self->queued, 0, 1)) {
    return;
  }
  g_idle_add_full(G_PRIORITY_DEFAULT, mark_available, g_object_ref(self),
                  g_object_unref);
}

static gboolean loaf_video_texture_copy_pixels(FlPixelBufferTexture* texture,
                                               const uint8_t** out_buffer,
                                               uint32_t* width,
                                               uint32_t* height,
                                               GError** error) {
  LoafVideoTexture* self = LOAF_VIDEO_TEXTURE(texture);
  if (self->player != nullptr &&
      loaf_rs_player_frame(self->player, out_buffer, width, height) == 1) {
    return TRUE;
  }
  *out_buffer = self->empty;
  *width = 1;
  *height = 1;
  return TRUE;
}

// May run twice: a frame callback racing the last unref takes a reference
// during dispose, and GObject disposes again when that one goes.
static void loaf_video_texture_dispose(GObject* object) {
  LoafVideoTexture* self = LOAF_VIDEO_TEXTURE(object);
  g_clear_pointer(&self->player, loaf_rs_player_free);
  g_clear_object(&self->registrar);
  self->changed = nullptr;
  self->changed_user = nullptr;
  G_OBJECT_CLASS(loaf_video_texture_parent_class)->dispose(object);
}

static void loaf_video_texture_class_init(LoafVideoTextureClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = loaf_video_texture_dispose;
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels =
      loaf_video_texture_copy_pixels;
}

static void loaf_video_texture_init(LoafVideoTexture* self) {
  self->player = nullptr;
  self->registrar = nullptr;
  self->queued = 0;
  self->changed = nullptr;
  self->changed_user = nullptr;
  for (uint8_t& byte : self->empty) {
    byte = 0;
  }
}

LoafVideoTexture* loaf_video_texture_new(FlTextureRegistrar* registrar,
                                         const char* id,
                                         LoafVideoChanged changed,
                                         gpointer user) {
  LoafVideoTexture* self = LOAF_VIDEO_TEXTURE(
      g_object_new(loaf_video_texture_get_type(), nullptr));
  self->registrar = FL_TEXTURE_REGISTRAR(g_object_ref(registrar));
  self->changed = changed;
  self->changed_user = user;
  // The player calls back with the texture itself, which owns it and so
  // outlives every callback.
  self->player = loaf_rs_player_new(id, on_frame, self);
  if (self->player == nullptr) {
    g_object_unref(self);
    return nullptr;
  }
  return self;
}

void* loaf_video_texture_get_player(LoafVideoTexture* self) {
  g_return_val_if_fail(LOAF_IS_VIDEO_TEXTURE(self), nullptr);
  return self->player;
}

void loaf_video_texture_set_changed(LoafVideoTexture* self,
                                    LoafVideoChanged changed, gpointer user) {
  g_return_if_fail(LOAF_IS_VIDEO_TEXTURE(self));
  self->changed = changed;
  self->changed_user = user;
}
