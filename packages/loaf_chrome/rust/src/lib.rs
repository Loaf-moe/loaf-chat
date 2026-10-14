//! The Windows half of `package:loaf_chrome`: a frameless window with
//! Loaf's own title-bar buttons. `window` subclasses the runner's window;
//! the C API Dart binds with `@Native` is `ffi`. `frame` is the geometry,
//! kept apart so it can be tested on any OS.

#![cfg_attr(
    not(test),
    deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)
)]

pub mod frame;

#[cfg(windows)]
pub mod window;

#[cfg(windows)]
pub mod ffi;
