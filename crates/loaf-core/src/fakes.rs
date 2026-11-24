//! In-memory stand-ins for the ports, driven by the core's tests.

use alloc::sync::{Arc, Weak};
use core::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard, PoisonError};

use async_trait::async_trait;
use tokio::sync::Mutex as AsyncMutex;
use tokio::sync::{Notify, mpsc, oneshot};
use url::Url;

use crate::ports::auth_browser::{AuthBrowser, AuthBrowserError};
use crate::ports::matrix::{
    Account, Attempt, AttemptError, CommitError, FinishError, LogoutError, Matrix, PasswordError, Probe, ServerOffer,
    SessionChange, Unreachable, WipeError, WontRestore,
};
use crate::ports::secret_store::{SecretStore, SecretStoreError};
use crate::session::{BrowserMethod, StoredSession};

/// A `SecretStore` in memory that fails when a test says so.
#[derive(Default)]
pub struct FakeSecretStore {
    values: Mutex<HashMap<String, String>>,
    fail_next_set: AtomicBool,
    fail_next_set_of: Mutex<Option<String>>,
    fail_gets: AtomicBool,
}

impl FakeSecretStore {
    pub fn new() -> Self {
        Self::default()
    }

    /// The next `set` fails; the one after succeeds.
    pub fn fail_next_set(&self) {
        self.fail_next_set.store(true, Ordering::SeqCst);
    }

    /// The next `set` of `key` fails; sets of other keys still succeed.
    pub fn fail_next_set_of(&self, key: &str) {
        *lock(&self.fail_next_set_of) = Some(key.to_owned());
    }

    /// Every `get` fails from now on.
    pub fn fail_gets(&self) {
        self.fail_gets.store(true, Ordering::SeqCst);
    }

    /// What is stored under `key`, read without going through the port.
    pub fn value(&self, key: &str) -> Option<String> {
        self.values().get(key).cloned()
    }

    // A poisoned lock only means another test thread panicked; the map is still sound.
    fn values(&self) -> MutexGuard<'_, HashMap<String, String>> {
        self.values.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

#[async_trait]
impl SecretStore for FakeSecretStore {
    async fn get(&self, key: &str) -> Result<Option<String>, SecretStoreError> {
        if self.fail_gets.load(Ordering::SeqCst) {
            return Err(SecretStoreError("keychain locked".into()));
        }
        Ok(self.value(key))
    }

    async fn set(&self, key: &str, value: &str) -> Result<(), SecretStoreError> {
        let failing_key = {
            let mut failing = lock(&self.fail_next_set_of);
            let matches = failing.as_deref() == Some(key);
            if matches {
                *failing = None;
            }
            matches
        };
        if self.fail_next_set.swap(false, Ordering::SeqCst) || failing_key {
            return Err(SecretStoreError("keychain locked".into()));
        }
        self.values().insert(key.to_owned(), value.to_owned());
        Ok(())
    }

    async fn delete(&self, key: &str) -> Result<(), SecretStoreError> {
        self.values().remove(key);
        Ok(())
    }
}

// A poisoned lock only means another test thread panicked; the data is still sound.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The calls of one port method, queued until the test takes them.
struct Calls<T> {
    sender: mpsc::UnboundedSender<T>,
    receiver: AsyncMutex<mpsc::UnboundedReceiver<T>>,
}

impl<T> Calls<T> {
    fn new() -> Self {
        let (sender, receiver) = mpsc::unbounded_channel();
        Self {
            sender,
            receiver: AsyncMutex::new(receiver),
        }
    }

    /// Queues `call` and waits for the test's answer, or `unanswered` when
    /// the test drops the call without replying.
    async fn ask<R>(&self, call: impl FnOnce(oneshot::Sender<R>) -> T, unanswered: R) -> R {
        let (reply, answer) = oneshot::channel();
        // The receiver lives as long as `self`, so the send can't fail.
        let _queued = self.sender.send(call(reply));
        answer.await.unwrap_or(unanswered)
    }

