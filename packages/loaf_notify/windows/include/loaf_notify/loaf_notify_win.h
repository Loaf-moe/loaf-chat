#ifndef FLUTTER_PLUGIN_LOAF_NOTIFY_WIN_H_
#define FLUTTER_PLUGIN_LOAF_NOTIFY_WIN_H_

// The Rust half of package:loaf_notify on Windows (`windows/rust/src/ffi.rs`):
// toasts through ToastNotificationManager under the app's AUMID.
//
// Functions returning int32_t return 0 for OK, or a negative number for an
// error: -1 a panic was caught, -2 a string was null or not UTF-8, -3 the
// call failed (WinRT refused), -4 a pointer argument was null. Strings are
// UTF-8 and NUL-terminated.

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Called on a WinRT thread when a toast is clicked. Both strings are valid
// only until it returns: copy them, and hand them to the platform thread.
typedef void (*loaf_notify_click_fn)(void* context, const char* room_id,
                                     const char* event_id);

// Null on failure. [context] goes back to [click] and must outlive the
// notifier.
void* loaf_notify_new(loaf_notify_click_fn click, void* context);
void loaf_notify_free(void* notifier);

// Registers the app's name and icon under HKCU for its AUMID.
int32_t loaf_notify_register(void);

// [avatar] is a path to a picture, or null.
int32_t loaf_notify_show(void* notifier, const char* title, const char* body,
                         const char* room_id, const char* event_id,
                         const char* avatar);

// Removes the room's toasts from the Action Center.
int32_t loaf_notify_withdraw(void* notifier, const char* room_id);

// 1 blocked, 0 not, < 0 error.
int32_t loaf_notify_blocked(void);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // FLUTTER_PLUGIN_LOAF_NOTIFY_WIN_H_
