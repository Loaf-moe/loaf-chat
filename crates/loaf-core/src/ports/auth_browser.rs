use async_trait::async_trait;
use url::Url;

/// The system browser a sign-in with OAuth or SSO happens in.
#[async_trait]
pub trait AuthBrowser: Send + Sync {
    /// Where the provider sends the browser back to. Desktop binds its
    /// loopback listener here, so the port is known; Apple returns its
    /// callback scheme.
    async fn redirect_uri(&self) -> Result<Url, AuthBrowserError>;
    /// Opens `url` and resolves with the URL the browser came back to.
    /// Dropping the future closes the pending page.
    async fn authenticate(&self, url: Url) -> Result<Url, AuthBrowserError>;
}

/// Why a browser sign-in came back without a callback.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum AuthBrowserError {
    #[error("browser sign-in was cancelled")]
    Cancelled,
    #[error("browser couldn't be opened")]
    CouldntOpen,
}
