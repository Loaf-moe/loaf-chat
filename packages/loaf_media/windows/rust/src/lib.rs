//! The Windows half of `package:loaf_media`: Media Foundation's Media
//! Engine playing a download as it arrives (through `byte_stream`) into a
//! texture Flutter draws, the shell's default apps, and WIC for pictures
//! Flutter can't decode. The C API the plugin calls is `ffi`
//! (`include/loaf_media/loaf_media_win.h`).

#![cfg_attr(
    not(test),
    deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)
)]

#[cfg(windows)]
pub mod byte_stream;

#[cfg(windows)]
pub mod player;

#[cfg(windows)]
pub mod shell;

#[cfg(windows)]
pub mod wic;

#[cfg(windows)]
pub mod ffi;

pub mod chime;
