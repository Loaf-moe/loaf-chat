#ifndef LOAF_MEDIA_VIDEO_TEXTURE_H_
#define LOAF_MEDIA_VIDEO_TEXTURE_H_

#include <flutter_linux/flutter_linux.h>

G_BEGIN_DECLS

// One inline video's frames: a pixel buffer texture owning the Rust player
// that fills it.
G_DECLARE_FINAL_TYPE(LoafVideoTexture, loaf_video_texture, LOAF,
                     VIDEO_TEXTURE, FlPixelBufferTexture)

// On the main loop, after the player had something new to show.
typedef void (*LoafVideoChanged)(LoafVideoTexture* texture, gpointer user);

// NULL if the player can't be made. [changed] runs until it is cleared with
// loaf_video_texture_set_changed.
LoafVideoTexture* loaf_video_texture_new(FlTextureRegistrar* registrar,
                                         const char* id,
                                         LoafVideoChanged changed,
                                         gpointer user);

// The Rust player, for as long as the texture lives.
void* loaf_video_texture_get_player(LoafVideoTexture* texture);

void loaf_video_texture_set_changed(LoafVideoTexture* texture,
                                    LoafVideoChanged changed, gpointer user);

G_END_DECLS

#endif  // LOAF_MEDIA_VIDEO_TEXTURE_H_
