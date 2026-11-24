//! Signing in, keeping the session across launches and signing out.

/// The sign-in flow: discovery, its state and its stale answers.
mod flow;
/// Restoring at start, and later the refresh and sign-out that keep the session.
pub(crate) mod keeping;
/// Server input and the sign-in methods a server offers.
mod server;
/// The session as the secret store keeps it.
mod stored;

pub use flow::{Activity, ServerCheck, SignInFailure, SignInFlow, SignInState};
pub use server::{AuthMethods, BrowserMethod};
pub use stored::{CorruptSession, StoredAuth, StoredSession};

use alloc::sync::Arc;

use eyeball::Subscriber;
use serde::{Deserialize, Serialize};
use tokio::runtime::Handle;

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

/// `begin_sign_in` was called while an account is signed in.
#[derive(Debug, thiserror::Error)]
#[error("an account is already signed in")]
pub struct NotSignedOut;

/// The handle a shell uses to watch and change the session.
pub struct Session {
    /// Holds the state and the secrets behind it.
    keeping: Arc<Keeping>,
    /// The runtime the core started on; flows spawn their work there, so a
    /// shell may call in, or drop a flow, from any thread.
    runtime: Handle,
}

impl Session {
    /// A handle over `keeping` whose flows run on `runtime`.
    pub(crate) fn new(keeping: Arc<Keeping>, runtime: Handle) -> Self {
        Self { keeping, runtime }
    }

    /// A subscriber whose first `next()` yields the current state at once;
    /// each later `next()` waits for a change.
    pub fn state(&self) -> Subscriber<SessionState> {
        self.keeping.state()
    }

    /// Starts signing in, probing the default server at once. Any earlier
    /// flow becomes inert, so two flows can never both sign in.
    ///
    /// # Errors
    ///
    /// [`NotSignedOut`] while an account is signed in or a sign-in is being kept.
    pub fn begin_sign_in(&self) -> Result<SignInFlow, NotSignedOut> {
        let generation = self.keeping.begin_flow()?;
        Ok(SignInFlow::begin(
            Arc::clone(&self.keeping),
            self.runtime.clone(),
            generation,
        ))
    }
}
