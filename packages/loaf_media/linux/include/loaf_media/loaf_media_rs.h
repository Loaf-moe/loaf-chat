#ifndef FLUTTER_PLUGIN_LOAF_MEDIA_RS_H_
#define FLUTTER_PLUGIN_LOAF_MEDIA_RS_H_

// The Rust half of video on Linux (`linux/rust/src/ffi.rs`): the `loafsrc`
// GStreamer source reading downloads as they arrive, and the players.
//
// Every function returns 0 for OK, or a negative number for an error,
// unless noted: -1 a panic was caught, -2 a string was null or not UTF-8,
// -3 the call failed (no such stream, GStreamer refused), -4 a pointer
// argument was null.

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// gst_init and registers loafsrc; idempotent.
int32_t loaf_rs_init(void);

// [total] is -1 while unknown.
int32_t loaf_rs_stream_begin(const char* id, const char* path,
                             int64_t received, int64_t total);
int32_t loaf_rs_stream_progress(const char* id, int64_t received,
                                int64_t total, int32_t complete,
                                int32_t failed);
// Readers still waiting on the stream fail.
int32_t loaf_rs_stream_end(const char* id);

// Called from GStreamer's threads whenever the player has something new to
// show: a frame, the first preroll, an error, or the end.
typedef void (*loaf_rs_frame_cb)(void* user);

// Prerolls `loaf-media://<id>` paused. NULL on error. [user] must stay
// valid until loaf_rs_player_free returns; no callback comes after that.
void* loaf_rs_player_new(const char* id, loaf_rs_frame_cb on_frame,
                         void* user);
int32_t loaf_rs_player_play(void* p);
int32_t loaf_rs_player_pause(void* p);
int32_t loaf_rs_player_seek(void* p, int64_t position_ms);
int32_t loaf_rs_player_set_muted(void* p, int32_t muted);
// Unknown times are -1.
int32_t loaf_rs_player_state(void* p, int64_t* position_ms,
                             int64_t* duration_ms, int32_t* playing,
                             int32_t* error);
/* Borrows the newest RGBA frame until the next call or free; 1 if there is
 * one. Calls must not overlap. */
int32_t loaf_rs_player_frame(void* p, const uint8_t** rgba, uint32_t* width,
                             uint32_t* height);
void loaf_rs_player_free(void* p);

#ifdef __cplusplus
}
#endif

#endif  // FLUTTER_PLUGIN_LOAF_MEDIA_RS_H_
