//! The Windows half of `package:loaf_notify`: toasts through
//! `ToastNotificationManager`, under the AUMID the app registers for
//! itself. The C API the plugin calls is `ffi`
//! (`include/loaf_notify/loaf_notify_win.h`).

#![cfg_attr(
    not(test),
    deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)
)]

pub mod toast;

#[cfg(windows)]
pub mod notifier;

#[cfg(windows)]
pub mod ffi;
