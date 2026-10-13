//! The one export that has nothing to do with WinRT, so it builds (and is
//! tested) on every host.

use std::ffi::{CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// Frees a string the click callback was given (made by
/// `CString::into_raw`). Null is fine.
///
/// # Safety
/// [s] is null, or came from a click callback and is not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_notify_string_free(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: forwarded from this function's contract.
        drop(unsafe { CString::from_raw(s) });
    }));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn freeing_null_is_safe() {
        // SAFETY: null is allowed.
        unsafe { loaf_notify_string_free(std::ptr::null_mut()) };
    }

    #[test]
    fn frees_a_handed_over_string() {
        let raw = CString::new("!room:x").map(CString::into_raw);
        assert!(raw.is_ok());
        if let Ok(raw) = raw {
            // SAFETY: made by into_raw just above, freed once.
            unsafe { loaf_notify_string_free(raw) };
        }
    }
}
