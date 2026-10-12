//! The C API Dart binds with `@Native` (`packages/loaf_notify/lib/`). Every
//! entry point catches panics; strings are UTF-8 and NUL-terminated.

use std::ffi::{CStr, CString, c_char, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Arc;

use windows::Win32::Foundation::RPC_E_CHANGED_MODE;
use windows::Win32::System::WinRT::{RO_INIT_MULTITHREADED, RoInitialize};

use crate::notifier::{self, Notifier};
use crate::toast::Toast;

const OK: i32 = 0;
/// A panic was caught: a bug, reported rather than crashing the app.
const PANICKED: i32 = -1;
/// A string argument was null or not UTF-8.
const BAD_STRING: i32 = -2;
/// The call itself failed: WinRT refused.
const FAILED: i32 = -3;
/// A pointer argument was null.
const NULL: i32 = -4;

/// Called on a WinRT thread when a toast is clicked. Dart's
/// `NativeCallable.listener` runs it later, on its own thread, so both
/// strings are handed over: Dart copies them, then returns each to
/// `loaf_notify_string_free`.
pub type ClickFn = unsafe extern "C" fn(room_id: *mut c_char, event_id: *mut c_char);

/// Makes the calling thread able to use WinRT. Dart's thread is not the
/// runner's COM-initialised main thread, and a thread that already has a
/// (different) apartment answers `RPC_E_CHANGED_MODE`, which is as good.
fn apartment() -> windows::core::Result<()> {
    // SAFETY: no pointers; initialisation is per calling thread.
    match unsafe { RoInitialize(RO_INIT_MULTITHREADED) } {
        Err(e) if e.code() != RPC_E_CHANGED_MODE => Err(e),
        _ => Ok(()),
    }
}

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

fn status(what: &str, result: windows::core::Result<()>) -> i32 {
    match result {
        Ok(()) => OK,
        Err(e) => {
            eprintln!("[loaf notify] {what}: {e}");
            FAILED
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn loaf_notify_new(click: ClickFn) -> *mut c_void {
    catch_unwind(|| {
        if let Err(e) = apartment() {
            eprintln!("[loaf notify] new: {e}");
            return std::ptr::null_mut();
        }
        let clicked: notifier::Clicked = Arc::new(move |room, event| {
            let (Ok(room), Ok(event)) = (CString::new(room), CString::new(event)) else {
                return;
            };
            // SAFETY: ownership of both passes to the callback, which
            // frees them with `loaf_notify_string_free`.
            unsafe { click(room.into_raw(), event.into_raw()) };
        });
        Box::into_raw(Box::new(Notifier::new(clicked))).cast::<c_void>()
    })
    .unwrap_or(std::ptr::null_mut())
}

/// # Safety
/// [notifier] is null, or came from `loaf_notify_new` and is not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_notify_free(notifier: *mut c_void) {
    if notifier.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: forwarded from this function's contract.
        drop(unsafe { Box::from_raw(notifier.cast::<Notifier>()) });
    }));
}

#[unsafe(no_mangle)]
pub extern "C" fn loaf_notify_register() -> i32 {
    guard(|| {
        if let Err(e) = apartment() {
            return status("register", Err(e));
        }
        match notifier::icon_path() {
            Some(icon) => status("register", notifier::register(&icon)),
            None => FAILED,
        }
    })
}

/// # Safety
/// [notifier] came from `loaf_notify_new`; the strings follow `string`'s
/// contract; [avatar] may be null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_notify_show(
    notifier: *mut c_void,
    title: *const c_char,
    body: *const c_char,
    room_id: *const c_char,
    event_id: *const c_char,
    avatar: *const c_char,
) -> i32 {
    guard(|| {
        if notifier.is_null() {
            return NULL;
        }
        if let Err(e) = apartment() {
            return status("show", Err(e));
        }
        // SAFETY: forwarded from this function's contract.
        let fields = unsafe {
            (|| {
                Ok::<_, i32>((
                    string(title)?,
                    string(body)?,
                    string(room_id)?,
                    string(event_id)?,
                ))
            })()
        };
        let (title, body, room_id, event_id) = match fields {
            Ok(f) => f,
            Err(e) => return e,
        };
        // SAFETY: as above; null means no picture.
        let avatar = if avatar.is_null() {
            None
        } else {
            unsafe { string(avatar) }.ok()
        };
        // SAFETY: forwarded from this function's contract.
        let notifier = unsafe { &*notifier.cast::<Notifier>() };
        status(
            "show",
            notifier.show(&Toast {
                title,
                body,
                room_id,
                event_id,
                avatar,
            }),
        )
    })
}

/// # Safety
/// As `loaf_notify_show`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_notify_withdraw(
    notifier: *mut c_void,
    room_id: *const c_char,
) -> i32 {
    guard(|| {
        if notifier.is_null() {
            return NULL;
        }
        if let Err(e) = apartment() {
            return status("withdraw", Err(e));
        }
        // SAFETY: forwarded from this function's contract.
        match unsafe { string(room_id) } {
            Ok(room_id) => {
                // SAFETY: forwarded from this function's contract.
                let notifier = unsafe { &*notifier.cast::<Notifier>() };
                status("withdraw", notifier.withdraw(room_id))
            }
            Err(e) => e,
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn loaf_notify_blocked() -> i32 {
    guard(|| {
        if let Err(e) = apartment() {
            return status("blocked", Err(e));
        }
        match notifier::blocked() {
            Ok(true) => 1,
            Ok(false) => 0,
            Err(e) => {
                eprintln!("[loaf notify] blocked: {e}");
                FAILED
            }
        }
    })
}
