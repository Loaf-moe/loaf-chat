//! The C API in `include/loaf_media/loaf_media_win.h`, for the plugin's
//! glue. Functions return 0 for OK and a negative number for an error, as
//! on Linux. Nothing may unwind into C, so every body runs under
//! `catch_unwind`.

use std::ffi::{CStr, c_char, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::PathBuf;
use std::ptr;
use std::sync::Arc;

use loaf_streams::{self as streams, Progress, Reader};

use crate::player::{self, Frame, FrameCallback, Player};
use crate::{shell, wic};

const OK: i32 = 0;
/// A panic was caught: a bug, reported rather than crashing the app.
const PANICKED: i32 = -1;
/// A string argument was null or not UTF-8.
const BAD_STRING: i32 = -2;
/// The call itself failed: no such stream, Media Foundation refused, …
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
/// [p] is null or came from `loaf_win_player_new` and is not yet freed.
unsafe fn player<'a>(p: *mut c_void) -> Result<&'a Player, i32> {
    // SAFETY: by the caller's contract it is null or a live Box<Player>.
    unsafe { p.cast::<Player>().as_ref() }.ok_or(NULL)
}

#[unsafe(no_mangle)]
pub extern "C" fn loaf_win_init() -> i32 {
    guard(|| status("init", player::init()))
}

/// # Safety
/// [id] and [path] (UTF-8) are NUL-terminated strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_win_stream_begin(
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
pub unsafe extern "C" fn loaf_win_stream_progress(
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
pub unsafe extern "C" fn loaf_win_stream_end(id: *const c_char) -> i32 {
    guard(|| {
        // SAFETY: forwarded from this function's contract.
        match unsafe { string(id) } {
            Ok(id) => status("end", streams::end(id)),
            Err(e) => e,
        }
    })
}

/// # Safety
/// [id] and [extension] are NUL-terminated strings; [user] stays valid
/// until `loaf_win_player_free` returns.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_win_player_new(
    id: *const c_char,
    extension: *const c_char,
    on_frame: Option<FrameCallback>,
    user: *mut c_void,
) -> *mut c_void {
    catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: forwarded from this function's contract.
        let (Ok(id), Ok(extension)) = (unsafe { string(id) }, unsafe { string(extension) }) else {
            return ptr::null_mut();
        };
        let Some(on_frame) = on_frame else {
            return ptr::null_mut();
        };
        let Some(stream) = streams::lookup(id) else {
            eprintln!("[loaf media] no stream {id}");
            return ptr::null_mut();
        };
        match Player::new(Reader::new(stream), id, extension, on_frame, user) {
            Ok(p) => Box::into_raw(Box::new(p)).cast(),
            Err(e) => {
                eprintln!("[loaf media] player for {id}: {e}");
                ptr::null_mut()
            }
        }
    }))
    .unwrap_or(ptr::null_mut())
}

macro_rules! player_call {
    ($name:ident, |$p:ident $(, $arg:ident: $ty:ty)*| $body:expr) => {
        /// # Safety
        /// [p] came from `loaf_win_player_new` and is not yet freed.
        #[unsafe(no_mangle)]
        pub unsafe extern "C" fn $name(p: *mut c_void $(, $arg: $ty)*) -> i32 {
            guard(|| {
                // SAFETY: forwarded from this function's contract.
                match unsafe { player(p) } {
                    Ok($p) => status(stringify!($name), $body),
                    Err(e) => e,
                }
            })
        }
    };
}

player_call!(loaf_win_player_play, |p| p.play());
player_call!(loaf_win_player_pause, |p| p.pause());
player_call!(loaf_win_player_seek, |p, position_ms: i64| p
    .seek(position_ms));
player_call!(loaf_win_player_set_muted, |p, muted: i32| p
    .set_muted(muted != 0));

/// # Safety
/// [p] came from `loaf_win_player_new`; the out pointers are valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_win_player_state(
    p: *mut c_void,
    position_ms: *mut i64,
    duration_ms: *mut i64,
    playing: *mut i32,
    error: *mut i32,
) -> i32 {
    guard(|| {
        if position_ms.is_null() || duration_ms.is_null() || playing.is_null() || error.is_null() {
            return NULL;
        }
        // SAFETY: forwarded from this function's contract.
        let p = match unsafe { player(p) } {
            Ok(p) => p,
            Err(e) => return e,
        };
        let state = p.state();
        // SAFETY: all checked non-null above.
        unsafe {
            *position_ms = state.position_ms;
            *duration_ms = state.duration_ms;
            *playing = state.playing.into();
            *error = state.error.into();
        }
        OK
    })
}

/// # Safety
/// [p] came from `loaf_win_player_new`; the out pointers are valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_win_player_status(
    p: *mut c_void,
    ready: *mut i32,
    error: *mut i32,
) -> i32 {
    guard(|| {
        if ready.is_null() || error.is_null() {
            return NULL;
        }
        // SAFETY: forwarded from this function's contract.
        let p = match unsafe { player(p) } {
            Ok(p) => p,
            Err(e) => return e,
        };
        // SAFETY: checked non-null above.
        unsafe {
            *ready = p.ready().into();
            *error = p.failed().into();
        }
        OK
    })
}

