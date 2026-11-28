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

pub use error::{
    AccountError, BrowserError, DiscoverError, EmptyFields, FinishError, InvalidUserId, PasswordError, Unreachable,
};
pub use lifecycle::Session;
pub use sign_in::{BrowserSignIn, Failed, PasswordSignIn, Server};

use serde::{Deserialize, Serialize};

/// A Matrix user id such as `@alice:example.org`: an `@`, a username, a
/// colon and the name of the server the account lives on.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct UserId {
    /// The whole id.
    id: String,
    /// Everything after the first colon, with any port.
    server_name: String,
}

impl UserId {
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.id
    }

    /// The server the account lives on, such as `example.org`, with any port.
    #[must_use]
    pub fn server_name(&self) -> &str {
        &self.server_name
    }
}

impl TryFrom<&str> for UserId {
    type Error = InvalidUserId;

    /// Reads a typed user id; whitespace around it is ignored.
    fn try_from(text: &str) -> Result<Self, InvalidUserId> {
        let id = text.trim();
        let rest = id.strip_prefix('@').ok_or(InvalidUserId::MissingAt)?;
        if rest.chars().any(char::is_whitespace) {
            return Err(InvalidUserId::HasSpaces);
        }
        let (username, server_name) = rest.split_once(':').ok_or(InvalidUserId::MissingServer)?;
        if username.is_empty() {
            return Err(InvalidUserId::EmptyUsername);
        }
        if server_name.is_empty() {
            return Err(InvalidUserId::MissingServer);
        }
        Ok(Self {
            id: id.to_owned(),
            server_name: server_name.to_owned(),
        })
    }
}

impl TryFrom<String> for UserId {
    type Error = InvalidUserId;

    fn try_from(text: String) -> Result<Self, InvalidUserId> {
        Self::try_from(text.as_str())
    }
}

impl From<UserId> for String {
    fn from(user: UserId) -> Self {
        user.id
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
