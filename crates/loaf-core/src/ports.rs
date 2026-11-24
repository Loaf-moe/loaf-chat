//! The I/O the core needs from its host, each a small trait in the core's own types.

/// The system browser that browser sign-ins happen in.
pub mod auth_browser;
/// What sign-in and the session need from a homeserver.
pub mod matrix;
/// Where the platform keeps secrets.
pub mod secret_store;
