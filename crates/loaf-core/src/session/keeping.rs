//! Keeping the session across launches: committing a sign-in and restoring it at start.

use alloc::sync::Arc;
use std::sync::{Mutex, MutexGuard, PoisonError};

use eyeball::{SharedObservable, Subscriber};

use crate::core::Platform;
use crate::ports::auth_browser::AuthBrowser;
use crate::ports::matrix::{Account, Attempt, Matrix};
use crate::ports::secret_store::{SecretStore, SecretStoreError};
use crate::session::stored::{PASSPHRASE_KEY, SESSION_KEY};
use crate::session::{NotSignedOut, SessionState, StoredSession};

/// Owns the session state and the stored secrets behind it.
pub(crate) struct Keeping {
    /// What the shell observes.
    state: SharedObservable<SessionState>,
    /// Where the session and the store passphrase are kept.
    secrets: Arc<dyn SecretStore>,
    /// The homeserver side: restoring and wiping the SDK store.
    matrix: Arc<dyn Matrix>,
    /// The system browser for browser sign-ins.
    #[expect(dead_code, reason = "used from Task 8")]
    auth_browser: Arc<dyn AuthBrowser>,
    /// The name other sessions see for this device.
    device_name: String,
    /// The signed-in account, restored or committed.
    account: Mutex<Option<Arc<dyn Account>>>,
    /// Which flow may sign in, and whether one is being kept. Beginning a
    /// flow and claiming a commit both decide under this one lock, so two
    /// flows can never both commit.
    flows: Mutex<Flows>,
}

/// The sign-in flows' share of [`Keeping`], behind `Keeping::flows`.
struct Flows {
    /// Bumped by each new flow; only the flow holding the latest may commit.
    generation: u64,
    /// A claimed commit is under way; no flow begins or commits until it ends.
    committing: bool,
}

/// The right to commit one sign-in, from [`Keeping::claim_commit`]. Dropping
/// it, after the commit has published its outcome, lets flows begin again.
pub(crate) struct CommitClaim<'keeping> {
    /// Released on drop.
    keeping: &'keeping Keeping,
}

impl Drop for CommitClaim<'_> {
    fn drop(&mut self) {
        self.keeping.flows().committing = false;
    }
}

/// Keeping a signed-in session failed; nothing of it was kept.
#[derive(Debug)]
pub(crate) struct CommitFailed;

impl Keeping {
    /// A keeper that starts signed out, before [`Self::restore`] has run.
    pub(crate) fn new(platform: Platform, device_name: String, matrix: Arc<dyn Matrix>) -> Self {
        Self {
            state: SharedObservable::new(SessionState::SignedOut),
            secrets: platform.secrets,
            matrix,
            auth_browser: platform.auth_browser,
            device_name,
            account: Mutex::new(None),
            flows: Mutex::new(Flows {
                generation: 0,
                committing: false,
            }),
        }
    }

    /// A poisoned lock only means a panic elsewhere; its fields are plain
    /// values assigned whole, so they stay consistent.
    fn flows(&self) -> MutexGuard<'_, Flows> {
        self.flows.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Starts a new flow generation, making every earlier flow inert.
    ///
    /// # Errors
    ///
    /// [`NotSignedOut`] while an account is signed in or a sign-in is being kept.
    pub(crate) fn begin_flow(&self) -> Result<u64, NotSignedOut> {
        let mut flows = self.flows();
        if flows.committing || self.state.get() != SessionState::SignedOut {
            return Err(NotSignedOut);
        }
        flows.generation = flows.generation.wrapping_add(1);
        Ok(flows.generation)
    }

    /// Whether no flow has begun since the one in `generation`.
    pub(crate) fn is_current_flow(&self, generation: u64) -> bool {
        self.flows().generation == generation
    }

