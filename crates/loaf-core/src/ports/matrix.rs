use alloc::sync::Arc;
use core::fmt;
use core::time::Duration;

use async_trait::async_trait;
use tokio::sync::mpsc::UnboundedReceiver;
use url::Url;

use crate::session::{BrowserMethod, StoredSession};

/// What sign-in and the session need from a homeserver.
#[async_trait]
pub trait Matrix: Send + Sync {
    /// Discovers `server` and opens a pending store under `passphrase` for
    /// the sign-in that may follow.
    async fn probe(&self, server: &str, passphrase: &str) -> Result<Probe, Unreachable>;
    /// Brings back a signed-in account from its store, without the network.
    async fn restore(&self, session: &StoredSession, passphrase: &str) -> Result<Arc<dyn Account>, WontRestore>;
    /// Deletes everything the client keeps on disk.
    async fn wipe(&self) -> Result<(), WipeError>;
}

/// A server that answered discovery, and the sign-in started against it.
pub struct Probe {
    pub offer: ServerOffer,
    pub attempt: Box<dyn Attempt>,
}

// The attempt is a trait object with nothing worth printing.
impl fmt::Debug for Probe {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Probe")
            .field("offer", &self.offer)
            .finish_non_exhaustive()
    }
}

/// What a homeserver's login endpoint and OAuth metadata offered.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerOffer {
    /// The server publishes OAuth 2.0 metadata.
    pub oauth: bool,
    /// `m.login.sso` is offered: `None` when it isn't, an empty list when it
    /// is offered without naming providers.
    pub sso: Option<Vec<IdentityProvider>>,
    /// `m.login.password` is offered.
    pub password: bool,
}

/// One single sign-on provider a server lists.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IdentityProvider {
    pub id: String,
    pub name: Option<String>,
}

/// One sign-in against a probed server, with its own pending store.
#[async_trait]
pub trait Attempt: Send + Sync {
    async fn sign_in_with_password(
        &self,
        user: &str,
        password: &str,
        device_name: &str,
    ) -> Result<StoredSession, PasswordError>;
    /// The page to open in the browser for `method`, returning to `redirect`.
    async fn browser_url(&self, method: &BrowserMethod, redirect: &Url, device_name: &str)
    -> Result<Url, AttemptError>;
    /// Completes a browser sign-in from the URL the browser came back to.
    async fn finish_browser(&self, callback: &Url) -> Result<StoredSession, FinishError>;
    /// Keeps the pending store as the account's own.
    async fn commit(self: Box<Self>, session: &StoredSession) -> Result<Arc<dyn Account>, CommitError>;
    /// Logs out any token this attempt got and deletes its store.
    async fn discard(self: Box<Self>);
}

/// Why a password sign-in didn't sign in.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PasswordError {
    #[error("wrong username or password")]
    Forbidden,
    #[error("too many attempts")]
    RateLimited { retry_after: Option<Duration> },
    #[error("server refused sign-in: {message}")]
    Refused { message: String },
    #[error("sign-in failed")]
    Other,
}

/// Why a browser sign-in couldn't be completed from its callback.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum FinishError {
    #[error("login token refused")]
    TokenRefused,
    #[error("browser sign-in failed")]
    Other,
}

/// A signed-in account on a homeserver.
#[async_trait]
pub trait Account: Send + Sync {
    /// Changes to the session the server side makes, such as refreshed tokens.
    fn session_changes(&self) -> UnboundedReceiver<SessionChange>;
    async fn logout(&self) -> Result<(), LogoutError>;
}

/// Something that happened to the stored session after sign-in.
#[derive(Debug, Clone, PartialEq, Eq)]
#[expect(
    clippy::large_enum_variant,
    reason = "a change arrives once per token refresh, so the unboxed session costs nothing"
)]
pub enum SessionChange {
    TokensRefreshed(StoredSession),
    /// The token expired and couldn't be refreshed.
    Unrecoverable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
#[error("server unreachable")]
pub struct Unreachable;

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
#[error("stored account won't restore")]
pub struct WontRestore;

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
#[error("couldn't delete the client's data")]
pub struct WipeError;

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
#[error("couldn't start browser sign-in")]
pub struct AttemptError;

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
#[error("couldn't keep the signed-in account")]
pub struct CommitError;

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
#[error("server logout failed")]
pub struct LogoutError;
