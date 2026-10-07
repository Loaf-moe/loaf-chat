#ifndef FLUTTER_PLUGIN_LOAF_MEDIA_WIN_H_
#define FLUTTER_PLUGIN_LOAF_MEDIA_WIN_H_

// The Rust half of package:loaf_media on Windows (`windows/rust/src/ffi.rs`):
// the Media Engine reading downloads as they arrive, the shell's default
// apps, and WIC.
//
// Every function returns 0 for OK, or a negative number for an error,
// unless noted: -1 a panic was caught, -2 a string was null or not UTF-8,
// -3 the call failed (no such stream, Media Foundation refused), -4 a
// pointer argument was null.

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// MFStartup; idempotent.
int32_t loaf_win_init(void);

// [path] is UTF-8. [total] is -1 while unknown.
int32_t loaf_win_stream_begin(const char* id, const char* path,
                              int64_t received, int64_t total);
int32_t loaf_win_stream_progress(const char* id, int64_t received,
                                 int64_t total, int32_t complete,
                                 int32_t failed);
// Readers still waiting on the stream fail.
int32_t loaf_win_stream_end(const char* id);

// Called from the player's threads whenever it has something new to show:
// a frame, readiness, an error, or the end.
typedef void (*loaf_win_frame_cb)(void* user);

// Loads `loaf-media://<id>` paused. [extension] (mp4, mov…) names the
// container. NULL on error. [user] must stay valid until
// loaf_win_player_free returns; no callback comes after that.
void* loaf_win_player_new(const char* id, const char* extension,
                          loaf_win_frame_cb on_frame, void* user);
int32_t loaf_win_player_play(void* p);
int32_t loaf_win_player_pause(void* p);
int32_t loaf_win_player_seek(void* p, int64_t position_ms);
int32_t loaf_win_player_set_muted(void* p, int32_t muted);
// Unknown times are -1.
int32_t loaf_win_player_state(void* p, int64_t* position_ms,
                              int64_t* duration_ms, int32_t* playing,
                              int32_t* error);
// Flags only: cheap enough for every frame.
int32_t loaf_win_player_status(void* p, int32_t* ready, int32_t* error);

// The newest frame as the caller's own reference, or NULL if there is none
// yet. [handle] is its DXGI shared handle (BGRA), valid until
// loaf_win_frame_release, independently of the player.
const void* loaf_win_player_take_frame(void* p, void** handle,
                                       uint32_t* width, uint32_t* height);
// NULL is ignored.
void loaf_win_frame_release(const void* frame);

void loaf_win_player_free(void* p);

// The app files ending `.<extension>` open in, UTF-8, into [out]. Its
// length, or -3 when none is set or [out] is too small.
int32_t loaf_win_default_app_name(const char* extension, char* out,
                                  uint32_t capacity);
// Opens [path] (UTF-8) as Explorer would.
int32_t loaf_win_open(const char* path);

// Decodes with WIC, at most [max_width] wide unless it is 0, to
// premultiplied RGBA. NULL if WIC can't; else free with loaf_win_image_free.
void* loaf_win_decode_image(const uint8_t* bytes, size_t len,
                            uint32_t max_width, uint32_t* width,
                            uint32_t* height, const uint8_t** pixels);
void loaf_win_image_free(void* image);

#ifdef __cplusplus
}
#endif

#endif  // FLUTTER_PLUGIN_LOAF_MEDIA_WIN_H_
