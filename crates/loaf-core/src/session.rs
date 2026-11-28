//! Signing in, keeping the session across launches and signing out.

/// Every way discovery and signing in can fail.
mod error;
/// Signing in on a fresh store, restoring at start, refresh and sign-out.
pub(crate) mod keeping;
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
pub use sign_in::{BrowserSignIn, Failed, PasswordSignIn, Server};

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

/// The server a full user id names, such as `example.org` in
/// `@alice:example.org`; `None` for anything else, a plain username included.
#[must_use]
pub fn server_in_user_id(text: &str) -> Option<String> {
    server::user_id_server(text)
}

/// The handle a shell uses to watch and change the session.
pub struct Session {
    /// Holds the state, the client and the secrets behind them.
    keeping: Arc<Keeping>,
}

impl Session {
    /// The handle over `keeping`.
    pub(crate) const fn new(keeping: Arc<Keeping>) -> Self {
        Self { keeping }
    }

    /// A subscriber whose first `next()` yields the current state at once;
    /// each later `next()` waits for a change.
    pub fn state(&self) -> Subscriber<SessionState> {
        self.keeping.state()
    }

    /// Finds the server `input` names (a server name, URL or full user id)
    /// and what it offers to sign in with.
    ///
    /// # Errors
    ///
    /// See [`DiscoverError`].
    pub async fn discover(&self, input: &str) -> Result<Server, DiscoverError> {
        if !self.keeping.is_signed_out() {
            return Err(DiscoverError::NotSignedOut);
        }
        let host = server::parse_server(input).ok_or(DiscoverError::NotAServer)?;
        let address = if server::typed_http(input) {
            format!("http://{host}")
        } else {
            host.clone()
        };
        let probe = sdk::probe(&address).await?;
        Ok(Server::new(&self.keeping, host, probe))
    }

    /// Logs out on the server where it can, then always wipes this device's
    /// data and publishes `SignedOut`.
    pub async fn sign_out(&self) {
        self.keeping.sign_out().await;
    }

    /// What keeps the session, for tests that drive the signed-in client.
    #[cfg(test)]
    pub(crate) fn keeping(&self) -> &Arc<Keeping> {
        &self.keeping
    }
}