/// The newest frame as the caller's own reference, or null if there is
/// none yet. [handle] is its DXGI shared handle, valid until
/// `loaf_win_frame_release`, independently of the player.
///
/// # Safety
/// [p] came from `loaf_win_player_new`; the out pointers are valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_win_player_take_frame(
    p: *mut c_void,
    handle: *mut *mut c_void,
    width: *mut u32,
    height: *mut u32,
) -> *const c_void {
    catch_unwind(AssertUnwindSafe(|| {
        if handle.is_null() || width.is_null() || height.is_null() {
            return ptr::null();
        }
        // SAFETY: forwarded from this function's contract.
        let Ok(p) = (unsafe { player(p) }) else {
            return ptr::null();
        };
        let Some(frame) = p.take_frame() else {
            return ptr::null();
        };
        // SAFETY: checked non-null above.
        unsafe {
            *handle = frame.handle.0;
            *width = frame.width;
            *height = frame.height;
        }
        Arc::into_raw(frame).cast()
    }))
    .unwrap_or(ptr::null())
}

/// # Safety
/// [frame] is null or came from `loaf_win_player_take_frame`, once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_win_frame_release(frame: *const c_void) {
    if frame.is_null() {
        return;
    }
    let _ = catch_unwind(|| {
        // SAFETY: an Arc<Frame> handed out by take_frame, released once.
        drop(unsafe { Arc::from_raw(frame.cast::<Frame>()) });
    });
}

/// # Safety
/// [p] is null or came from `loaf_win_player_new`, and is freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_win_player_free(p: *mut c_void) {
    if p.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: a Box<Player> from player_new, freed once.
        drop(unsafe { Box::from_raw(p.cast::<Player>()) });
    }));
}

/// Writes the name of the app files ending `.<extension>` open in, as
/// UTF-8 and NUL-terminated, into [out]. Its length, or -3 when no app is
/// set or [out] is too small.
///
/// # Safety
/// [extension] is a NUL-terminated string; [out] holds [capacity] bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_win_default_app_name(
    extension: *const c_char,
    out: *mut c_char,
    capacity: u32,
) -> i32 {
    guard(|| {
        if out.is_null() {
            return NULL;
        }
        // SAFETY: forwarded from this function's contract.
        let extension = match unsafe { string(extension) } {
            Ok(e) => e,
            Err(e) => return e,
        };
        let Some(name) = shell::default_app_name(extension) else {
            return FAILED;
        };
        let bytes = name.as_bytes();
        if bytes.len() + 1 > capacity as usize {
            return FAILED;
        }
        // SAFETY: [out] holds [capacity] bytes, and this writes len + 1.
        unsafe {
            ptr::copy_nonoverlapping(bytes.as_ptr(), out.cast::<u8>(), bytes.len());
            *out.add(bytes.len()) = 0;
        }
        bytes.len() as i32
    })
}

/// # Safety
/// [path] is a NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_win_open(path: *const c_char) -> i32 {
    guard(|| {
        // SAFETY: forwarded from this function's contract.
        match unsafe { string(path) } {
            Ok(path) => status("open", shell::open(path)),
            Err(e) => e,
        }
    })
}

/// Decodes [bytes] with WIC, at most [max_width] wide when it isn't 0.
/// Null if WIC can't. Free with `loaf_win_image_free`.
///
/// # Safety
/// [bytes] holds [len] bytes; the out pointers are valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_win_decode_image(
    bytes: *const u8,
    len: usize,
    max_width: u32,
    width: *mut u32,
    height: *mut u32,
    pixels: *mut *const u8,
) -> *mut c_void {
    catch_unwind(AssertUnwindSafe(|| {
        if bytes.is_null() || width.is_null() || height.is_null() || pixels.is_null() {
            return ptr::null_mut();
        }
        // SAFETY: [bytes] holds [len] bytes by this function's contract.
        let input = unsafe { std::slice::from_raw_parts(bytes, len) };
        match wic::decode(input, (max_width > 0).then_some(max_width)) {
            Ok(image) => {
                let image = Box::new(image);
                // SAFETY: checked non-null above; the pixels live in the box.
                unsafe {
                    *width = image.width;
                    *height = image.height;
                    *pixels = image.pixels.as_ptr();
                }
                Box::into_raw(image).cast()
            }
            Err(e) => {
                eprintln!("[loaf media] WIC: {e}");
                ptr::null_mut()
            }
        }
    }))
    .unwrap_or(ptr::null_mut())
}

/// # Safety
/// [image] is null or came from `loaf_win_decode_image`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_win_image_free(image: *mut c_void) {
    if image.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: a Box<Decoded> from decode_image, freed once.
        drop(unsafe { Box::from_raw(image.cast::<wic::Decoded>()) });
    }));
}
