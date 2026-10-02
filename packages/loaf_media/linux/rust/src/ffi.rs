//! The C API in `include/loaf_media/loaf_media_rs.h`, for the plugin's
//! glue. Functions return 0 for OK and a negative number for an error.
//! Nothing may unwind into C, so every body runs under `catch_unwind`.

use std::ffi::{CStr, c_char, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::PathBuf;
use std::ptr;

use crate::player::Player;
use crate::streams::{self, Progress};

const OK: i32 = 0;
/// A panic was caught: a bug, reported rather than crashing the app.
const PANICKED: i32 = -1;
/// A string argument was null or not UTF-8.
const BAD_STRING: i32 = -2;
/// The call itself failed: no such stream, GStreamer refused, …
const FAILED: i32 = -3;
/// A pointer argument was null.
const NULL: i32 = -4;

fn guard(f: impl FnOnce() -> i32) -> i32 {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(PANICKED)
}

/// # Safety
/// [s] is null or a NUL-terminated string that outlives the call.
unsafe fn string<'a>(s: *const c_char) -> Result<&'a str, i32> {
    if s.is_null() {
        return Err(BAD_STRING);
    }
    // SAFETY: non-null and NUL-terminated by the caller's contract.
    unsafe { CStr::from_ptr(s) }
        .to_str()
        .map_err(|_| BAD_STRING)
}

/// A negative size means not known yet.
fn known(n: i64) -> Option<u64> {
    u64::try_from(n).ok()
}

fn status<E: std::fmt::Display>(what: &str, result: Result<(), E>) -> i32 {
    match result {
        Ok(()) => OK,
        Err(e) => {
            eprintln!("[loaf media] {what}: {e}");
            FAILED
        }
    }
}

/// # Safety
/// [p] is null or came from `loaf_rs_player_new` and is not yet freed.
unsafe fn player<'a>(p: *mut c_void) -> Result<&'a Player, i32> {
    // SAFETY: by the caller's contract it is null or a live Box<Player>.
    unsafe { p.cast::<Player>().as_ref() }.ok_or(NULL)
}

#[unsafe(no_mangle)]
pub extern "C" fn loaf_rs_init() -> i32 {
    guard(|| status("init", crate::init()))
}

/// # Safety
/// [id] and [path] are NUL-terminated strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_rs_stream_begin(
    id: *const c_char,
    path: *const c_char,
    received: i64,
    total: i64,
) -> i32 {
    guard(|| {
        // SAFETY: forwarded from this function's contract.
        let (id, path) = match unsafe { (string(id), string(path)) } {
            (Ok(id), Ok(path)) => (id, path),
            (Err(e), _) | (_, Err(e)) => return e,
        };
        let progress = Progress {
            received: known(received).unwrap_or(0),
            total: known(total),
            complete: false,
            failed: false,
        };
        streams::begin(id, PathBuf::from(path), progress);
        OK
    })
}

/// # Safety
/// [id] is a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_rs_stream_progress(
    id: *const c_char,
    received: i64,
    total: i64,
    complete: i32,
    failed: i32,
) -> i32 {
    guard(|| {
        // SAFETY: forwarded from this function's contract.
        let id = match unsafe { string(id) } {
            Ok(id) => id,
            Err(e) => return e,
        };
        let progress = Progress {
            received: known(received).unwrap_or(0),
            total: known(total),
            complete: complete != 0,
            failed: failed != 0,
        };
        status("progress", streams::progress(id, progress))
    })
}

/// # Safety
/// [id] is a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_rs_stream_end(id: *const c_char) -> i32 {
    guard(|| {
        // SAFETY: forwarded from this function's contract.
        match unsafe { string(id) } {
            Ok(id) => status("end", streams::end(id)),
            Err(e) => e,
        }
    })
}

pub type FrameCallback = Option<unsafe extern "C" fn(user: *mut c_void)>;

/// The C callback and its argument, called from GStreamer's threads.
struct OnFrame {
    callback: unsafe extern "C" fn(*mut c_void),
    user: *mut c_void,
}

// SAFETY: the header documents that the callback is called from any
// thread; the plugin's callback only takes a reference and queues work on
// the main loop, and keeps [user] alive until the player is freed.
unsafe impl Send for OnFrame {}
unsafe impl Sync for OnFrame {}

impl OnFrame {
    fn call(&self) {
        // SAFETY: see the Send/Sync impls above.
        unsafe { (self.callback)(self.user) }
    }
}

/// # Safety
/// [id] is a NUL-terminated string; [user] stays valid until
/// `loaf_rs_player_free` returns.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_rs_player_new(
    id: *const c_char,
    on_frame: FrameCallback,
    user: *mut c_void,
) -> *mut c_void {
    catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: forwarded from this function's contract.
        let Ok(id) = (unsafe { string(id) }) else {
            return ptr::null_mut();
        };
        let Some(callback) = on_frame else {
            return ptr::null_mut();
        };
        let on_frame = OnFrame { callback, user };
        match Player::new(id, move || on_frame.call()) {
            Ok(player) => Box::into_raw(Box::new(player)).cast::<c_void>(),
            Err(e) => {
                eprintln!("[loaf media] no player for {id}: {e}");
                ptr::null_mut()
            }
        }
    }))
    .unwrap_or(ptr::null_mut())
}

