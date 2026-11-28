//! Signing in, keeping the session across launches and signing out.

/// Every way discovery and signing in can fail.
mod error;
/// The session itself: discovery, signing in on a fresh store, restoring at
/// start, refresh and sign-out.
mod lifecycle;
/// Everything that touches matrix-sdk's types.
mod sdk;
/// Server input and the sign-in methods a server offers.
mod server;
/// A discovered server and its sign-in handles.
mod sign_in;
/// The session as the secret store keeps it.
mod stored;
#[cfg(test)]
mod tests;

pub use error::{AccountError, BrowserError, DiscoverError, EmptyFields, FinishError, PasswordError, Unreachable};
pub use lifecycle::Session;
pub use sign_in::{BrowserSignIn, Failed, PasswordSignIn, Server};

use serde::{Deserialize, Serialize};

/// A Matrix user id such as `@alice:example.org`.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct UserId(String);

impl UserId {
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl From<String> for UserId {
    fn from(id: String) -> Self {
        Self(id)
    }
}

/// The id of one device's login on the homeserver.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct DeviceId(String);

impl DeviceId {
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl From<String> for DeviceId {
    fn from(id: String) -> Self {
        Self(id)
    }
}

/// Whether this device holds a signed-in account.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionState {
    SignedOut,
    SignedIn { user: UserId, device: DeviceId },
}

/// The server a full user id names, such as `example.org` in
/// `@alice:example.org`; `None` for anything else, a plain username included.
#[must_use]
pub fn server_in_user_id(text: &str) -> Option<String> {
    server::user_id_server(text)
}
