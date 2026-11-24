//! Signing in, keeping the session across launches and signing out.

/// Restoring at start, and later the refresh and sign-out that keep the session.
pub(crate) mod keeping;
/// Server input and the sign-in methods a server offers.
mod server;
/// The session as the secret store keeps it.
mod stored;

pub use server::{AuthMethods, BrowserMethod};
pub use stored::{CorruptSession, StoredAuth, StoredSession};

use alloc::sync::Arc;

use eyeball::Subscriber;
use serde::{Deserialize, Serialize};

use keeping::Keeping;

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

/// The handle a shell uses to watch and change the session.
pub struct Session {
    /// Holds the state and the secrets behind it.
    keeping: Arc<Keeping>,
}

impl Session {
    /// A handle over `keeping`.
    pub(crate) const fn new(keeping: Arc<Keeping>) -> Self {
        Self { keeping }
    }

    /// A subscriber whose first `next()` yields the current state at once;
    /// each later `next()` waits for a change.
    pub fn state(&self) -> Subscriber<SessionState> {
        self.keeping.state()
    }
}
