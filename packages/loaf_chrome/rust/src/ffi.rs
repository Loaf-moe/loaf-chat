//! The C API Dart binds with `@Native` (`packages/loaf_chrome/lib/`). Every
//! entry point catches panics. Dart calls these on the platform thread,
//! which owns the window (see `window`).

use std::panic::{AssertUnwindSafe, catch_unwind};

use crate::frame::LogicalRect;
use crate::window::{self, InstallError, StateFn};

const OK: i32 = 0;
/// A panic was caught: a bug, reported rather than crashing the app.
const PANICKED: i32 = -1;
/// No runner window on the calling thread.
const NOT_FOUND: i32 = -2;
/// Windows refused.
const FAILED: i32 = -3;
/// Nothing is installed, so there is no window to act on.
const NOT_INSTALLED: i32 = -4;

fn guard(f: impl FnOnce() -> i32) -> i32 {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(PANICKED)
}

fn done(installed: bool) -> i32 {
    if installed { OK } else { NOT_INSTALLED }
}

/// Takes over the window. [report] is called with the state bits on each
/// change, until `loaf_chrome_uninstall`.
#[unsafe(no_mangle)]
pub extern "C" fn loaf_chrome_install(report: StateFn) -> i32 {
    guard(|| match window::install(report) {
        Ok(()) => OK,
        Err(InstallError::NotFound) => NOT_FOUND,
        Err(InstallError::Failed) => FAILED,
    })
}

/// Hands the window its frame back. After this returns, the callback given
/// to `loaf_chrome_install` is not called again.
#[unsafe(no_mangle)]
pub extern "C" fn loaf_chrome_uninstall() {
    let _ = catch_unwind(window::uninstall);
}

/// The state bits now, or a status below 0.
#[unsafe(no_mangle)]
pub extern "C" fn loaf_chrome_state() -> i32 {
    guard(|| match window::state() {
        Some(bits) => i32::try_from(bits).unwrap_or(FAILED),
        None => NOT_INSTALLED,
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn loaf_chrome_minimize() -> i32 {
    guard(|| done(window::minimize()))
}

#[unsafe(no_mangle)]
pub extern "C" fn loaf_chrome_toggle_maximize() -> i32 {
    guard(|| done(window::toggle_maximize()))
}

#[unsafe(no_mangle)]
pub extern "C" fn loaf_chrome_close() -> i32 {
    guard(|| done(window::close()))
}

#[unsafe(no_mangle)]
pub extern "C" fn loaf_chrome_start_drag() -> i32 {
    guard(|| done(window::start_drag()))
}

/// Where the maximize button is, in logical pixels from the window's
/// top-left; all zero when it goes.
#[unsafe(no_mangle)]
pub extern "C" fn loaf_chrome_set_max_button(x: f64, y: f64, w: f64, h: f64) -> i32 {
    guard(|| done(window::set_max_button(LogicalRect { x, y, w, h })))
}