    async fn next(&self) -> T {
        self.receiver
            .lock()
            .await
            .recv()
            .await
            .expect("the sender lives as long as the receiver")
    }
}

/// Sends `answer` to a caller that may have stopped listening, as a
/// cancelled flow does.
fn answer<R>(reply: oneshot::Sender<R>, answer: R) {
    let _heard = reply.send(answer);
}

/// A `Matrix` whose every awaited call waits until the test answers it.
///
/// Attempts and accounts route their calls back here, so one `FakeMatrix`
/// sees every call. Probes are numbered from 0 in call order, and each
/// attempt's calls carry the number of the probe that started it.
pub struct FakeMatrix {
    me: Weak<FakeMatrix>,
    probes: Calls<ProbeCall>,
    passwords: Calls<PasswordCall>,
    browser_urls: Calls<BrowserUrlCall>,
    finishes: Calls<FinishCall>,
    commit_calls: Calls<CommitCall>,
    restores: Calls<RestoreCall>,
    logouts: Calls<LogoutCall>,
    probe_count: AtomicUsize,
    commits: AtomicUsize,
    discarded: AtomicUsize,
    discarded_logged_out: AtomicUsize,
    wipes: AtomicUsize,
}

impl FakeMatrix {
    pub fn new() -> Arc<Self> {
        Arc::new_cyclic(|me| Self {
            me: Weak::clone(me),
            probes: Calls::new(),
            passwords: Calls::new(),
            browser_urls: Calls::new(),
            finishes: Calls::new(),
            commit_calls: Calls::new(),
            restores: Calls::new(),
            logouts: Calls::new(),
            probe_count: AtomicUsize::new(0),
            commits: AtomicUsize::new(0),
            discarded: AtomicUsize::new(0),
            discarded_logged_out: AtomicUsize::new(0),
            wipes: AtomicUsize::new(0),
        })
    }

    pub async fn next_probe(&self) -> ProbeCall {
        self.probes.next().await
    }

    pub async fn next_password(&self) -> PasswordCall {
        self.passwords.next().await
    }

    pub async fn next_browser_url(&self) -> BrowserUrlCall {
        self.browser_urls.next().await
    }

    pub async fn next_finish(&self) -> FinishCall {
        self.finishes.next().await
    }

    pub async fn next_commit(&self) -> CommitCall {
        self.commit_calls.next().await
    }

    pub async fn next_restore(&self) -> RestoreCall {
        self.restores.next().await
    }

    pub async fn next_logout(&self) -> LogoutCall {
        self.logouts.next().await
    }

    /// Commits answered `Ok`.
    pub fn commits(&self) -> usize {
        self.commits.load(Ordering::SeqCst)
    }

    /// Attempts discarded, whether or not they had signed in.
    pub fn discarded(&self) -> usize {
        self.discarded.load(Ordering::SeqCst)
    }

    /// Discarded attempts that had signed in, whose token a real one logs out.
    pub fn discarded_logged_out(&self) -> usize {
        self.discarded_logged_out.load(Ordering::SeqCst)
    }

    pub fn wipes(&self) -> usize {
        self.wipes.load(Ordering::SeqCst)
    }
}

#[async_trait]
impl Matrix for FakeMatrix {
    async fn probe(&self, server: &str, passphrase: &str) -> Result<Probe, Unreachable> {
        let attempt = self.probe_count.fetch_add(1, Ordering::SeqCst);
        let found = self
            .probes
            .ask(
                |sender| ProbeCall {
                    attempt,
                    server: server.to_owned(),
                    passphrase: passphrase.to_owned(),
                    sender,
                },
                Err(Unreachable),
            )
            .await?;
        Ok(Probe {
            offer: found.offer,
            attempt: Box::new(FakeAttempt {
                id: attempt,
                matrix: self.me.upgrade().expect("FakeMatrix outlives its calls"),
                signed_in: AtomicBool::new(false),
            }),
        })
    }

    async fn restore(&self, session: &StoredSession, passphrase: &str) -> Result<Arc<dyn Account>, WontRestore> {
        self.restores
            .ask(
                |sender| RestoreCall {
                    session: session.clone(),
                    passphrase: passphrase.to_owned(),
                    sender,
                },
                Err(WontRestore),
            )
            .await
    }

