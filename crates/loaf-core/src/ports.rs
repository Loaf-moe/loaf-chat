//! The I/O the core needs from its host that matrix-sdk doesn't provide.

/// The system browser that browser sign-ins happen in.
pub mod auth_browser;
/// Where the platform keeps secrets.
pub mod secret_store;
