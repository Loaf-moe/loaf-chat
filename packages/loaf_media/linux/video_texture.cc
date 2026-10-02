#include "video_texture.h"

#include "include/loaf_media/loaf_media_rs.h"

struct _LoafVideoTexture {
  FlPixelBufferTexture parent_instance;

  // Guards [player] and the lent frame: copy_pixels runs on the raster
  // thread, attach and detach on the main thread.
  GMutex lock;

  // Owned; NULL while detached.
  void* player;

  // The frame the last copy_pixels handed the engine, held as this
  // texture's own reference so it stays whole while the engine uploads it,
  // whatever happens to the player meanwhile. Only copy_pixels replaces it
  // (the engine is done with the previous buffer by its next call), and
  // finalize releases it.
  const LoafRsFrame* lent;
  const uint8_t* lent_rgba;
  uint32_t lent_width;
  uint32_t lent_height;
  // Set on attach: the lent frame is the last video's, not to be shown.
  gboolean lent_stale;

  FlTextureRegistrar* registrar;

  // Set while a mark is queued on the main loop: frames arrive faster than
  // the main loop needs telling, and one queued mark covers them all.
  gint queued;

  // Main thread only.
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
  // Detached while the mark was queued: nothing to show. A mark queued by
  // an earlier player only makes the current one's owner look again.
  if (self->player == nullptr) {
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
// unreffed after it. g_idle_add rather than g_main_context_invoke: invoke
// runs the function right here when this thread can acquire the main
// context, and the mark and the channel calls behind it belong on the main
// thread.
static void on_frame(void* user) {
  LoafVideoTexture* self = LOAF_VIDEO_TEXTURE(user);
  if (!g_atomic_int_compare_and_exchange(&self->queued, 0, 1)) {
    return;
  }
  g_idle_add_full(G_PRIORITY_DEFAULT, mark_available, g_object_ref(self),
                  g_object_unref);
}

// On the raster thread.
static gboolean loaf_video_texture_copy_pixels(FlPixelBufferTexture* texture,
                                               const uint8_t** out_buffer,
                                               uint32_t* width,
                                               uint32_t* height,
                                               GError** error) {
  LoafVideoTexture* self = LOAF_VIDEO_TEXTURE(texture);
  g_mutex_lock(&self->lock);
  if (self->player != nullptr) {
    const uint8_t* rgba = nullptr;
    uint32_t w = 0, h = 0;
    const LoafRsFrame* frame =
        loaf_rs_player_take_frame(self->player, &rgba, &w, &h);
    if (frame != nullptr) {
      loaf_rs_frame_release(self->lent);
      self->lent = frame;
      self->lent_rgba = rgba;
      self->lent_width = w;
      self->lent_height = h;
      self->lent_stale = FALSE;
    }
  }
  if (self->lent != nullptr && !self->lent_stale) {
    *out_buffer = self->lent_rgba;
    *width = self->lent_width;
    *height = self->lent_height;
  } else {
    *out_buffer = self->empty;
    *width = 1;
    *height = 1;
  }
  g_mutex_unlock(&self->lock);
  return TRUE;
}

void loaf_video_texture_detach(LoafVideoTexture* self) {
  g_return_if_fail(LOAF_IS_VIDEO_TEXTURE(self));
  self->changed = nullptr;
  self->changed_user = nullptr;
  g_mutex_lock(&self->lock);
  void* player = self->player;
  self->player = nullptr;
  g_mutex_unlock(&self->lock);
  // Outside the lock, so a frame being drawn isn't held up by GStreamer
  // stopping. Nothing on the raster thread can reach the player now, and
  // any frame it holds is the texture's own.
  loaf_rs_player_free(player);
}

gboolean loaf_video_texture_attach(LoafVideoTexture* self, const char* id,
                                   LoafVideoChanged changed, gpointer user) {
  g_return_val_if_fail(LOAF_IS_VIDEO_TEXTURE(self), FALSE);
  g_return_val_if_fail(self->player == nullptr, FALSE);
  // The player calls back with the texture itself, which outlives it: the
  // player is freed on detach or finalize, and the texture is recycled.
  void* player = loaf_rs_player_new(id, on_frame, self);
  if (player == nullptr) {
    return FALSE;
  }
  self->changed = changed;
  self->changed_user = user;
  g_mutex_lock(&self->lock);
  self->player = player;
  self->lent_stale = TRUE;
  g_mutex_unlock(&self->lock);
  return TRUE;
}

void* loaf_video_texture_get_player(LoafVideoTexture* self) {
  g_return_val_if_fail(LOAF_IS_VIDEO_TEXTURE(self), nullptr);
  return self->player;
}

static void loaf_video_texture_dispose(GObject* object) {
  LoafVideoTexture* self = LOAF_VIDEO_TEXTURE(object);
  loaf_video_texture_detach(self);
  g_clear_object(&self->registrar);
  G_OBJECT_CLASS(loaf_video_texture_parent_class)->dispose(object);
}

static void loaf_video_texture_finalize(GObject* object) {
  LoafVideoTexture* self = LOAF_VIDEO_TEXTURE(object);
  loaf_rs_frame_release(self->lent);
  self->lent = nullptr;
  g_mutex_clear(&self->lock);
  G_OBJECT_CLASS(loaf_video_texture_parent_class)->finalize(object);
}

static void loaf_video_texture_class_init(LoafVideoTextureClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = loaf_video_texture_dispose;
  G_OBJECT_CLASS(klass)->finalize = loaf_video_texture_finalize;
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels =
      loaf_video_texture_copy_pixels;
}

static void loaf_video_texture_init(LoafVideoTexture* self) {
  g_mutex_init(&self->lock);
  self->player = nullptr;
  self->lent = nullptr;
  self->lent_rgba = nullptr;
  self->lent_width = 0;
  self->lent_height = 0;
  self->lent_stale = FALSE;
  self->registrar = nullptr;
  self->queued = 0;
  self->changed = nullptr;
  self->changed_user = nullptr;
  for (uint8_t& byte : self->empty) {
    byte = 0;
  }
}

LoafVideoTexture* loaf_video_texture_new(FlTextureRegistrar* registrar) {
  LoafVideoTexture* self = LOAF_VIDEO_TEXTURE(
      g_object_new(loaf_video_texture_get_type(), nullptr));
  self->registrar = FL_TEXTURE_REGISTRAR(g_object_ref(registrar));
  return self;
}