    async fn wipe(&self) -> Result<(), WipeError> {
        self.wipes.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }
}

/// A probe call; `attempt` numbers the attempt an `Ok` reply starts.
pub struct ProbeCall {
    pub attempt: usize,
    pub server: String,
    pub passphrase: String,
    pub sender: oneshot::Sender<Result<FakeProbe, Unreachable>>,
}

impl ProbeCall {
    pub fn reply(self, result: Result<FakeProbe, Unreachable>) {
        answer(self.sender, result);
    }
}

/// What a found server answers to a probe.
pub struct FakeProbe {
    offer: ServerOffer,
}

impl FakeProbe {
    pub fn new(offer: ServerOffer) -> Self {
        Self { offer }
    }
}

pub struct PasswordCall {
    pub attempt: usize,
    pub user: String,
    pub password: String,
    pub device_name: String,
    pub sender: oneshot::Sender<Result<StoredSession, PasswordError>>,
}

impl PasswordCall {
    pub fn reply(self, result: Result<StoredSession, PasswordError>) {
        answer(self.sender, result);
    }
}

pub struct BrowserUrlCall {
    pub attempt: usize,
    pub method: BrowserMethod,
    pub redirect: Url,
    pub device_name: String,
    pub sender: oneshot::Sender<Result<Url, AttemptError>>,
}

impl BrowserUrlCall {
    pub fn reply(self, result: Result<Url, AttemptError>) {
        answer(self.sender, result);
    }
}

pub struct FinishCall {
    pub attempt: usize,
    pub callback: Url,
    pub sender: oneshot::Sender<Result<StoredSession, FinishError>>,
}

impl FinishCall {
    pub fn reply(self, result: Result<StoredSession, FinishError>) {
        answer(self.sender, result);
    }
}

pub struct CommitCall {
    pub attempt: usize,
    pub session: StoredSession,
    pub sender: oneshot::Sender<Result<Arc<dyn Account>, CommitError>>,
}

impl CommitCall {
    pub fn reply(self, result: Result<Arc<FakeAccount>, CommitError>) {
        answer(self.sender, result.map(|account| -> Arc<dyn Account> { account }));
    }
}

pub struct RestoreCall {
    pub session: StoredSession,
    pub passphrase: String,
    pub sender: oneshot::Sender<Result<Arc<dyn Account>, WontRestore>>,
}

impl RestoreCall {
    pub fn reply(self, result: Result<Arc<FakeAccount>, WontRestore>) {
        answer(self.sender, result.map(|account| -> Arc<dyn Account> { account }));
    }
}

pub struct LogoutCall {
    pub sender: oneshot::Sender<Result<(), LogoutError>>,
}

impl LogoutCall {
    pub fn reply(self, result: Result<(), LogoutError>) {
        answer(self.sender, result);
    }
}

/// The attempt an `Ok` probe reply starts; its calls go to the `FakeMatrix`.
struct FakeAttempt {
    id: usize,
    matrix: Arc<FakeMatrix>,
    // Set once a sign-in answered with a session, whose token a discard
    // must log out.
    signed_in: AtomicBool,
}

impl FakeAttempt {
    fn note_sign_in<E>(&self, result: &Result<StoredSession, E>) {
        if result.is_ok() {
            self.signed_in.store(true, Ordering::SeqCst);
        }
    }
}

#[async_trait]
impl Attempt for FakeAttempt {
    async fn sign_in_with_password(
        &self,
        user: &str,
        password: &str,
        device_name: &str,
    ) -> Result<StoredSession, PasswordError> {
        let result = self
            .matrix
            .passwords
            .ask(
                |sender| PasswordCall {
                    attempt: self.id,
                    user: user.to_owned(),
                    password: password.to_owned(),
                    device_name: device_name.to_owned(),
                    sender,
                },
                Err(PasswordError::Other),
            )
            .await;
        self.note_sign_in(&result);
        result
    }

    async fn browser_url(
        &self,
        method: &BrowserMethod,
        redirect: &Url,
        device_name: &str,
    ) -> Result<Url, AttemptError> {
        self.matrix
            .browser_urls
            .ask(
                |sender| BrowserUrlCall {
                    attempt: self.id,
                    method: method.clone(),
                    redirect: redirect.clone(),
                    device_name: device_name.to_owned(),
                    sender,
                },
                Err(AttemptError),
            )
            .await
    }

