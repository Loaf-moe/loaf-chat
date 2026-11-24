//! Signing in, keeping the session across launches and signing out.

/// Server input and the sign-in methods a server offers.
mod server;
/// The session as the secret store keeps it.
mod stored;

pub use server::{AuthMethods, BrowserMethod};
pub use stored::{CorruptSession, StoredAuth, StoredSession};

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
