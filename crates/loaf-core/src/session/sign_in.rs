//! A discovered server and the sign-ins it offers, each a handle that is
//! used up by signing in and handed back when that fails.

use alloc::sync::Arc;
use core::fmt;

use url::Url;

use super::error::{BrowserError, EmptyFields, PasswordError};
use super::keeping::Keeping;
use super::sdk::{self, Probe};
use super::server::{BrowserMethod, auth_methods};

/// A server that answered discovery, and the ways it offers to sign in.
#[derive(Debug)]
pub struct Server {
    /// The host as typed.
    name: String,
    /// Present where the server takes a password.
    password: Option<PasswordSignIn>,
    /// OAuth alone, or one per SSO provider in the server's order.
    browser: Vec<BrowserSignIn>,
}

impl Server {
    /// The sign-ins `probe` found on the server typed as `name`.
    pub(crate) fn new(keeping: &Arc<Keeping>, name: String, probe: Probe) -> Self {
        let methods = auth_methods(&probe.offer);
        let browser = methods
            .browser
            .into_iter()
            .map(|method| BrowserSignIn {
                keeping: Arc::clone(keeping),
                homeserver: probe.homeserver.clone(),
                name: match &method {
                    BrowserMethod::Sso {
                        name: Some(provider_name),
                        provider: _,
                    } => provider_name.clone(),
                    BrowserMethod::OAuth
                    | BrowserMethod::Sso {
                        name: None,
                        provider: _,
                    } => name.clone(),
                },
                method,
            })
            .collect();
        let password = methods.password.then(|| PasswordSignIn {
            keeping: Arc::clone(keeping),
            homeserver: probe.homeserver,
        });
        Self {
            name,
            password,
            browser,
        }
    }

    /// The host as typed, never the base URL it delegates to.
    #[must_use]
    pub fn name(&self) -> &str {
        &self.name
    }

    /// Signing in with a password, where the server takes one.
    #[must_use]
    pub fn password(&self) -> Option<PasswordSignIn> {
        self.password.clone()
    }

    /// Signing in in the system browser: OAuth alone, or one per SSO provider.
    #[must_use]
    pub fn browser(&self) -> Vec<BrowserSignIn> {
        self.browser.clone()
    }
}

/// A failed sign-in hands its handle back, so the UI can try again.
#[derive(Debug, thiserror::Error)]
#[error("{error}")]
pub struct Failed<H, E> {
    /// The sign-in, ready to try again.
    pub handle: H,
    /// Why it didn't sign in.
    pub error: E,
}

/// Signing in to one server with a username and password.
#[derive(Clone)]
pub struct PasswordSignIn {
    /// Signs in and keeps the session.
    keeping: Arc<Keeping>,
    /// The base URL discovery resolved.
    homeserver: Url,
}

impl PasswordSignIn {
    /// Signs in as `user` (trimmed) with `password` and keeps the session.
    ///
    /// # Errors
    ///
    /// The handle comes back with why it didn't sign in; see [`PasswordError`].
    #[expect(
        clippy::result_large_err,
        reason = "the handle comes back by value so the UI can retry; it is returned once per attempt"
    )]
    pub async fn sign_in(self, user: &str, password: &str) -> Result<(), Failed<Self, PasswordError>> {
        if let Some(fields) = EmptyFields::of(user, password) {
            return Err(Failed {
                handle: self,
                error: PasswordError::Empty(fields),
            });
        }
        let trimmed = user.trim();
        let signed_in = self
            .keeping
            .sign_in(&self.homeserver, async |client, device_name| {
                sdk::password_sign_in(client, trimmed, password, device_name).await
            })
            .await;
        signed_in.map_err(|kept| Failed {
            handle: self,
            error: kept.into(),
        })
    }
}

// Shows where it signs in to, not the core behind it.
impl fmt::Debug for PasswordSignIn {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PasswordSignIn")
            .field("homeserver", &self.homeserver.as_str())
            .finish_non_exhaustive()
    }
}

/// Signing in to one server in the system browser, by OAuth or one SSO provider.
#[derive(Clone)]
pub struct BrowserSignIn {
    /// Signs in and keeps the session.
    keeping: Arc<Keeping>,
    /// The base URL discovery resolved.
    homeserver: Url,
    /// The provider's name, or the server's for OAuth.
    name: String,
    /// OAuth, or which SSO provider.
    method: BrowserMethod,
}

impl BrowserSignIn {
    /// The provider's name, or the server's for OAuth.
    #[must_use]
    pub fn name(&self) -> &str {
        &self.name
    }

    /// Signs in through the platform's `AuthBrowser` and keeps the session.
    ///
    /// # Errors
    ///
    /// The handle comes back with why it didn't sign in; see [`BrowserError`].
    #[expect(
        clippy::result_large_err,
        reason = "the handle comes back by value so the UI can retry; it is returned once per attempt"
    )]
    pub async fn sign_in(self) -> Result<(), Failed<Self, BrowserError>> {
        let browser = self.keeping.auth_browser();
        let signed_in = self
            .keeping
            .sign_in(&self.homeserver, async |client, device_name| match &self.method {
                BrowserMethod::OAuth => sdk::oauth_sign_in(client, browser.as_ref()).await,
                BrowserMethod::Sso { provider, name: _ } => {
                    sdk::sso_sign_in(client, browser.as_ref(), provider.as_deref(), device_name).await
                }
            })
            .await;
        signed_in.map_err(|kept| Failed {
            handle: self,
            error: kept.into(),
        })
    }
}

// Shows which sign-in it is, not the core behind it.
impl fmt::Debug for BrowserSignIn {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("BrowserSignIn")
            .field("name", &self.name)
            .field("method", &self.method)
            .finish_non_exhaustive()
    }
}
