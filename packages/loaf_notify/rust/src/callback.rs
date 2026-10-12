//! The click callback Dart gave us, which must never be called once Dart
//! has torn it down. Toasts outlive the notifier in Action Center, so a
//! click can arrive long after `loaf_notify_free`.

use std::ffi::c_char;
use std::sync::{Arc, Mutex};

/// Called on a WinRT thread when a toast is clicked. Dart's
/// `NativeCallable.listener` runs it later, on its own thread, so both
/// strings are handed over: Dart copies them, then returns each to
/// `loaf_notify_string_free`.
pub type ClickFn = unsafe extern "C" fn(room_id: *mut c_char, event_id: *mut c_char);

/// A [ClickFn] that can be switched off. Clones share the switch.
#[derive(Clone)]
pub struct Callback(Arc<Mutex<Option<ClickFn>>>);

impl Callback {
    pub fn new(click: ClickFn) -> Self {
        Self(Arc::new(Mutex::new(Some(click))))
    }

    /// Calls the callback if it is still on. The lock is held across the
    /// call, so a [clear](Self::clear) returns only after any call in
    /// flight has: Dart's listener just posts, so this is brief.
    ///
    /// # Safety
    /// [room] and [event] are valid for the callback to take ownership of.
    pub unsafe fn call(&self, room: *mut c_char, event: *mut c_char) -> bool {
        let Ok(slot) = self.0.lock() else {
            return false;
        };
        match *slot {
            Some(click) => {
                // SAFETY: forwarded from this function's contract.
                unsafe { click(room, event) };
                true
            }
            None => false,
        }
    }

    /// After this returns, no call begins or is running.
    pub fn clear(&self) {
        if let Ok(mut slot) = self.0.lock() {
            *slot = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static CALLS: AtomicUsize = AtomicUsize::new(0);

    unsafe extern "C" fn counted(_: *mut c_char, _: *mut c_char) {
        CALLS.fetch_add(1, Ordering::SeqCst);
    }

    #[test]
    fn a_cleared_callback_is_not_called() {
        let callback = Callback::new(counted);
        let stored = callback.clone();
        // SAFETY: the test callback ignores its arguments.
        assert!(unsafe { stored.call(std::ptr::null_mut(), std::ptr::null_mut()) });
        assert_eq!(CALLS.load(Ordering::SeqCst), 1);
        callback.clear();
        // SAFETY: as above.
        assert!(!unsafe { stored.call(std::ptr::null_mut(), std::ptr::null_mut()) });
        assert_eq!(CALLS.load(Ordering::SeqCst), 1);
    }
}
