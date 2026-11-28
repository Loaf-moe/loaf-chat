//! The session: discovery, signing in on a fresh store, restoring at start,
//! storing refreshed tokens and signing out.

use alloc::sync::{Arc, Weak};
use core::sync::atomic::{AtomicBool, Ordering};
use core::time::Duration;
use std::io::ErrorKind;
use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard, PoisonError};

use eyeball::{SharedObservable, Subscriber};
use matrix_sdk::{Client, SessionChange};
use rand::distr::{Alphanumeric, SampleString as _};
use tokio::fs::remove_dir_all;
use tokio::sync::Mutex as AsyncMutex;
use tokio::sync::broadcast::Receiver;
use tokio::sync::broadcast::error::RecvError;
use tokio::task::JoinHandle;
use tokio::time::timeout;
use url::Url;

use super::error::{BrowserError, DiscoverError, FinishError, PasswordError};
use super::sign_in::Server;
use super::stored::{PASSPHRASE_KEY, SESSION_KEY, StoredSession};
use super::{DeviceId, SessionState, UserId, sdk, server};
use crate::core::Platform;
use crate::ports::auth_browser::AuthBrowser;
use crate::ports::secret_store::{SecretStore, SecretStoreError};

/// How long a server logout may take before local data is wiped anyway.
const LOGOUT_TIMEOUT: Duration = Duration::from_secs(15);
/// Characters in the passphrase that encrypts the SDK store.
const PASSPHRASE_LENGTH: usize = 32;

/// The account on this device: its state, the signed-in client and the
/// secrets behind them. A shell watches and changes it through `Core`.
pub struct Session {
    /// What the shell observes.
    state: SharedObservable<SessionState>,
    /// Where the session and the store passphrase are kept.
    secrets: Arc<dyn SecretStore>,
    /// The system browser for browser sign-ins.
    auth_browser: Arc<dyn AuthBrowser>,
    /// The name other sessions see for this device.
    device_name: String,
    /// matrix-sdk's store: `data_dir/matrix`.
    store_dir: PathBuf,
    /// Held for the whole of a sign-in, so a second one finds it taken.
    signing_in: AsyncMutex<()>,
    /// A sign-out is under way; another call does nothing.
    signing_out: AtomicBool,
    /// The signed-in client and the task keeping its tokens.
    signed_in: Mutex<Option<SignedIn>>,
}

/// A signed-in client and the task writing its refreshed tokens.
struct SignedIn {
    /// Signed in and refreshing its own tokens.
    client: Client,
    /// Runs [`keep_tokens`] for `client`.
    listener: JoinHandle<()>,
}

/// Why `Session::sign_in` didn't sign in.
#[derive(Debug)]
pub(crate) enum SignInError<E> {
    /// Another sign-in holds the guard.
    Busy,
    /// An account is signed in.
    NotSignedOut,
    /// The server accepted, but the session couldn't be kept.
    CouldntFinish(FinishError),
    /// The sign-in itself failed.
    SignIn(E),
}

impl From<SignInError<PasswordError>> for PasswordError {
    fn from(error: SignInError<Self>) -> Self {
        match error {
            SignInError::Busy => Self::Busy,
            SignInError::NotSignedOut => Self::NotSignedOut,
            SignInError::CouldntFinish(finish) => finish.into(),
            SignInError::SignIn(sign_in) => sign_in,
        }
    }
}

impl From<SignInError<BrowserError>> for BrowserError {
    fn from(error: SignInError<Self>) -> Self {
        match error {
            SignInError::Busy => Self::Busy,
            SignInError::NotSignedOut => Self::NotSignedOut,
            SignInError::CouldntFinish(finish) => finish.into(),
            SignInError::SignIn(sign_in) => sign_in,
        }
    }
}

impl Session {
    /// A session that starts signed out, before [`Self::restore`] has run.
    pub(crate) fn new(platform: Platform, device_name: String, store_dir: PathBuf) -> Self {
        Self {
            state: SharedObservable::new(SessionState::SignedOut),
            secrets: platform.secrets,
            auth_browser: platform.auth_browser,
            device_name,
            store_dir,
            signing_in: AsyncMutex::new(()),
            signing_out: AtomicBool::new(false),
            signed_in: Mutex::new(None),
        }
    }

    /// A subscriber whose first `next()` yields the current state at once;
    /// each later `next()` waits for a change.
    pub fn state(&self) -> Subscriber<SessionState> {
        self.state.subscribe_reset()
    }