    async fn finish_browser(&self, callback: &Url) -> Result<StoredSession, FinishError> {
        let result = self
            .matrix
            .finishes
            .ask(
                |sender| FinishCall {
                    attempt: self.id,
                    callback: callback.clone(),
                    sender,
                },
                Err(FinishError::Other),
            )
            .await;
        self.note_sign_in(&result);
        result
    }

    async fn commit(self: Box<Self>, session: &StoredSession) -> Result<Arc<dyn Account>, CommitError> {
        let result = self
            .matrix
            .commit_calls
            .ask(
                |sender| CommitCall {
                    attempt: self.id,
                    session: session.clone(),
                    sender,
                },
                Err(CommitError),
            )
            .await;
        if result.is_ok() {
            self.matrix.commits.fetch_add(1, Ordering::SeqCst);
        }
        result
    }

    async fn discard(self: Box<Self>) {
        self.matrix.discarded.fetch_add(1, Ordering::SeqCst);
        if self.signed_in.load(Ordering::SeqCst) {
            self.matrix.discarded_logged_out.fetch_add(1, Ordering::SeqCst);
        }
    }
}

/// An account a commit or restore reply hands over. `send` reaches the
/// receiver `session_changes` gave out last; `logout` waits on the `FakeMatrix`.
pub struct FakeAccount {
    matrix: Arc<FakeMatrix>,
    listener: Mutex<Option<mpsc::UnboundedSender<SessionChange>>>,
}

impl FakeAccount {
    pub fn new(matrix: &Arc<FakeMatrix>) -> Arc<Self> {
        Arc::new(Self {
            matrix: Arc::clone(matrix),
            listener: Mutex::new(None),
        })
    }

    pub fn send(&self, change: SessionChange) {
        if let Some(listener) = lock(&self.listener).as_ref() {
            // A dropped receiver means nobody keeps the session any more.
            let _heard = listener.send(change);
        }
    }
}

#[async_trait]
impl Account for FakeAccount {
    fn session_changes(&self) -> mpsc::UnboundedReceiver<SessionChange> {
        let (sender, receiver) = mpsc::unbounded_channel();
        *lock(&self.listener) = Some(sender);
        receiver
    }

    async fn logout(&self) -> Result<(), LogoutError> {
        self.matrix
            .logouts
            .ask(|sender| LogoutCall { sender }, Err(LogoutError))
            .await
    }
}

/// An `AuthBrowser` with a fixed redirect whose `authenticate` waits until
/// the test answers it or `cancel` is called.
pub struct FakeAuthBrowser {
    redirect: Url,
    calls: Calls<AuthCall>,
    cancelled: Notify,
    fail_open: AtomicBool,
    reopens: AtomicUsize,
    cancels: AtomicUsize,
}

impl FakeAuthBrowser {
    pub fn new(redirect: Url) -> Arc<Self> {
        Arc::new(Self {
            redirect,
            calls: Calls::new(),
            cancelled: Notify::new(),
            fail_open: AtomicBool::new(false),
            reopens: AtomicUsize::new(0),
            cancels: AtomicUsize::new(0),
        })
    }

    pub async fn next_authenticate(&self) -> AuthCall {
        self.calls.next().await
    }

    /// Every `authenticate` from now on fails at once with `CouldntOpen`.
    pub fn fail_open(&self) {
        self.fail_open.store(true, Ordering::SeqCst);
    }

    pub fn reopens(&self) -> usize {
        self.reopens.load(Ordering::SeqCst)
    }

    pub fn cancels(&self) -> usize {
        self.cancels.load(Ordering::SeqCst)
    }
}

#[async_trait]
impl AuthBrowser for FakeAuthBrowser {
    async fn redirect_uri(&self) -> Result<Url, AuthBrowserError> {
        Ok(self.redirect.clone())
    }