    /// The right to commit, for the flow in `generation` if it is still the
    /// newest, nothing is signed in and no other commit is under way.
    pub(crate) fn claim_commit(&self, generation: u64) -> Option<CommitClaim<'_>> {
        let mut flows = self.flows();
        if flows.generation != generation || flows.committing || self.state.get() != SessionState::SignedOut {
            return None;
        }
        flows.committing = true;
        Some(CommitClaim { keeping: self })
    }

    /// The name other sessions see for this device.
    pub(crate) fn device_name(&self) -> &str {
        &self.device_name
    }

    /// Keeps a signed-in `session`: writes it and the store passphrase to the
    /// secret store, commits `attempt`'s store as the account's own, then
    /// publishes `SignedIn`. A failure deletes the secrets written so far,
    /// and an attempt not yet committed is discarded, logging its token out.
    pub(crate) async fn commit(
        &self,
        claim: CommitClaim<'_>,
        attempt: Box<dyn Attempt>,
        session: StoredSession,
        passphrase: String,
    ) -> Result<(), CommitFailed> {
        if let Err(error) = self.secrets.set(SESSION_KEY, &session.to_secret()).await {
            return self.abandon(attempt, &[], &error).await;
        }
        if let Err(error) = self.secrets.set(PASSPHRASE_KEY, &passphrase).await {
            return self.abandon(attempt, &[SESSION_KEY], &error).await;
        }
        match attempt.commit(&session).await {
            Ok(account) => {
                *self.account.lock().unwrap_or_else(PoisonError::into_inner) = Some(account);
                self.state.set(SessionState::SignedIn {
                    user: session.user,
                    device: session.device,
                });
                drop(claim);
                Ok(())
            }
            Err(error) => {
                tracing::warn!(%error, "couldn't keep the signed-in account");
                self.delete_secrets(&[SESSION_KEY, PASSPHRASE_KEY]).await;
                Err(CommitFailed)
            }
        }
    }

    /// Gives up on a commit whose secret write failed: discards `attempt`,
    /// logging its token out, and deletes the secrets already `written`.
    async fn abandon(
        &self,
        attempt: Box<dyn Attempt>,
        written: &[&str],
        error: &SecretStoreError,
    ) -> Result<(), CommitFailed> {
        tracing::warn!(%error, "couldn't store the signed-in session");
        attempt.discard().await;
        self.delete_secrets(written).await;
        Err(CommitFailed)
    }

    /// Deletes `keys` from the secret store, logging any that fail.
    async fn delete_secrets(&self, keys: &[&str]) {
        for &key in keys {
            if let Err(error) = self.secrets.delete(key).await {
                tracing::warn!(%error, key, "couldn't delete a stored secret");
            }
        }
    }

    /// The homeserver side, for probing during sign-in.
    pub(crate) fn matrix(&self) -> &Arc<dyn Matrix> {
        &self.matrix
    }

    /// A subscriber whose first `next()` yields the current state; later ones wait for a change.
    pub(crate) fn state(&self) -> Subscriber<SessionState> {
        self.state.subscribe_reset()
    }

    /// Signs in from the stored session with no network. A missing or
    /// unreadable session, or a store that won't restore, wipes local data;
    /// a secret store that errors leaves it alone so the next launch can retry.
    pub(crate) async fn restore(&self) {
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
        match self.matrix.restore(&session, &passphrase).await {
            Ok(account) => {
                *self.account.lock().unwrap_or_else(PoisonError::into_inner) = Some(account);
                self.state.set(SessionState::SignedIn {
                    user: session.user,
                    device: session.device,
                });
            }
            Err(error) => {
                tracing::warn!(%error, "stored session won't restore; wiping local data");
                self.wipe_local().await;
            }
        }
    }

    /// Deletes the Matrix store and both secrets. A failing step is logged
    /// and the rest still run; the next launch wipes whichever half is left.
    pub(crate) async fn wipe_local(&self) {
        if let Err(error) = self.matrix.wipe().await {
            tracing::warn!(%error, "couldn't delete the Matrix store");
        }
        self.delete_secrets(&[SESSION_KEY, PASSPHRASE_KEY]).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::{Core, CoreConfig};
    use crate::fakes::{FakeAccount, FakeAuthBrowser, FakeMatrix, FakeSecretStore};
    use crate::ports::matrix::WontRestore;
    use crate::session::stored::{PASSPHRASE_KEY, SESSION_KEY, StoredAuth};
    use crate::session::{DeviceId, StoredSession, UserId};
    use core::time::Duration;
    use std::path::PathBuf;
    use tokio::task::{JoinHandle, yield_now};
    use tokio::time::timeout;
    use url::Url;

    fn stored() -> StoredSession {
        StoredSession {
            homeserver: Url::parse("https://matrix.example.org").unwrap(),
            user: UserId::from("@alice:example.org".to_owned()),
            device: DeviceId::from("DEVICE1".to_owned()),
            auth: StoredAuth::Matrix {
                access_token: "syt_access_secret".into(),
                refresh_token: None,
            },
        }
    }

    fn config(secrets: &Arc<FakeSecretStore>) -> CoreConfig {
        CoreConfig {
            data_dir: PathBuf::from("data"),
            device_name: "Test".into(),
            platform: Platform {
                secrets: Arc::<FakeSecretStore>::clone(secrets),
                auth_browser: FakeAuthBrowser::new(Url::parse("http://127.0.0.1:1/").unwrap()),
            },
        }
    }

    async fn state_after_start(secrets: &Arc<FakeSecretStore>, fake: &Arc<FakeMatrix>) -> SessionState {
        let core = Core::start_with(config(secrets), Arc::<FakeMatrix>::clone(fake)).await;
        core.session().state().get()
    }

    fn spawn_start(secrets: &Arc<FakeSecretStore>, fake: &Arc<FakeMatrix>) -> JoinHandle<SessionState> {
        let secrets_for_task = Arc::clone(secrets);
        let fake_for_task = Arc::clone(fake);
        tokio::spawn(async move { state_after_start(&secrets_for_task, &fake_for_task).await })
    }

    /// A store holding `session`, and the passphrase when there is one.
    async fn secrets_with(session: Option<&str>, passphrase: Option<&str>) -> Arc<FakeSecretStore> {
        let secrets = Arc::new(FakeSecretStore::new());
        for (key, secret) in [(SESSION_KEY, session), (PASSPHRASE_KEY, passphrase)] {
            if let Some(text) = secret {
                secrets.set(key, text).await.unwrap();
            }
        }
        secrets
    }

    fn both_deleted(secrets: &FakeSecretStore) -> bool {
        secrets.value(SESSION_KEY).is_none() && secrets.value(PASSPHRASE_KEY).is_none()
    }

    #[tokio::test(start_paused = true)]
    async fn nothing_stored_starts_signed_out() {
        let secrets = secrets_with(None, Some("pass")).await;
        let fake = FakeMatrix::new();
        assert_eq!(state_after_start(&secrets, &fake).await, SessionState::SignedOut);
        assert_eq!(fake.wipes(), 1);
        assert_eq!(secrets.value(PASSPHRASE_KEY), None);
    }

    #[tokio::test(start_paused = true)]
    async fn stored_session_restores_signed_in() {
        let secrets = secrets_with(Some(&stored().to_secret()), Some("pass")).await;
        let fake = FakeMatrix::new();
        let start = spawn_start(&secrets, &fake);
        let restore = fake.next_restore().await;
        assert_eq!(restore.session, stored());
        assert_eq!(restore.passphrase, "pass");
        yield_now().await;
        assert!(!start.is_finished());
        restore.reply(Ok(FakeAccount::new(&fake)));
        assert_eq!(
            start.await.unwrap(),
            SessionState::SignedIn {
                user: stored().user,
                device: stored().device,
            }
        );
        assert_eq!(fake.wipes(), 0);
    }

    #[tokio::test(start_paused = true)]
    async fn secret_store_error_signs_out_without_wiping() {
        let secrets = secrets_with(Some(&stored().to_secret()), Some("pass")).await;
        secrets.fail_gets();
        let fake = FakeMatrix::new();
        assert_eq!(state_after_start(&secrets, &fake).await, SessionState::SignedOut);
        assert_eq!(fake.wipes(), 0);
        assert!(secrets.value(SESSION_KEY).is_some());
        assert!(secrets.value(PASSPHRASE_KEY).is_some());
    }

    #[tokio::test(start_paused = true)]
    async fn corrupt_session_wipes() {
        let secrets = secrets_with(Some("{"), Some("pass")).await;
        let fake = FakeMatrix::new();
        assert_eq!(state_after_start(&secrets, &fake).await, SessionState::SignedOut);
        assert_eq!(fake.wipes(), 1);
        assert!(both_deleted(&secrets));
    }

    #[tokio::test(start_paused = true)]
    async fn store_that_wont_restore_wipes() {
        let secrets = secrets_with(Some(&stored().to_secret()), Some("pass")).await;
        let fake = FakeMatrix::new();
        let start = spawn_start(&secrets, &fake);
        fake.next_restore().await.reply(Err(WontRestore));
        assert_eq!(start.await.unwrap(), SessionState::SignedOut);
        assert_eq!(fake.wipes(), 1);
        assert!(both_deleted(&secrets));
    }

    #[tokio::test(start_paused = true)]
    async fn only_the_newest_flow_claims_the_commit_and_begin_waits_for_it() {
        let secrets = Arc::new(FakeSecretStore::new());
        let keeping = Keeping::new(config(&secrets).platform, "Test".into(), FakeMatrix::new());
        let first = keeping.begin_flow().unwrap();
        let second = keeping.begin_flow().unwrap();
        assert!(keeping.claim_commit(first).is_none());

        let claim = keeping.claim_commit(second).unwrap();
        assert!(keeping.claim_commit(second).is_none());
        keeping.begin_flow().unwrap_err();
        drop(claim);
        keeping.begin_flow().unwrap();
    }

    #[tokio::test(start_paused = true)]
    async fn state_subscriber_yields_current_state_first() {
        let secrets = secrets_with(Some(&stored().to_secret()), Some("pass")).await;
        let fake = FakeMatrix::new();
        let start = tokio::spawn({
            let secrets_for_task = Arc::clone(&secrets);
            let fake_for_task = Arc::clone(&fake);
            async move { Core::start_with(config(&secrets_for_task), fake_for_task).await }
        });
        fake.next_restore().await.reply(Ok(FakeAccount::new(&fake)));
        let core = start.await.unwrap();
        let mut state = core.session().state();
        let first = timeout(Duration::from_secs(1), state.next()).await.unwrap();
        assert_eq!(
            first,
            Some(SessionState::SignedIn {
                user: stored().user,
                device: stored().device,
            })
        );
    }
}