    /// Finds the server `input` names (a server name, URL or full user id)
    /// and what it offers to sign in with.
    ///
    /// # Errors
    ///
    /// See [`DiscoverError`].
    pub async fn discover(self: &Arc<Self>, input: &str) -> Result<Server, DiscoverError> {
        if !self.is_signed_out() {
            return Err(DiscoverError::NotSignedOut);
        }
        let host = server::parse_server(input).ok_or(DiscoverError::NotAServer)?;
        let address = if server::typed_http(input) {
            format!("http://{host}")
        } else {
            host.clone()
        };
        let probe = sdk::probe(&address).await?;
        Ok(Server::new(self, host, probe))
    }

    /// A poisoned lock only means a panic elsewhere; the slot is assigned
    /// whole, so it stays consistent.
    fn signed_in(&self) -> MutexGuard<'_, Option<SignedIn>> {
        self.signed_in.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// No account is signed in.
    pub(crate) fn is_signed_out(&self) -> bool {
        self.state.get() == SessionState::SignedOut
    }

    /// The system browser browser sign-ins open their pages in.
    pub(crate) fn auth_browser(&self) -> Arc<dyn AuthBrowser> {
        Arc::clone(&self.auth_browser)
    }

    /// The signed-in client.
    #[cfg(test)]
    pub(crate) fn client(&self) -> Option<Client> {
        self.signed_in().as_ref().map(|signed_in| signed_in.client.clone())
    }

    /// Signs in to `homeserver` with `sign_in` on a fresh store, then keeps
    /// the session: its secrets written, then `SignedIn` published.
    pub(crate) async fn sign_in<E>(
        self: &Arc<Self>,
        homeserver: &Url,
        sign_in: impl AsyncFnOnce(&Client, &str) -> Result<(), E>,
    ) -> Result<(), SignInError<E>> {
        let Ok(_guard) = self.signing_in.try_lock() else {
            return Err(SignInError::Busy);
        };
        if !self.is_signed_out() {
            return Err(SignInError::NotSignedOut);
        }
        // Signed out, so nothing in the store is worth keeping; a sign-in
        // dropped earlier may have left one behind.
        self.wipe_store().await;
        let passphrase = Alphanumeric.sample_string(&mut rand::rng(), PASSPHRASE_LENGTH);
        let client = match sdk::sign_in_client(homeserver, &self.store_dir, &passphrase).await {
            Ok(client) => client,
            Err(error) => {
                tracing::warn!(%error, "couldn't open a store to sign in on");
                self.wipe_store().await;
                return Err(SignInError::CouldntFinish(error));
            }
        };
        if let Err(error) = sign_in(&client, &self.device_name).await {
            close(client).await;
            self.wipe_store().await;
            return Err(SignInError::SignIn(error));
        }
        let written = match StoredSession::try_from(&client) {
            Ok(session) => self
                .write_secrets(&session, &passphrase)
                .await
                .map(|()| session)
                .map_err(FinishError::from),
            Err(no_session) => Err(no_session.into()),
        };
        match written {
            Ok(session) => {
                self.keep(client, session.user, session.device);
                Ok(())
            }
            Err(error) => {
                tracing::warn!(%error, "couldn't store the signed-in session; logging it out");
                log_out(&client).await;
                close(client).await;
                self.wipe_local().await;
                Err(SignInError::CouldntFinish(error))
            }
        }
    }

    /// Writes `session`, then the passphrase its store is encrypted with.
    async fn write_secrets(&self, session: &StoredSession, passphrase: &str) -> Result<(), SecretStoreError> {
        self.secrets.set(SESSION_KEY, &session.to_secret()).await?;
        self.secrets.set(PASSPHRASE_KEY, passphrase).await
    }

    /// Signs in from the stored session with no network. A missing or
    /// unreadable session, or a store that won't restore, wipes local data;
    /// a secret store that errors leaves it alone so the next launch can retry.
    pub(crate) async fn restore(self: &Arc<Self>) {
        let secret = match self.secrets.get(SESSION_KEY).await {
            Ok(Some(secret)) => secret,
            Ok(None) => return self.wipe_local().await,
            Err(error) => return tracing::warn!(%error, "secret store unavailable at start; staying signed out"),
        };
        let Ok(session) = StoredSession::from_secret(&secret) else {
            tracing::warn!("stored session is unreadable; wiping local data");
            return self.wipe_local().await;
        };
        let passphrase = match self.secrets.get(PASSPHRASE_KEY).await {
            Ok(Some(passphrase)) => passphrase,
            Ok(None) => {
                tracing::warn!("store passphrase is missing; wiping local data");
                return self.wipe_local().await;
            }
            Err(error) => return tracing::warn!(%error, "secret store unavailable at start; staying signed out"),
        };
        match sdk::restore(&session, &self.store_dir, &passphrase).await {
            Ok(client) => self.keep(client, session.user, session.device),
            Err(error) => {
                tracing::warn!(%error, "wiping local data");
                self.wipe_local().await;
            }
        }
    }