    async fn authenticate(&self, url: Url) -> Result<Url, AuthBrowserError> {
        if self.fail_open.load(Ordering::SeqCst) {
            return Err(AuthBrowserError::CouldntOpen);
        }
        // Created before the call is queued, so a `cancel` made once the
        // test has seen the call always reaches it.
        let cancelled = self.cancelled.notified();
        let answered = self
            .calls
            .ask(|sender| AuthCall { url, sender }, Err(AuthBrowserError::Cancelled));
        tokio::select! {
            result = answered => result,
            () = cancelled => Err(AuthBrowserError::Cancelled),
        }
    }

    fn reopen(&self) {
        self.reopens.fetch_add(1, Ordering::SeqCst);
    }

    fn cancel(&self) {
        self.cancels.fetch_add(1, Ordering::SeqCst);
        self.cancelled.notify_waiters();
    }
}

pub struct AuthCall {
    pub url: Url,
    pub sender: oneshot::Sender<Result<Url, AuthBrowserError>>,
}

impl AuthCall {
    pub fn reply(self, result: Result<Url, AuthBrowserError>) {
        answer(self.sender, result);
    }
}

#[cfg(test)]
mod tests {
    use tokio::task::yield_now;

    use super::*;
    use crate::session::StoredAuth;

    #[tokio::test]
    async fn fake_secret_store_fails_on_command() {
        let store = FakeSecretStore::new();
        store.fail_next_set();
        assert!(store.set("k", "v").await.is_err());
        store.set("k", "v").await.unwrap();
        assert_eq!(store.value("k").as_deref(), Some("v"));
    }

    #[tokio::test(start_paused = true)]
    async fn fake_matrix_answers_when_told() {
        let fake = FakeMatrix::new();
        let matrix: Arc<dyn Matrix> = Arc::<FakeMatrix>::clone(&fake);
        let probing = tokio::spawn(async move { matrix.probe("a.b", "p").await });

        let call = fake.next_probe().await;
        assert_eq!(
            (call.attempt, call.server.as_str(), call.passphrase.as_str()),
            (0, "a.b", "p")
        );
        yield_now().await;
        assert!(!probing.is_finished());

        call.reply(Ok(FakeProbe::new(offer())));
        let probe = probing.await.unwrap().unwrap();
        assert_eq!(probe.offer, offer());
    }

    #[tokio::test(start_paused = true)]
    async fn attempts_route_their_calls_to_the_fake_matrix() {
        let fake = FakeMatrix::new();
        let first = found(&fake).await;
        let second = found(&fake).await;

        let signing_in = tokio::spawn(async move {
            let result = second.sign_in_with_password("alice", "hunter2", "Loaf").await;
            (second, result)
        });
        let call = fake.next_password().await;
        assert_eq!(
            (call.attempt, call.user.as_str(), call.password.as_str()),
            (1, "alice", "hunter2")
        );
        assert_eq!(call.device_name, "Loaf");
        call.reply(Ok(session()));
        let (signed_in_attempt, signed_in) = signing_in.await.unwrap();
        assert_eq!(signed_in, Ok(session()));

        first.discard().await;
        signed_in_attempt.discard().await;
        assert_eq!((fake.discarded(), fake.discarded_logged_out()), (2, 1));
    }

    #[tokio::test(start_paused = true)]
    async fn browser_sign_in_and_commit_reach_the_fake_matrix() {
        let fake = FakeMatrix::new();
        let attempt = found(&fake).await;
        let redirect = url("http://127.0.0.1:1/");
        let committing = tokio::spawn(async move {
            let page = attempt
                .browser_url(&BrowserMethod::OAuth, &redirect, "Loaf")
                .await
                .unwrap();
            let session = attempt.finish_browser(&page).await.unwrap();
            attempt.commit(&session).await.is_ok()
        });

        let url_call = fake.next_browser_url().await;
        assert_eq!(
            (url_call.attempt, &url_call.method, url_call.redirect.as_str()),
            (0, &BrowserMethod::OAuth, "http://127.0.0.1:1/")
        );
        assert_eq!(url_call.device_name, "Loaf");
        url_call.reply(Ok(url("https://idp.example/auth")));
        let finish = fake.next_finish().await;
        assert_eq!(
            (finish.attempt, finish.callback.as_str()),
            (0, "https://idp.example/auth")
        );
        finish.reply(Ok(session()));
        let commit = fake.next_commit().await;
        assert_eq!((commit.attempt, &commit.session), (0, &session()));
        commit.reply(Ok(FakeAccount::new(&fake)));

        assert!(committing.await.unwrap());
        assert_eq!(fake.commits(), 1);
    }

