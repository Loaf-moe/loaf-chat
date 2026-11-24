//! The I/O the core needs from its host, each a small trait in the core's own types.

/// What a homeserver answered to discovery.
pub mod matrix;
/// Where the platform keeps secrets.
pub mod secret_store;