/// # Safety
/// [p] came from `loaf_rs_player_new` and is not yet freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_rs_player_play(p: *mut c_void) -> i32 {
    // SAFETY: forwarded from this function's contract.
    guard(|| match unsafe { player(p) } {
        Ok(player) => status("play", player.play()),
        Err(e) => e,
    })
}

/// # Safety
/// [p] came from `loaf_rs_player_new` and is not yet freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_rs_player_pause(p: *mut c_void) -> i32 {
    // SAFETY: forwarded from this function's contract.
    guard(|| match unsafe { player(p) } {
        Ok(player) => status("pause", player.pause()),
        Err(e) => e,
    })
}

/// # Safety
/// [p] came from `loaf_rs_player_new` and is not yet freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_rs_player_seek(p: *mut c_void, position_ms: i64) -> i32 {
    // SAFETY: forwarded from this function's contract.
    guard(|| match unsafe { player(p) } {
        Ok(player) => status("seek", player.seek(known(position_ms).unwrap_or(0))),
        Err(e) => e,
    })
}

/// # Safety
/// [p] came from `loaf_rs_player_new` and is not yet freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_rs_player_set_muted(p: *mut c_void, muted: i32) -> i32 {
    // SAFETY: forwarded from this function's contract.
    guard(|| match unsafe { player(p) } {
        Ok(player) => status("mute", player.set_muted(muted != 0)),
        Err(e) => e,
    })
}

/// Unknown times are -1.
///
/// # Safety
/// [p] came from `loaf_rs_player_new` and is not yet freed; the out
/// pointers are valid for writes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_rs_player_state(
    p: *mut c_void,
    position_ms: *mut i64,
    duration_ms: *mut i64,
    playing: *mut i32,
    error: *mut i32,
) -> i32 {
    guard(|| {
        // SAFETY: forwarded from this function's contract.
        let player = match unsafe { player(p) } {
            Ok(player) => player,
            Err(e) => return e,
        };
        if position_ms.is_null() || duration_ms.is_null() || playing.is_null() || error.is_null() {
            return NULL;
        }
        let state = player.state();
        let ms = |t: Option<u64>| t.and_then(|t| i64::try_from(t).ok()).unwrap_or(-1);
        // SAFETY: checked non-null above; valid for writes by contract.
        unsafe {
            *position_ms = ms(state.position_ms);
            *duration_ms = ms(state.duration_ms);
            *playing = i32::from(state.playing);
            *error = i32::from(state.error);
        }
        OK
    })
}

/// 1 and the newest frame, 0 if there is none yet, or an error.
///
/// # Safety
/// [p] came from `loaf_rs_player_new` and is not yet freed; the out
/// pointers are valid for writes. The bytes stay valid until the next call
/// for this player or `loaf_rs_player_free`, so calls must not overlap.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_rs_player_frame(
    p: *mut c_void,
    rgba: *mut *const u8,
    width: *mut u32,
    height: *mut u32,
) -> i32 {
    guard(|| {
        // SAFETY: forwarded from this function's contract.
        let player = match unsafe { player(p) } {
            Ok(player) => player,
            Err(e) => return e,
        };
        if rgba.is_null() || width.is_null() || height.is_null() {
            return NULL;
        }
        let Some(frame) = player.lend() else {
            return 0;
        };
        // SAFETY: checked non-null above. The bytes live in the Arc the
        // player keeps as last lent, until the next call or free.
        unsafe {
            *rgba = frame.rgba.as_ptr();
            *width = frame.width;
            *height = frame.height;
        }
        1
    })
}

/// # Safety
/// [p] is null or came from `loaf_rs_player_new` and is not yet freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_rs_player_free(p: *mut c_void) {
    if p.is_null() {
        return;
    }
    // A panic while dropping can only leak the player; it must not unwind
    // into C.
    let _ = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: from Box::into_raw in loaf_rs_player_new, freed once.
        drop(unsafe { Box::from_raw(p.cast::<Player>()) });
    }));
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    #[test]
    fn bad_strings_are_refused_not_trusted() {
        let bad = CString::new(vec![0xff, 0xfe]).unwrap();
        let path = CString::new("/nowhere.part").unwrap();
        unsafe {
            assert_eq!(
                loaf_rs_stream_begin(bad.as_ptr(), path.as_ptr(), 0, -1),
                BAD_STRING
            );
            assert_eq!(loaf_rs_stream_end(ptr::null()), BAD_STRING);
            assert!(loaf_rs_player_new(bad.as_ptr(), None, ptr::null_mut()).is_null());
        }
    }

    #[test]
    fn an_unknown_stream_is_an_error() {
        let id = CString::new("ffi-unknown").unwrap();
        unsafe {
            assert_eq!(loaf_rs_stream_progress(id.as_ptr(), 1, 2, 0, 0), FAILED);
            assert_eq!(loaf_rs_stream_end(id.as_ptr()), FAILED);
        }
    }

    #[test]
    fn a_null_player_is_an_error() {
        let (mut a, mut b, mut c, mut d) = (0, 0, 0, 0);
        unsafe {
            assert_eq!(loaf_rs_player_play(ptr::null_mut()), NULL);
            assert_eq!(
                loaf_rs_player_state(ptr::null_mut(), &mut a, &mut b, &mut c, &mut d),
                NULL
            );
            loaf_rs_player_free(ptr::null_mut());
        }
    }
}
