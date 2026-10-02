#ifndef LOAF_MEDIA_VIDEO_TEXTURE_H_
#define LOAF_MEDIA_VIDEO_TEXTURE_H_

#include <flutter_linux/flutter_linux.h>

G_BEGIN_DECLS

// The frames of one inline video at a time: a pixel buffer texture with a
// Rust player attached.
//
// A texture is recycled, never finalized while the engine runs. The
// embedder's raster thread finds a texture without taking a reference
// (fl_texture_registrar.cc lookup_texture) and draws it outside any lock,
// and unregistering only posts a task to the raster thread
// (Shell::OnPlatformViewUnregisterTexture) with nothing to say when it ran.
// No moment after unregistering is known safe for the last unref, so the
// plugin keeps detached textures for the next video instead.
G_DECLARE_FINAL_TYPE(LoafVideoTexture, loaf_video_texture, LOAF,
                     VIDEO_TEXTURE, FlPixelBufferTexture)

// On the main loop, after the player had something new to show.
typedef void (*LoafVideoChanged)(LoafVideoTexture* texture, gpointer user);

LoafVideoTexture* loaf_video_texture_new(FlTextureRegistrar* registrar);

// Makes a player for the file [id] and shows its frames. FALSE if no player
// could be made. Main thread; the texture must be detached.
gboolean loaf_video_texture_attach(LoafVideoTexture* texture, const char* id,
                                   LoafVideoChanged changed, gpointer user);

// Stops and frees the player at once (sound stops, GStreamer's threads are
// joined), safely against a frame being drawn on the raster thread. The
// texture can then be attached again. Main thread.
void loaf_video_texture_detach(LoafVideoTexture* texture);

// The attached player, or NULL. Main thread only: the main thread is the
// only one that attaches and detaches.
void* loaf_video_texture_get_player(LoafVideoTexture* texture);

G_END_DECLS

#endif  // LOAF_MEDIA_VIDEO_TEXTURE_H_
