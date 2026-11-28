//! Loaf Chat's application state and services. No UI or FFI dependencies.

extern crate alloc;

pub mod core;
pub mod ports;
pub mod session;

#[cfg(test)]
mod fakes;