    /// Holds `client` as the signed-in one, starts writing its refreshed
    /// tokens, and publishes `SignedIn`.
    fn keep(self: &Arc<Self>, client: Client, user: UserId, device: DeviceId) {
        // Subscribed before the task starts, so no change is missed.
        let changes = client.subscribe_to_session_changes();
        let listener = tokio::spawn(keep_tokens(Arc::downgrade(self), changes));
        *self.signed_in() = Some(SignedIn { client, listener });
        self.state.set(SessionState::SignedIn { user, device });
    }

    /// Writes the session as the client now holds it, after a token refresh.
    async fn store_refreshed(&self) {
        let current = self
            .signed_in()
            .as_ref()
            .and_then(|signed_in| StoredSession::try_from(&signed_in.client).ok());
        let Some(session) = current else { return };
        if let Err(error) = self.secrets.set(SESSION_KEY, &session.to_secret()).await {
            tracing::warn!(%error, "couldn't store refreshed tokens");
        }
    }

    /// The token couldn't be refreshed: wipes local data and publishes `SignedOut`.
    async fn lose_session(&self) {
        if self.signing_out.load(Ordering::SeqCst) {
            return;
        }
        tracing::warn!("session token couldn't be refreshed; signing out");
        // Detaches the listener, which is the task running this.
        let signed_in = self.signed_in().take();
        if let Some(SignedIn { client, listener: _ }) = signed_in {
            close(client).await;
        }
        self.wipe_local().await;
        self.state.set(SessionState::SignedOut);
    }

    /// Logs out on the server where it can, then always wipes this device's
    /// data and publishes `SignedOut`. Runs to the end even if the caller
    /// stops waiting; a call while one is under way does nothing.
    pub async fn sign_out(self: &Arc<Self>) {
        if self.signing_out.swap(true, Ordering::SeqCst) {
            return;
        }
        let session = Arc::clone(self);
        let signing_out = tokio::spawn(async move {
            let signed_in = session.signed_in().take();
            if let Some(SignedIn { client, listener }) = signed_in {
                listener.abort();
                log_out(&client).await;
                close(client).await;
                session.wipe_local().await;
                session.state.set(SessionState::SignedOut);
            }
            session.signing_out.store(false, Ordering::SeqCst);
        });
        if let Err(error) = signing_out.await {
            tracing::warn!(%error, "sign-out stopped early");
        }
    }

    /// Deletes the Matrix store and both secrets. A failing step is logged
    /// and the rest still run; the next launch wipes whichever half is left.
    async fn wipe_local(&self) {
        self.wipe_store().await;
        for key in [SESSION_KEY, PASSPHRASE_KEY] {
            if let Err(error) = self.secrets.delete(key).await {
                tracing::warn!(%error, key, "couldn't delete a stored secret");
            }
        }
    }

    /// Deletes matrix-sdk's store; one that isn't there is already deleted.
    async fn wipe_store(&self) {
        match remove_dir_all(&self.store_dir).await {
            Err(error) if error.kind() != ErrorKind::NotFound => {
                tracing::warn!(%error, "couldn't delete the Matrix store");
            }
            Ok(()) | Err(_) => {}
        }
    }
}

/// Closes `client`'s stores, waiting for anything in flight, so nothing it
/// still holds writes into the store after it is wiped.
async fn close(client: Client) {
    if let Err(error) = sdk::close(&client).await {
        tracing::warn!(%error, "couldn't close the Matrix store");
    }
}

/// Logs `client` out on the server, giving up after [`LOGOUT_TIMEOUT`].
async fn log_out(client: &Client) {
    match timeout(LOGOUT_TIMEOUT, sdk::log_out(client)).await {
        Ok(Ok(())) => {}
        Ok(Err(error)) => tracing::warn!(%error, "server logout failed"),
        Err(_elapsed) => tracing::warn!("server logout timed out"),
    }
}

/// Follows the client's session changes for as long as it is kept: writes
/// refreshed tokens, and signs out when the token is lost.
async fn keep_tokens(weak: Weak<Session>, mut changes: Receiver<SessionChange>) {
    loop {
        let change = changes.recv().await;
        let Some(session) = weak.upgrade() else { return };
        match change {
            // A missed change may have been a refresh; the client's current
            // tokens are what to keep either way.
            Ok(SessionChange::TokensRefreshed) | Err(RecvError::Lagged(_)) => session.store_refreshed().await,
            Ok(SessionChange::UnknownToken(_)) => return session.lose_session().await,
            Err(RecvError::Closed) => return,
        }
    }
}