    #[tokio::test(start_paused = true)]
    async fn an_unanswered_call_fails() {
        let fake = FakeMatrix::new();
        let matrix = Arc::clone(&fake);
        let probing = tokio::spawn(async move { matrix.probe("a.b", "p").await });
        drop(fake.next_probe().await);
        assert_eq!(probing.await.unwrap().unwrap_err(), Unreachable);
    }

    #[tokio::test(start_paused = true)]
    async fn restored_accounts_send_changes_and_log_out_on_command() {
        let fake = FakeMatrix::new();
        let matrix = Arc::clone(&fake);
        let restoring = tokio::spawn(async move { matrix.restore(&session(), "p").await.is_ok() });
        let call = fake.next_restore().await;
        assert_eq!((&call.session, call.passphrase.as_str()), (&session(), "p"));
        let account = FakeAccount::new(&fake);
        call.reply(Ok(Arc::clone(&account)));
        assert!(restoring.await.unwrap());

        let mut changes = account.session_changes();
        account.send(SessionChange::Unrecoverable);
        assert_eq!(changes.recv().await, Some(SessionChange::Unrecoverable));

        let logging_out = tokio::spawn(async move { account.logout().await });
        fake.next_logout().await.reply(Err(LogoutError));
        assert_eq!(logging_out.await.unwrap(), Err(LogoutError));

        fake.wipe().await.unwrap();
        assert_eq!(fake.wipes(), 1);
    }

    #[tokio::test(start_paused = true)]
    async fn fake_auth_browser_answers_cancels_and_fails_to_open() {
        let browser = FakeAuthBrowser::new(url("http://127.0.0.1:1/"));
        assert_eq!(browser.redirect_uri().await, Ok(url("http://127.0.0.1:1/")));

        let shared = Arc::clone(&browser);
        let answered = tokio::spawn(async move { shared.authenticate(url("https://idp.example/")).await });
        let call = browser.next_authenticate().await;
        assert_eq!(call.url.as_str(), "https://idp.example/");
        call.reply(Ok(url("http://127.0.0.1:1/?code=c")));
        assert_eq!(answered.await.unwrap(), Ok(url("http://127.0.0.1:1/?code=c")));

        let shared_again = Arc::clone(&browser);
        let cancelled = tokio::spawn(async move { shared_again.authenticate(url("https://idp.example/")).await });
        let late = browser.next_authenticate().await;
        browser.reopen();
        browser.cancel();
        assert_eq!(cancelled.await.unwrap(), Err(AuthBrowserError::Cancelled));
        late.reply(Ok(url("http://127.0.0.1:1/?code=late")));
        assert_eq!((browser.reopens(), browser.cancels()), (1, 1));

        browser.fail_open();
        assert_eq!(
            browser.authenticate(url("https://idp.example/")).await,
            Err(AuthBrowserError::CouldntOpen)
        );
    }

    /// Probes through `fake` and answers that the server was found.
    async fn found(fake: &Arc<FakeMatrix>) -> Box<dyn Attempt> {
        let matrix = Arc::clone(fake);
        let probing = tokio::spawn(async move { matrix.probe("a.b", "p").await });
        fake.next_probe().await.reply(Ok(FakeProbe::new(offer())));
        probing.await.unwrap().unwrap().attempt
    }

    fn offer() -> ServerOffer {
        ServerOffer {
            oauth: true,
            sso: None,
            password: true,
        }
    }

    fn session() -> StoredSession {
        StoredSession {
            homeserver: url("https://a.b/"),
            user: String::from("@alice:a.b").into(),
            device: String::from("DEVICE").into(),
            auth: StoredAuth::Matrix {
                access_token: "token".into(),
                refresh_token: None,
            },
        }
    }

    fn url(text: &str) -> Url {
        Url::parse(text).unwrap()
    }
}
