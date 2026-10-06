//! Video for the Linux half of `package:loaf_media`: a GStreamer source
//! that reads a download as it arrives, a player drawing into a Flutter
//! texture, and the C API the plugin calls
//! (`include/loaf_media/loaf_media_rs.h`).

#![cfg_attr(
    not(test),
    deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)
)]

use std::sync::OnceLock;

pub mod ffi;
pub mod player;
pub mod source;
/// The downloads being read, shared with Windows.
pub use loaf_streams as streams;

/// Starts GStreamer and registers `loafsrc`, once per process. Later calls
/// give the first call's outcome.
pub fn init() -> Result<(), String> {
    static INIT: OnceLock<Result<(), String>> = OnceLock::new();
    INIT.get_or_init(|| {
        gst::init().map_err(|e| format!("GStreamer: {e}"))?;
        source::register().map_err(|e| format!("loafsrc: {e}"))
    })
    .clone()
}
