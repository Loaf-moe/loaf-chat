//! The Windows half of `package:loaf_notify`: toasts through
//! `ToastNotificationManager`, under the AUMID the app registers for
//! itself. The C API Dart binds with `@Native` is `ffi` and `strings`.

#![cfg_attr(
    not(test),
    deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)
)]

pub mod callback;
pub mod strings;
pub mod toast;

#[cfg(windows)]
pub mod notifier;

#[cfg(windows)]
pub mod ffi;
