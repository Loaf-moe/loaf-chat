//! The sign-in flow: discovering a server, signing in with a password,
//! and dropping answers gone stale.

use alloc::sync::Arc;
use core::time::Duration;
use std::sync::{Mutex, MutexGuard, PoisonError};

use eyeball::{SharedObservable, Subscriber};
use tokio::runtime::Handle;
use tokio::time::{Instant, interval, sleep_until};

use crate::ports::matrix::{Attempt, PasswordError, Probe, Unreachable};
use crate::session::keeping::{CommitClaim, Keeping};
use crate::session::server::{auth_methods, parse_server, user_id_server};
use crate::session::{AuthMethods, StoredSession};

/// The server a flow probes before the person types one.
const DEFAULT_SERVER: &str = "loaf.moe";
/// How long password sign-in is refused when a rate-limiting server names no time.
const DEFAULT_RETRY_AFTER: Duration = Duration::from_secs(30);
/// How often the rate-limit countdown moves.
const COUNTDOWN_TICK: Duration = Duration::from_secs(1);
/// How long typing must pause before a full user id re-points the server.
const REPOINT_QUIET: Duration = Duration::from_millis(400);

/// Everything a sign-in screen shows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SignInState {
    /// The server as typed, never the delegated base URL.
    pub server: String,
    pub check: ServerCheck,
    pub activity: Activity,
    /// The server refused the username and password.
    pub wrong_password: bool,
    /// Password sign-in is refused until this counts down to zero.
    pub retry_in: Option<Duration>,
    /// The server a full user id in the username field is being re-pointed to.
    pub repointing: Option<String>,
    pub failure: Option<SignInFailure>,
}

/// Where discovery of the server stands.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ServerCheck {
    Probing,
    Found(AuthMethods),
    CouldntReach,
}

/// What the flow is doing with the person's sign-in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Activity {
    Idle,
    InBrowser,
    CheckingPassword,
    SignedIn,
}

/// Why a sign-in failed, typed so a shell words it without parsing text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SignInFailure {
    CouldntReach,
    /// `message` is the server's own error text.
    Refused {
        message: String,
    },
    BrowserDidntOpen,
    /// The server refused the login token the provider sent back.
    ProviderDidntFinish {
        name: String,
    },
    /// Keeping the session failed.
    CouldntFinish,
}

impl SignInState {
    /// A fresh state while `server` is being discovered.
    fn probing(server: String) -> Self {
        Self {
            server,
            check: ServerCheck::Probing,
            activity: Activity::Idle,
            wrong_password: false,
            retry_in: None,
            repointing: None,
            failure: None,
        }
    }
}

/// One sign-in, from discovery to a kept session. Commands return at once
/// and their outcome lands in [`Self::state`]; dropping the flow drops
/// whatever it has in flight.
pub struct SignInFlow {
    /// Shared with the work this flow has spawned.
    shared: Arc<Shared>,
}

/// What a flow's commands and the work they spawn share. Spawned work holds
/// it too, so it outlives a dropped flow until that work has finished.
struct Shared {
    /// The Matrix port, the device name, the flow generation and the commit.
    keeping: Arc<Keeping>,
    /// Where spawned work and discards run.
    runtime: Handle,
    /// The generation this flow began in; it is inert once Keeping moves on.
    generation: u64,
    /// What the shell observes; written only under `inner`'s lock, so it
    /// changes in epoch order.
    state: SharedObservable<SignInState>,
    /// Never held across an `.await`.
    inner: Mutex<Inner>,
}

/// The flow's mutable core, behind `Shared::inner`.
struct Inner {
    /// Bumped by anything that makes earlier answers stale: a new probe, a
    /// password attempt, or dropping the flow.
    epoch: u64,
    /// The attempt the found server started, kept for the sign-in that
    /// follows. A password call takes it out while in flight.
    probe: Option<Pending>,
    /// Bumped by every username change, so only the latest one's quiet
    /// period may re-point the server.
    debounce: u64,
    /// A full user id naming another server is waiting out its quiet period.
    repoint_waiting: bool,
    /// A password submitted while a re-point was pending, sent once that
    /// server is found to take passwords.
    held: Option<Credentials>,
}

impl Inner {
    /// Cancels a pending re-point's quiet period and drops any held password.
    fn cancel_repoint(&mut self) {
        self.debounce = self.debounce.wrapping_add(1);
        self.repoint_waiting = false;
        self.held = None;
    }
}

/// A trimmed user and the password as typed. No `Debug`, so the password
/// can't reach a log.
struct Credentials {
    /// The username, trimmed.
    user: String,
    /// Never logged, never in [`SignInState`].
    password: String,
}

/// An attempt and the passphrase its pending store was opened under.
struct Pending {
    /// Signs in against the found server; discarded when not committed.
    attempt: Box<dyn Attempt>,
    /// Committing the attempt stores this beside the session.
    passphrase: String,
}

/// What a password answer leaves to do once the flow's lock is released.
#[expect(
    clippy::large_enum_variant,
    reason = "one lives briefly on the stack per password answer, so boxing the session saves nothing"
)]
enum AfterPassword<'keeping> {
    /// Nothing; the state already shows the outcome.
    Nothing,
    /// The answer went stale, or the flow no longer wants the attempt.
    Discard(Pending),
    /// Refused for a while; count `retry_in` down in this epoch.
    CountDown(u64),
    /// Tokens arrived for a current attempt: keep the session.
    Commit(CommitClaim<'keeping>, Pending, StoredSession),
}

impl SignInFlow {
    /// A flow in `generation` that starts probing the default server.
    pub(crate) fn begin(keeping: Arc<Keeping>, runtime: Handle, generation: u64) -> Self {
        let shared = Arc::new(Shared {
            keeping,
            runtime,
            generation,
            state: SharedObservable::new(SignInState::probing(DEFAULT_SERVER.to_owned())),
            inner: Mutex::new(Inner {
                epoch: 0,
                probe: None,
                debounce: 0,
                repoint_waiting: false,
                held: None,
            }),
        });
        Shared::start_probe(&shared, |_| Some(DEFAULT_SERVER.to_owned()));
        Self { shared }
    }

    /// A subscriber whose first `next()` yields the current state at once;
    /// each later `next()` waits for a change.
    pub fn state(&self) -> Subscriber<SignInState> {
        self.shared.state.subscribe_reset()
    }

    /// Probes the server named by `input`: a server name, a URL or a full
    /// user id. Any call cancels a re-point from the username field, since the
    /// server field has the last word. Half-typed input, or the server already
    /// chosen with no re-point in flight, probes nothing.
    pub fn set_server(&self, input: &str) {
        self.shared.cancel_repoint();
        let Some(server) = parse_server(input) else {
            return;
        };
        // A re-point in flight already let the chosen server's attempt go.
        Shared::start_probe(&self.shared, |current| {
            (current.server != server || current.repointing.is_some()).then_some(server)
        });
    }

    /// Probes the current server again.
    pub fn retry(&self) {
        Shared::start_probe(&self.shared, |current| Some(current.server.clone()));
    }

    /// Signs in on the found server with the trimmed `user` and `password`
    /// as typed. Does nothing unless the flow is idle, the server takes
    /// passwords, no rate limit is counting down and both fields are filled.
    pub fn sign_in_with_password(&self, user: &str, password: &str) {
        let trimmed = user.trim();
        if trimmed.is_empty() || password.is_empty() {
            return;
        }
        Shared::start_password(&self.shared, trimmed.to_owned(), password.to_owned());
    }

    /// Re-points the flow to the server a full user id in the username field
    /// names, once typing pauses for [`REPOINT_QUIET`], if that server differs
    /// and the flow is idle. Any other text cancels a pending re-point.
    pub fn username_changed(&self, text: &str) {
        Shared::schedule_repoint(&self.shared, text);
    }
}

impl Drop for SignInFlow {
    /// Work still in flight sees the bumped epoch when it answers and
    /// discards what it got; the attempt already held is discarded here.
    fn drop(&mut self) {
        let held = {
            let mut inner = self.shared.lock();
            inner.epoch = inner.epoch.wrapping_add(1);
            inner.cancel_repoint();
            inner.probe.take()
        };
        self.shared.discard_later(held);
    }
}

impl Shared {
    /// The flow's mutable core. A poisoned lock only means a panic elsewhere;
    /// every write under it is a plain assignment, so the fields stay consistent.
    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Whether no newer flow has begun since this one.
    fn is_current_flow(&self) -> bool {
        self.keeping.is_current_flow(self.generation)
    }

    /// Whether work started at `epoch` may still change the flow.
    fn is_current(&self, inner: &Inner, epoch: u64) -> bool {
        inner.epoch == epoch && self.is_current_flow()
    }

    /// Probes the server `choose` picks from the current state, if it picks
    /// one, in a new epoch that replaces the attempt held so far. Probing the
    /// same server again keeps a running rate-limit countdown; only a server
    /// change clears it.
    fn start_probe(self: &Arc<Self>, choose: impl FnOnce(&SignInState) -> Option<String>) {
        let (server, epoch, replaced, counting) = {
            let mut inner = self.lock();
            let current = self.state.get();
            // Past the point of no return, the session is being kept.
            if !self.is_current_flow() || current.activity == Activity::SignedIn {
                return;
            }
            let Some(server) = choose(&current) else {
                return;
            };
            let retry_in = current.retry_in.filter(|_| current.server == server);
            let next = SignInState {
                retry_in,
                ..SignInState::probing(server.clone())
            };
            let (epoch, replaced) = self.enter_probe(&mut inner, next);
            (server, epoch, replaced, retry_in.is_some())
        };
        self.discard_later(replaced);
        if counting {
            self.start_countdown(epoch);
        }
        self.spawn_probe(server, epoch);
    }

    /// Starts a new epoch showing `next`, which is probing its server, and
    /// hands back the epoch and the attempt it replaces. Call with the lock held.
    fn enter_probe(&self, inner: &mut Inner, next: SignInState) -> (u64, Option<Pending>) {
        inner.epoch = inner.epoch.wrapping_add(1);
        inner.cancel_repoint();
        self.state.update(|state| *state = next);
        (inner.epoch, inner.probe.take())
    }

    /// Probes `server` for work started at `epoch`, with a fresh passphrase.
    fn spawn_probe(self: &Arc<Self>, server: String, epoch: u64) {
        let passphrase = new_passphrase();
        let shared = Arc::clone(self);
        self.runtime.spawn(async move {
            let answer = shared.keeping.matrix().probe(&server, &passphrase).await;
            shared.apply_probe(epoch, answer, passphrase).await;
        });
    }

    /// Publishes a probe's answer if `epoch` is still current; otherwise
    /// discards the attempt it started. A re-point's answer moves the flow to
    /// the re-pointed server either way, since the person typed that id, and
    /// settles a held password: sent when the server takes passwords,
    /// dropped when it doesn't or couldn't be reached.
    async fn apply_probe(self: &Arc<Self>, epoch: u64, answer: Result<Probe, Unreachable>, passphrase: String) {
        let (unwanted, send) = {
            let mut inner = self.lock();
            if self.is_current(&inner, epoch) {
                // A held password waits through a newer re-point still waiting
                // out its quiet period, so it reaches the server last typed.
                let held = if inner.repoint_waiting { None } else { inner.held.take() };
                let found = answer
                    .ok()
                    .map(|Probe { offer, attempt }| (auth_methods(&offer), attempt));
                let takes_passwords = found.as_ref().is_some_and(|(methods, _)| methods.password);
                let dropping_held = held.is_some() && !takes_passwords;
                let check = found.as_ref().map_or(ServerCheck::CouldntReach, |(methods, _)| {
                    ServerCheck::Found(methods.clone())
                });
                self.state.update(|state| {
                    if let Some(server) = state.repointing.take() {
                        state.server = server;
                    }
                    state.check = check;
                    if dropping_held {
                        state.activity = Activity::Idle;
                    }
                });
                let unwanted = found.and_then(|(_, attempt)| inner.probe.replace(Pending { attempt, passphrase }));
                let send = held
                    .filter(|_| takes_passwords)
                    .and_then(|credentials| Some((inner.probe.take()?, credentials)))
                    .map(|(pending, credentials)| (pending, self.enter_password(&mut inner), credentials));
                (unwanted, send)
            } else {
                let unwanted = answer.ok().map(|probe| Pending {
                    attempt: probe.attempt,
                    passphrase,
                });
                (unwanted, None)
            }
        };
        if let Some((pending, password_epoch, credentials)) = send {
            self.spawn_password(pending, password_epoch, credentials);
        }
        if let Some(pending) = unwanted {
            pending.attempt.discard().await;
        }
    }

    /// Sends `user` and `password` through the held attempt in a new epoch,
    /// if the state allows a password sign-in now. They are held for a
    /// re-pointed server instead while a re-point is pending or in flight,
    /// and when `user` is a full id naming another server, which re-points
    /// at once. So the password only reaches the server its own user id names.
    fn start_password(self: &Arc<Self>, user: String, password: String) {
        let named = user_id_server(&user);
        let credentials = Credentials { user, password };
        let (pending, epoch) = {
            let mut inner = self.lock();
            let current = self.state.get();
            if !self.is_current_flow() || current.activity != Activity::Idle {
                return;
            }
            let target = current.repointing.as_ref().unwrap_or(&current.server);
            let repoint_now = named.filter(|server| server != target);
            // The re-pointed server's own offer and rate limit decide once it is found.
            if repoint_now.is_some() || inner.repoint_waiting || current.repointing.is_some() {
                inner.held = Some(credentials);
                self.show_checking_password();
                let Some(server) = repoint_now else {
                    return;
                };
                // The password's own user id outranks a re-point still waiting.
                inner.debounce = inner.debounce.wrapping_add(1);
                inner.repoint_waiting = false;
                let (repoint_epoch, replaced) = self.enter_repoint(&mut inner, &server);
                drop(inner);
                self.discard_later(replaced);
                self.spawn_probe(server, repoint_epoch);
                return;
            }
            let takes_passwords = matches!(&current.check, ServerCheck::Found(methods) if methods.password);
            if !takes_passwords || current.retry_in.is_some() {
                return;
            }
            // The attempt is needed by value across the call; a server change
            // meanwhile finds none held and simply probes.
            let Some(pending) = inner.probe.take() else {
                return;
            };
            (pending, self.enter_password(&mut inner))
        };
        self.spawn_password(pending, epoch, credentials);
    }

    /// Cancels a pending re-point's quiet period and lets any held password
    /// go, back to idle.
    fn cancel_repoint(&self) {
        let mut inner = self.lock();
        if inner.held.is_some() {
            self.state.update(|state| state.activity = Activity::Idle);
        }
        inner.cancel_repoint();
    }

    /// Starts the epoch a re-point probe of `server` runs in, keeping the
    /// form up, and hands back the attempt it replaces. The old server's
    /// countdown and refusals don't apply to the new one. Call with the lock held.
    fn enter_repoint(&self, inner: &mut Inner, server: &str) -> (u64, Option<Pending>) {
        inner.epoch = inner.epoch.wrapping_add(1);
        self.state.update(|state| {
            state.repointing = Some(server.to_owned());
            state.retry_in = None;
            state.wrong_password = false;
            state.failure = None;
        });
        (inner.epoch, inner.probe.take())
    }

    /// Starts the epoch a password call runs in and shows it checking.
    /// Call with the lock held.
    fn enter_password(&self, inner: &mut Inner) -> u64 {
        inner.epoch = inner.epoch.wrapping_add(1);
        self.show_checking_password();
        inner.epoch
    }

    /// Shows a password sign-in under way, clearing the last one's outcome.
    /// Call with the lock held.
    fn show_checking_password(&self) {
        self.state.update(|state| {
            state.activity = Activity::CheckingPassword;
            state.failure = None;
            state.wrong_password = false;
        });
    }

    /// Sends `credentials` through `pending`'s attempt for work started at `epoch`.
    fn spawn_password(self: &Arc<Self>, pending: Pending, epoch: u64, credentials: Credentials) {
        let shared = Arc::clone(self);
        self.runtime.spawn(async move {
            let answer = pending
                .attempt
                .sign_in_with_password(&credentials.user, &credentials.password, shared.keeping.device_name())
                .await;
            shared.apply_password(epoch, pending, answer).await;
        });
    }

    /// Restarts the quiet period before re-pointing to the server a full user
    /// id in the username field `text` names. Other text, or the server the
    /// flow is already on or heading to, only cancels a pending re-point.
    fn schedule_repoint(self: &Arc<Self>, text: &str) {
        let (debounce, server) = {
            let mut inner = self.lock();
            let current = self.state.get();
            if !self.is_current_flow() || current.activity == Activity::SignedIn {
                return;
            }
            // The username a held password was submitted with, sent again, changes nothing.
            if inner.held.as_ref().is_some_and(|held| held.user == text.trim()) {
                return;
            }
            // A held password belongs to the username it was submitted with.
            if inner.held.take().is_some() {
                self.state.update(|state| state.activity = Activity::Idle);
            }
            inner.debounce = inner.debounce.wrapping_add(1);
            let target = current.repointing.as_ref().unwrap_or(&current.server);
            let Some(server) = user_id_server(text).filter(|server| server != target) else {
                inner.repoint_waiting = false;
                return;
            };
            inner.repoint_waiting = true;
            (inner.debounce, server)
        };
        // Measured from the keystroke, so paused-clock tests are exact.
        let Some(deadline) = Instant::now().checked_add(REPOINT_QUIET) else {
            return;
        };
        let shared = Arc::clone(self);
        self.runtime.spawn(async move {
            sleep_until(deadline).await;
            shared.repoint(debounce, server);
        });
    }

    /// Probes `server` for the re-point whose quiet period `debounce` ended,
    /// if no later username change, server change or drop has cancelled it
    /// and the flow is idle or holding a password for it. The form stays up
    /// while `repointing` names the server being probed.
    fn repoint(self: &Arc<Self>, debounce: u64, server: String) {
        let (epoch, replaced) = {
            let mut inner = self.lock();
            if inner.debounce != debounce || !self.is_current_flow() {
                return;
            }
            inner.repoint_waiting = false;
            let current = self.state.get();
            let holding = inner.held.is_some();
            if current.activity != Activity::Idle && !holding {
                return;
            }
            if current.repointing.as_ref().unwrap_or(&current.server) == &server {
                // Nothing will be probed, so a held password would wait forever.
                if inner.held.take().is_some() {
                    self.state.update(|state| state.activity = Activity::Idle);
                }
                return;
            }
            self.enter_repoint(&mut inner, &server)
        };
        self.discard_later(replaced);
        self.spawn_probe(server, epoch);
    }

    /// Applies a password answer from `epoch`: commits the session when
    /// tokens arrived for a current attempt, shows a refusal and holds the
    /// attempt again, or discards it when the answer went stale.
    async fn apply_password(
        self: &Arc<Self>,
        epoch: u64,
        pending: Pending,
        answer: Result<StoredSession, PasswordError>,
    ) {
        let after = {
            let mut inner = self.lock();
            if inner.epoch == epoch {
                match answer {
                    // The claim is decided under Keeping's lock, atomically
                    // with `begin_sign_in`, so a newer flow and this commit
                    // never both proceed.
                    Ok(session) => match self.keeping.claim_commit(self.generation) {
                        Some(claim) => {
                            self.state.update(|state| state.activity = Activity::SignedIn);
                            AfterPassword::Commit(claim, pending, session)
                        }
                        None => AfterPassword::Discard(pending),
                    },
                    Err(error) if self.is_current_flow() => {
                        let rate_limited = self.show_refusal(error);
                        match inner.probe.replace(pending) {
                            Some(unwanted) => AfterPassword::Discard(unwanted),
                            None if rate_limited => AfterPassword::CountDown(epoch),
                            None => AfterPassword::Nothing,
                        }
                    }
                    Err(_) => AfterPassword::Discard(pending),
                }
            } else {
                AfterPassword::Discard(pending)
            }
        };
        match after {
            AfterPassword::Nothing => {}
            AfterPassword::Discard(unwanted) => unwanted.attempt.discard().await,
            AfterPassword::CountDown(counting) => self.start_countdown(counting),
            AfterPassword::Commit(claim, kept, session) => {
                let committed = self.keeping.commit(claim, kept.attempt, session, kept.passphrase).await;
                if committed.is_err() {
                    self.reprobe_after_failed_commit(epoch);
                }
            }
        }
    }

    /// Brings the controls back after keeping the session failed: shows
    /// `CouldntFinish` and probes the current server again, since the failed
    /// commit used up the attempt. Only a drop moves the epoch past `epoch`
    /// while signed in, and a dropped flow needs neither.
    fn reprobe_after_failed_commit(self: &Arc<Self>, epoch: u64) {
        let (server, probe_epoch, replaced) = {
            let mut inner = self.lock();
            if !self.is_current(&inner, epoch) {
                return;
            }
            let server = self.state.get().server;
            let next = SignInState {
                failure: Some(SignInFailure::CouldntFinish),
                ..SignInState::probing(server.clone())
            };
            let (probe_epoch, replaced) = self.enter_probe(&mut inner, next);
            (server, probe_epoch, replaced)
        };
        self.discard_later(replaced);
        self.spawn_probe(server, probe_epoch);
    }

    /// Shows why the server refused a password sign-in and returns to idle.
    /// Returns whether it is rate limiting. Call with the lock held.
    fn show_refusal(&self, error: PasswordError) -> bool {
        let rate_limited = matches!(error, PasswordError::RateLimited { retry_after: _ });
        self.state.update(|state| {
            state.activity = Activity::Idle;
            match error {
                PasswordError::Forbidden => state.wrong_password = true,
                PasswordError::RateLimited { retry_after } => state.retry_in = Some(retry_wait(retry_after)),
                PasswordError::Refused { message } => state.failure = Some(SignInFailure::Refused { message }),
                PasswordError::Other => state.failure = Some(SignInFailure::CouldntReach),
            }
        });
        rate_limited
    }

    /// Counts `retry_in` down a second at a time until it reaches zero.
    /// Anything that bumps the epoch, such as a server change or dropping
    /// the flow, stops it at the next tick.
    fn start_countdown(self: &Arc<Self>, epoch: u64) {
        let shared = Arc::clone(self);
        self.runtime.spawn(async move {
            // Fixed deadlines, so a late wake-up catches up instead of drifting.
            let mut ticks = interval(COUNTDOWN_TICK);
            // The first tick completes at once; the countdown moves a tick later.
            ticks.tick().await;
            loop {
                ticks.tick().await;
                let finished = {
                    let inner = shared.lock();
                    if !shared.is_current(&inner, epoch) {
                        return;
                    }
                    let mut finished = false;
                    shared.state.update(|state| {
                        state.retry_in = state
                            .retry_in
                            .map(|left| left.saturating_sub(COUNTDOWN_TICK))
                            .filter(|left| !left.is_zero());
                        finished = state.retry_in.is_none();
                    });
                    finished
                };
                if finished {
                    return;
                }
            }
        });
    }

    /// Discards `unwanted` on the runtime, for callers that can't await.
    fn discard_later(&self, unwanted: Option<Pending>) {
        if let Some(pending) = unwanted {
            self.runtime.spawn(pending.attempt.discard());
        }
    }
}

/// How long to refuse password sign-in: `retry_after` rounded up to whole
/// seconds and at least one, or [`DEFAULT_RETRY_AFTER`] when the server names none.
fn retry_wait(retry_after: Option<Duration>) -> Duration {
    retry_after.map_or(DEFAULT_RETRY_AFTER, |after| {
        let whole = after.as_secs().saturating_add(u64::from(after.subsec_nanos() > 0));
        Duration::from_secs(whole.max(1))
    })
}

/// A fresh store passphrase: 32 random bytes, hex-encoded.
fn new_passphrase() -> String {
    let [high, low]: [u128; 2] = rand::random();
    format!("{high:032x}{low:032x}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::{Core, CoreConfig, Platform};
    use crate::fakes::{
        CommitCall, FakeAccount, FakeAuthBrowser, FakeMatrix, FakeProbe, FakeSecretStore, PasswordCall, ProbeCall,
    };
    use crate::ports::matrix::{CommitError, IdentityProvider, PasswordError, ServerOffer};
    use crate::ports::secret_store::SecretStore as _;
    use crate::session::stored::{PASSPHRASE_KEY, SESSION_KEY, StoredAuth};
    use crate::session::{DeviceId, NotSignedOut, SessionState, StoredSession, UserId};
    use std::path::PathBuf;
    use tokio::task::yield_now;
    use tokio::time::{advance, sleep, timeout};
    use url::Url;

    fn config(secrets: Arc<FakeSecretStore>) -> CoreConfig {
        CoreConfig {
            data_dir: PathBuf::from("data"),
            device_name: "Test".into(),
            platform: Platform {
                secrets,
                auth_browser: FakeAuthBrowser::new(Url::parse("http://127.0.0.1:1/").unwrap()),
            },
        }
    }

    /// A core with nothing stored, so it starts signed out.
    async fn signed_out_core() -> (Arc<Core>, Arc<FakeMatrix>) {
        let fake = FakeMatrix::new();
        let core = Core::start_with(
            config(Arc::new(FakeSecretStore::new())),
            Arc::<FakeMatrix>::clone(&fake),
        )
        .await;
        (core, fake)
    }

    fn offer() -> ServerOffer {
        ServerOffer {
            oauth: false,
            sso: Some(vec![IdentityProvider {
                id: "kanidm".into(),
                name: Some("Kanidm".into()),
            }]),
            password: true,
        }
    }

    fn probing(server: &str) -> SignInState {
        SignInState::probing(server.to_owned())
    }

    /// The next state change, failing rather than hanging when none comes.
    async fn next_change(state: &mut Subscriber<SignInState>) -> SignInState {
        timeout(Duration::from_secs(5), state.next()).await.unwrap().unwrap()
    }

    /// The next probe call, failing rather than hanging when none comes.
    async fn next_probe(fake: &FakeMatrix) -> ProbeCall {
        timeout(Duration::from_secs(5), fake.next_probe()).await.unwrap()
    }

    /// Waits for `done`, sleeping so paused time can run out instead of hanging.
    async fn until(done: impl Fn() -> bool) {
        timeout(Duration::from_secs(5), async {
            while !done() {
                sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
    }

    #[tokio::test(start_paused = true)]
    async fn opens_probing_loaf_moe() {
        let (core, fake) = signed_out_core().await;
        let flow = core.session().begin_sign_in().unwrap();
        let probe = next_probe(&fake).await;
        assert_eq!(probe.server, "loaf.moe");
        assert_eq!(probe.passphrase.len(), 64);
        assert!(probe.passphrase.bytes().all(|byte| byte.is_ascii_hexdigit()));
        assert_eq!(flow.state().get(), probing("loaf.moe"));
    }

    #[tokio::test(start_paused = true)]
    async fn each_probe_gets_its_own_passphrase() {
        let (core, fake) = signed_out_core().await;
        let flow = core.session().begin_sign_in().unwrap();
        let first = next_probe(&fake).await;
        flow.set_server("example.org");
        let second = next_probe(&fake).await;
        assert_ne!(first.passphrase, second.passphrase);
    }

    #[tokio::test(start_paused = true)]
    async fn found_server_publishes_methods() {
        let (core, fake) = signed_out_core().await;
        let flow = core.session().begin_sign_in().unwrap();
        let mut state = flow.state();
        assert_eq!(next_change(&mut state).await, probing("loaf.moe"));
        next_probe(&fake).await.reply(Ok(FakeProbe::new(offer())));
        let found = next_change(&mut state).await;
        assert_eq!(found.check, ServerCheck::Found(auth_methods(&offer())));
        assert_eq!(found.server, "loaf.moe");
        assert_eq!(fake.discarded(), 0);
    }

    #[tokio::test(start_paused = true)]
    async fn unreachable_is_couldnt_reach_and_retry_probes_again() {
        let (core, fake) = signed_out_core().await;
        let flow = core.session().begin_sign_in().unwrap();
        let mut state = flow.state();
        assert_eq!(next_change(&mut state).await, probing("loaf.moe"));
        next_probe(&fake).await.reply(Err(Unreachable));
        assert_eq!(next_change(&mut state).await.check, ServerCheck::CouldntReach);

        flow.retry();
        assert_eq!(next_probe(&fake).await.server, "loaf.moe");
        assert_eq!(flow.state().get(), probing("loaf.moe"));
    }

    #[tokio::test(start_paused = true)]
    async fn retry_discards_the_found_attempt() {
        let (core, fake) = signed_out_core().await;
        let flow = core.session().begin_sign_in().unwrap();
        let mut state = flow.state();
        assert_eq!(next_change(&mut state).await, probing("loaf.moe"));
        next_probe(&fake).await.reply(Ok(FakeProbe::new(offer())));
        next_change(&mut state).await;

        flow.retry();
        assert_eq!(flow.state().get(), probing("loaf.moe"));
        let again = next_probe(&fake).await;
        until(|| fake.discarded() == 1).await;
        again.reply(Ok(FakeProbe::new(offer())));
        until(|| matches!(flow.state().get().check, ServerCheck::Found(_))).await;
        assert_eq!(fake.discarded(), 1);
    }

    #[tokio::test(start_paused = true)]
    async fn half_typed_server_is_ignored() {
        let (core, fake) = signed_out_core().await;
        let flow = core.session().begin_sign_in().unwrap();
        // Held unanswered, so the opening probe stays in flight.
        let _opening = next_probe(&fake).await;
        flow.set_server("loa");
        assert!(timeout(Duration::from_secs(1), fake.next_probe()).await.is_err());
        assert_eq!(flow.state().get(), probing("loaf.moe"));
    }

    #[tokio::test(start_paused = true)]
    async fn answer_to_old_probe_is_dropped() {
        let (core, fake) = signed_out_core().await;
        let flow = core.session().begin_sign_in().unwrap();
        let _opening = next_probe(&fake).await;
        flow.set_server("a.org");
        flow.set_server("b.org");
        let first = next_probe(&fake).await;
        assert_eq!(first.server, "a.org");
        let second = next_probe(&fake).await;
        assert_eq!(second.server, "b.org");

        first.reply(Ok(FakeProbe::new(offer())));
        until(|| fake.discarded() == 1).await;
        assert_eq!(flow.state().get(), probing("b.org"));
        assert!(!second.sender.is_closed());
    }

    #[tokio::test(start_paused = true)]
    async fn second_begin_makes_first_inert() {
        let (core, fake) = signed_out_core().await;
        let first_flow = core.session().begin_sign_in().unwrap();
        let first = next_probe(&fake).await;
        let second_flow = core.session().begin_sign_in().unwrap();
        let second = next_probe(&fake).await;

        first.reply(Ok(FakeProbe::new(offer())));
        until(|| fake.discarded() == 1).await;
        assert_eq!(first_flow.state().get(), probing("loaf.moe"));

        second.reply(Ok(FakeProbe::new(offer())));
        until(|| matches!(second_flow.state().get().check, ServerCheck::Found(_))).await;
        assert_eq!(fake.discarded(), 1);
    }

    #[tokio::test(start_paused = true)]
    async fn inert_flow_ignores_commands() {
        let (core, fake) = signed_out_core().await;
        let first_flow = core.session().begin_sign_in().unwrap();
        let _first = next_probe(&fake).await;
        let _second_flow = core.session().begin_sign_in().unwrap();
        let _second = next_probe(&fake).await;

        first_flow.set_server("a.org");
        first_flow.retry();
        assert!(timeout(Duration::from_secs(1), fake.next_probe()).await.is_err());
    }

    #[tokio::test(start_paused = true)]
    async fn dropped_flow_discards_its_attempts() {
        let (core, fake) = signed_out_core().await;
        let flow = core.session().begin_sign_in().unwrap();
        next_probe(&fake).await.reply(Ok(FakeProbe::new(offer())));
        until(|| matches!(flow.state().get().check, ServerCheck::Found(_))).await;
        flow.set_server("a.org");
        let late = next_probe(&fake).await;
        until(|| fake.discarded() == 1).await;

        drop(flow);
        late.reply(Ok(FakeProbe::new(offer())));
        until(|| fake.discarded() == 2).await;
    }

    #[tokio::test(start_paused = true)]
    async fn dropped_flow_discards_the_attempt_it_holds() {
        let (core, fake) = signed_out_core().await;
        let flow = core.session().begin_sign_in().unwrap();
        next_probe(&fake).await.reply(Ok(FakeProbe::new(offer())));
        until(|| matches!(flow.state().get().check, ServerCheck::Found(_))).await;
        drop(flow);
        until(|| fake.discarded() == 1).await;
    }

    #[tokio::test(start_paused = true)]
    async fn begin_while_signed_in_is_refused() {
        let stored = StoredSession {
            homeserver: Url::parse("https://matrix.example.org").unwrap(),
            user: UserId::from("@alice:example.org".to_owned()),
            device: DeviceId::from("DEVICE1".to_owned()),
            auth: StoredAuth::Matrix {
                access_token: "syt_access_secret".into(),
                refresh_token: None,
            },
        };
        let secrets = Arc::new(FakeSecretStore::new());
        secrets.set(SESSION_KEY, &stored.to_secret()).await.unwrap();
        secrets.set(PASSPHRASE_KEY, "pass").await.unwrap();
        let fake = FakeMatrix::new();
        let start = tokio::spawn({
            let fake_for_task = Arc::clone(&fake);
            async move { Core::start_with(config(secrets), fake_for_task).await }
        });
        fake.next_restore().await.reply(Ok(FakeAccount::new(&fake)));
        let core = start.await.unwrap();

        assert!(matches!(core.session().begin_sign_in(), Err(NotSignedOut)));
        assert!(timeout(Duration::from_secs(1), fake.next_probe()).await.is_err());
    }

    /// A flow whose opening probe found `loaf.moe` taking passwords.
    struct Found {
        core: Arc<Core>,
        fake: Arc<FakeMatrix>,
        secrets: Arc<FakeSecretStore>,
        flow: SignInFlow,
        /// The passphrase the found attempt's store was opened under.
        passphrase: String,
    }

    async fn found_flow() -> Found {
        let secrets = Arc::new(FakeSecretStore::new());
        let fake = FakeMatrix::new();
        let core = Core::start_with(config(Arc::clone(&secrets)), Arc::<FakeMatrix>::clone(&fake)).await;
        let flow = core.session().begin_sign_in().unwrap();
        let probe = next_probe(&fake).await;
        let passphrase = probe.passphrase.clone();
        probe.reply(Ok(FakeProbe::new(offer())));
        until(|| matches!(flow.state().get().check, ServerCheck::Found(_))).await;
        Found {
            core,
            fake,
            secrets,
            flow,
            passphrase,
        }
    }

    fn bob() -> StoredSession {
        StoredSession {
            homeserver: Url::parse("https://matrix.loaf.moe").unwrap(),
            user: UserId::from("@bob:loaf.moe".to_owned()),
            device: DeviceId::from("BOBDEVICE".to_owned()),
            auth: StoredAuth::Matrix {
                access_token: "syt_bob_access".into(),
                refresh_token: Some("syt_bob_refresh".into()),
            },
        }
    }

    async fn next_password(fake: &FakeMatrix) -> PasswordCall {
        timeout(Duration::from_secs(5), fake.next_password()).await.unwrap()
    }

    async fn next_commit(fake: &FakeMatrix) -> CommitCall {
        timeout(Duration::from_secs(5), fake.next_commit()).await.unwrap()
    }

    /// Whether a password call arrives within a second.
    async fn password_called(fake: &FakeMatrix) -> bool {
        timeout(Duration::from_secs(1), fake.next_password()).await.is_ok()
    }

    /// Lets spawned work run without moving the paused clock.
    async fn settle() {
        /// Enough yields for a reply to cross the fake and the flow's task.
        const ROUNDS: u8 = 20;
        for _ in 0..ROUNDS {
            yield_now().await;
        }
    }

    fn no_secrets(secrets: &FakeSecretStore) -> bool {
        secrets.value(SESSION_KEY).is_none() && secrets.value(PASSPHRASE_KEY).is_none()
    }

    /// Signs in on `found` and answers the password call with `answer`.
    async fn answer_password(found: &Found, answer: Result<StoredSession, PasswordError>) {
        found.flow.sign_in_with_password("bob", "pw");
        next_password(&found.fake).await.reply(answer);
    }

    #[tokio::test(start_paused = true)]
    async fn right_credentials_sign_in() {
        let found = found_flow().await;
        found.flow.sign_in_with_password("  bob  ", " pw ");
        assert_eq!(found.flow.state().get().activity, Activity::CheckingPassword);
        let call = next_password(&found.fake).await;
        assert_eq!(call.attempt, 0);
        assert_eq!(
            (call.user.as_str(), call.password.as_str(), call.device_name.as_str()),
            ("bob", " pw ", "Test")
        );
        call.reply(Ok(bob()));

        let commit = next_commit(&found.fake).await;
        assert_eq!(commit.session, bob());
        assert_eq!(found.flow.state().get().activity, Activity::SignedIn);
        assert_eq!(found.core.session().state().get(), SessionState::SignedOut);
        commit.reply(Ok(FakeAccount::new(&found.fake)));

        let signed_in = SessionState::SignedIn {
            user: bob().user,
            device: bob().device,
        };
        until(|| found.core.session().state().get() == signed_in).await;
        assert_eq!(found.flow.state().get().activity, Activity::SignedIn);
        assert_eq!(found.secrets.value(SESSION_KEY), Some(bob().to_secret()));
        assert_eq!(found.secrets.value(PASSPHRASE_KEY), Some(found.passphrase.clone()));
        assert_eq!((found.fake.commits(), found.fake.discarded()), (1, 0));
    }

    #[tokio::test(start_paused = true)]
    async fn empty_fields_do_nothing() {
        let found = found_flow().await;
        found.flow.sign_in_with_password("  ", "pw");
        found.flow.sign_in_with_password("bob", "");
        assert_eq!(found.flow.state().get().activity, Activity::Idle);
        assert!(!password_called(&found.fake).await);
    }

    #[tokio::test(start_paused = true)]
    async fn sign_in_before_the_server_is_found_does_nothing() {
        let (core, fake) = signed_out_core().await;
        let flow = core.session().begin_sign_in().unwrap();
        let _opening = next_probe(&fake).await;
        flow.sign_in_with_password("bob", "pw");
        assert_eq!(flow.state().get(), probing("loaf.moe"));
        assert!(!password_called(&fake).await);
    }

    #[tokio::test(start_paused = true)]
    async fn second_sign_in_while_checking_does_nothing() {
        let found = found_flow().await;
        found.flow.sign_in_with_password("bob", "pw");
        let _first = next_password(&found.fake).await;
        found.flow.sign_in_with_password("bob", "pw2");
        assert!(!password_called(&found.fake).await);
    }

    #[tokio::test(start_paused = true)]
    async fn forbidden_sets_wrong_password() {
        let found = found_flow().await;
        answer_password(&found, Err(PasswordError::Forbidden)).await;
        until(|| found.flow.state().get().wrong_password).await;
        let state = found.flow.state().get();
        assert_eq!((state.activity, state.failure), (Activity::Idle, None));

        // The attempt is held again, so the next try reaches the same server.
        found.flow.sign_in_with_password("bob", "pw");
        assert_eq!(next_password(&found.fake).await.attempt, 0);
        assert_eq!(found.fake.discarded(), 0);
    }

    #[tokio::test(start_paused = true)]
    async fn rate_limit_counts_down() {
        let found = found_flow().await;
        answer_password(
            &found,
            Err(PasswordError::RateLimited {
                retry_after: Some(Duration::from_millis(2300)),
            }),
        )
        .await;
        until(|| found.flow.state().get().retry_in.is_some()).await;
        let state = found.flow.state().get();
        assert_eq!(
            (state.retry_in, state.activity),
            (Some(Duration::from_secs(3)), Activity::Idle)
        );

        advance(Duration::from_secs(1)).await;
        settle().await;
        assert_eq!(found.flow.state().get().retry_in, Some(Duration::from_secs(2)));
        found.flow.sign_in_with_password("bob", "pw");
        assert_eq!(found.flow.state().get().activity, Activity::Idle);

        advance(Duration::from_secs(2)).await;
        settle().await;
        assert_eq!(found.flow.state().get().retry_in, None);
        found.flow.sign_in_with_password("bob", "pw");
        assert_eq!(found.flow.state().get().activity, Activity::CheckingPassword);
        // The refused try made no call, so this is the first one queued.
        let call = next_password(&found.fake).await;
        assert_eq!(call.attempt, 0);
        assert!(!password_called(&found.fake).await);
    }

    #[tokio::test(start_paused = true)]
    async fn rate_limit_defaults_and_minimum() {
        for (retry_after, shown) in [(None, 30), (Some(Duration::from_millis(200)), 1)] {
            let found = found_flow().await;
            answer_password(&found, Err(PasswordError::RateLimited { retry_after })).await;
            until(|| found.flow.state().get().retry_in.is_some()).await;
            assert_eq!(found.flow.state().get().retry_in, Some(Duration::from_secs(shown)));
        }
    }

    #[tokio::test(start_paused = true)]
    async fn changing_server_clears_countdown() {
        let found = found_flow().await;
        answer_password(&found, Err(PasswordError::RateLimited { retry_after: None })).await;
        until(|| found.flow.state().get().retry_in.is_some()).await;

        found.flow.set_server("example.org");
        assert_eq!(found.flow.state().get(), probing("example.org"));
        let probe = next_probe(&found.fake).await;
        assert_eq!(probe.server, "example.org");
        advance(Duration::from_secs(2)).await;
        settle().await;
        assert_eq!(found.flow.state().get(), probing("example.org"));
    }

    #[tokio::test(start_paused = true)]
    async fn other_error_sets_failure_and_next_attempt_clears_it() {
        let found = found_flow().await;
        answer_password(&found, Err(PasswordError::Forbidden)).await;
        until(|| found.flow.state().get().wrong_password).await;

        found.flow.sign_in_with_password("bob", "pw");
        assert!(!found.flow.state().get().wrong_password);
        next_password(&found.fake)
            .await
            .reply(Err(PasswordError::Refused { message: "nope".into() }));
        until(|| found.flow.state().get().failure.is_some()).await;
        let state = found.flow.state().get();
        assert_eq!(state.failure, Some(SignInFailure::Refused { message: "nope".into() }));
        assert_eq!((state.activity, state.wrong_password), (Activity::Idle, false));

        found.flow.sign_in_with_password("bob", "pw");
        let retried = found.flow.state().get();
        assert_eq!((retried.failure, retried.wrong_password), (None, false));
        assert_eq!(retried.activity, Activity::CheckingPassword);
    }

    #[tokio::test(start_paused = true)]
    async fn failed_secret_write_fails_sign_in() {
        let found = found_flow().await;
        found.secrets.fail_next_set();
        answer_password(&found, Ok(bob())).await;
        until(|| found.flow.state().get().failure.is_some()).await;
        let state = found.flow.state().get();
        assert_eq!(
            (state.failure, state.activity),
            (Some(SignInFailure::CouldntFinish), Activity::Idle)
        );
        assert_eq!(found.fake.discarded_logged_out(), 1);
        assert_eq!(found.core.session().state().get(), SessionState::SignedOut);
        assert!(no_secrets(&found.secrets));
        assert!(timeout(Duration::from_secs(1), found.fake.next_commit()).await.is_err());
    }

    #[tokio::test(start_paused = true)]
    async fn failed_passphrase_write_deletes_the_session() {
        let found = found_flow().await;
        found.secrets.fail_next_set_of(PASSPHRASE_KEY);
        answer_password(&found, Ok(bob())).await;
        until(|| found.flow.state().get().failure.is_some()).await;
        assert_eq!(found.flow.state().get().failure, Some(SignInFailure::CouldntFinish));
        assert_eq!(found.fake.discarded_logged_out(), 1);
        assert!(no_secrets(&found.secrets));
    }

    #[tokio::test(start_paused = true)]
    async fn failed_commit_brings_controls_back() {
        let found = found_flow().await;
        answer_password(&found, Ok(bob())).await;
        next_commit(&found.fake).await.reply(Err(CommitError));
        until(|| found.flow.state().get().failure.is_some()).await;
        let state = found.flow.state().get();
        assert_eq!(
            (state.failure, state.activity),
            (Some(SignInFailure::CouldntFinish), Activity::Idle)
        );
        assert_eq!(found.core.session().state().get(), SessionState::SignedOut);
        assert!(no_secrets(&found.secrets));

        // The controls are back: the current server is probed for a fresh attempt.
        assert_eq!(next_probe(&found.fake).await.server, "loaf.moe");
    }

    #[tokio::test(start_paused = true)]
    async fn after_tokens_cancel_and_set_server_are_ignored() {
        let found = found_flow().await;
        answer_password(&found, Ok(bob())).await;
        let commit = next_commit(&found.fake).await;
        let before = found.flow.state().get();
        assert_eq!(before.activity, Activity::SignedIn);

        found.flow.set_server("x.org");
        found.flow.retry();
        found.flow.sign_in_with_password("bob", "pw");
        assert_eq!(found.flow.state().get(), before);
        assert!(timeout(Duration::from_secs(1), found.fake.next_probe()).await.is_err());
        assert!(!password_called(&found.fake).await);

        commit.reply(Ok(FakeAccount::new(&found.fake)));
        until(|| found.core.session().state().get() != SessionState::SignedOut).await;
    }

    #[tokio::test(start_paused = true)]
    async fn dropped_flow_discards_late_success() {
        let found = found_flow().await;
        found.flow.sign_in_with_password("bob", "pw");
        let call = next_password(&found.fake).await;
        let Found {
            core,
            fake,
            flow,
            secrets: _,
            passphrase: _,
        } = found;
        drop(flow);
        call.reply(Ok(bob()));
        until(|| fake.discarded_logged_out() == 1).await;
        assert!(timeout(Duration::from_secs(1), fake.next_commit()).await.is_err());
        assert_eq!(fake.commits(), 0);
        assert_eq!(core.session().state().get(), SessionState::SignedOut);
    }

    #[tokio::test(start_paused = true)]
    async fn server_change_during_check_discards_late_success() {
        let found = found_flow().await;
        found.flow.sign_in_with_password("bob", "pw");
        let call = next_password(&found.fake).await;
        found.flow.set_server("example.org");
        let probe = next_probe(&found.fake).await;
        assert_eq!(probe.server, "example.org");

        call.reply(Ok(bob()));
        until(|| found.fake.discarded_logged_out() == 1).await;
        assert!(timeout(Duration::from_secs(1), found.fake.next_commit()).await.is_err());
        assert_eq!(found.flow.state().get(), probing("example.org"));
        assert_eq!(found.core.session().state().get(), SessionState::SignedOut);
    }

    #[tokio::test(start_paused = true)]
    async fn newer_flow_makes_late_success_stale() {
        let found = found_flow().await;
        found.flow.sign_in_with_password("bob", "pw");
        let call = next_password(&found.fake).await;
        let _second_flow = found.core.session().begin_sign_in().unwrap();
        let _second = next_probe(&found.fake).await;

        call.reply(Ok(bob()));
        until(|| found.fake.discarded_logged_out() == 1).await;
        assert!(timeout(Duration::from_secs(1), found.fake.next_commit()).await.is_err());
        assert_eq!(found.core.session().state().get(), SessionState::SignedOut);
    }

    #[tokio::test(start_paused = true)]
    async fn begin_while_committing_is_refused() {
        let found = found_flow().await;
        answer_password(&found, Ok(bob())).await;
        let commit = next_commit(&found.fake).await;
        assert!(matches!(found.core.session().begin_sign_in(), Err(NotSignedOut)));

        // A failed commit gives the session back to sign-in.
        commit.reply(Err(CommitError));
        until(|| found.flow.state().get().failure.is_some()).await;
        found.core.session().begin_sign_in().unwrap();
    }

    #[tokio::test(start_paused = true)]
    async fn sign_in_after_failed_commit_reaches_a_password_call() {
        let found = found_flow().await;
        answer_password(&found, Ok(bob())).await;
        next_commit(&found.fake).await.reply(Err(CommitError));

        let reprobe = next_probe(&found.fake).await;
        assert_eq!(reprobe.server, "loaf.moe");
        let state = found.flow.state().get();
        assert_eq!(
            (state.failure, state.activity, state.check),
            (Some(SignInFailure::CouldntFinish), Activity::Idle, ServerCheck::Probing)
        );
        reprobe.reply(Ok(FakeProbe::new(offer())));
        until(|| matches!(found.flow.state().get().check, ServerCheck::Found(_))).await;
        assert_eq!(found.flow.state().get().failure, Some(SignInFailure::CouldntFinish));

        found.flow.sign_in_with_password("bob", "pw");
        assert_eq!(next_password(&found.fake).await.attempt, 1);
    }

    #[tokio::test(start_paused = true)]
    async fn retry_keeps_the_countdown() {
        let found = found_flow().await;
        answer_password(&found, Err(PasswordError::RateLimited { retry_after: None })).await;
        until(|| found.flow.state().get().retry_in.is_some()).await;
        assert_eq!(found.flow.state().get().retry_in, Some(Duration::from_secs(30)));

        found.flow.retry();
        assert_eq!(found.flow.state().get().retry_in, Some(Duration::from_secs(30)));
        let probe = next_probe(&found.fake).await;
        assert_eq!(probe.server, "loaf.moe");
        // One countdown runs, in the new epoch: a second moves it by one.
        advance(Duration::from_secs(1)).await;
        settle().await;
        assert_eq!(found.flow.state().get().retry_in, Some(Duration::from_secs(29)));

        probe.reply(Ok(FakeProbe::new(offer())));
        until(|| matches!(found.flow.state().get().check, ServerCheck::Found(_))).await;
        assert!(found.flow.state().get().retry_in.is_some());
        found.flow.sign_in_with_password("bob", "pw");
        assert!(!password_called(&found.fake).await);

        advance(Duration::from_secs(30)).await;
        settle().await;
        assert_eq!(found.flow.state().get().retry_in, None);
    }

    /// An offer from a server that signs in only through the browser.
    fn browser_only() -> ServerOffer {
        ServerOffer {
            password: false,
            ..offer()
        }
    }

    /// Whether no probe is queued once spawned work has run, without moving
    /// the paused clock.
    async fn no_probe_queued(fake: &FakeMatrix) -> bool {
        settle().await;
        timeout(Duration::ZERO, fake.next_probe()).await.is_err()
    }

    /// Moves the paused clock by `millis` and lets woken work run.
    async fn advance_ms(millis: u64) {
        advance(Duration::from_millis(millis)).await;
        settle().await;
    }

    #[tokio::test(start_paused = true)]
    async fn full_id_repoints_after_400ms_quiet() {
        let found = found_flow().await;
        found.flow.username_changed("@a:other.org");
        advance_ms(399).await;
        assert!(no_probe_queued(&found.fake).await);
        assert_eq!(found.flow.state().get().repointing, None);

        advance_ms(1).await;
        let probe = next_probe(&found.fake).await;
        assert_eq!(probe.server, "other.org");
        let probing_other = found.flow.state().get();
        assert_eq!(probing_other.repointing.as_deref(), Some("other.org"));
        assert_eq!(probing_other.check, ServerCheck::Found(auth_methods(&offer())));
        assert_eq!(probing_other.server, "loaf.moe");

        probe.reply(Ok(FakeProbe::new(browser_only())));
        until(|| found.flow.state().get().repointing.is_none()).await;
        let on_other = found.flow.state().get();
        assert_eq!(on_other.server, "other.org");
        assert_eq!(on_other.check, ServerCheck::Found(auth_methods(&browser_only())));
        // The loaf.moe attempt was let go when the re-point began.
        assert_eq!(found.fake.discarded(), 1);
    }

    #[tokio::test(start_paused = true)]
    async fn typing_restarts_the_debounce() {
        let found = found_flow().await;
        found.flow.username_changed("@a:other.org");
        advance_ms(300).await;
        found.flow.username_changed("@ab:other.org");
        advance_ms(399).await;
        assert!(no_probe_queued(&found.fake).await);
        advance_ms(1).await;
        assert_eq!(next_probe(&found.fake).await.server, "other.org");
        assert!(no_probe_queued(&found.fake).await);
    }

    #[tokio::test(start_paused = true)]
    async fn plain_username_leaves_server_alone() {
        let found = found_flow().await;
        let before = found.flow.state().get();
        found.flow.username_changed("alice");
        advance_ms(1000).await;
        assert!(no_probe_queued(&found.fake).await);

        // Backing out of a full id cancels its pending re-point.
        found.flow.username_changed("@a:other.org");
        advance_ms(200).await;
        found.flow.username_changed("@a");
        advance_ms(1000).await;
        assert!(no_probe_queued(&found.fake).await);
        assert_eq!(found.flow.state().get(), before);
    }

    #[tokio::test(start_paused = true)]
    async fn same_server_does_nothing() {
        let found = found_flow().await;
        let before = found.flow.state().get();
        found.flow.username_changed("@a:loaf.moe");
        advance_ms(1000).await;
        assert!(no_probe_queued(&found.fake).await);
        assert_eq!(found.flow.state().get(), before);

        // Nothing is pending, so a password goes straight to loaf.moe.
        found.flow.username_changed("@a:loaf.moe");
        found.flow.sign_in_with_password("@a:loaf.moe", "pw");
        assert_eq!(next_password(&found.fake).await.attempt, 0);
    }

    #[tokio::test(start_paused = true)]
    async fn password_inside_debounce_goes_to_new_server() {
        let found = found_flow().await;
        found.flow.username_changed("@a:other.org");
        advance_ms(100).await;
        found.flow.sign_in_with_password("@a:other.org", "pw");
        assert_eq!(found.flow.state().get().activity, Activity::CheckingPassword);
        assert!(!password_called(&found.fake).await);

        let probe = next_probe(&found.fake).await;
        assert_eq!(probe.server, "other.org");
        probe.reply(Ok(FakeProbe::new(offer())));
        let call = next_password(&found.fake).await;
        assert_eq!(call.attempt, 1);
        assert_eq!((call.user.as_str(), call.password.as_str()), ("@a:other.org", "pw"));
        let state = found.flow.state().get();
        assert_eq!((state.server.as_str(), state.repointing), ("other.org", None));
        assert_eq!(state.activity, Activity::CheckingPassword);
    }

    #[tokio::test(start_paused = true)]
    async fn password_held_for_server_without_passwords_is_dropped() {
        let found = found_flow().await;
        found.flow.username_changed("@a:other.org");
        found.flow.sign_in_with_password("@a:other.org", "pw");
        next_probe(&found.fake).await.reply(Ok(FakeProbe::new(browser_only())));
        until(|| found.flow.state().get().repointing.is_none()).await;
        let state = found.flow.state().get();
        assert_eq!(state.activity, Activity::Idle);
        assert_eq!(state.check, ServerCheck::Found(auth_methods(&browser_only())));
        assert!(!password_called(&found.fake).await);
    }

    #[tokio::test(start_paused = true)]
    async fn password_during_repoint_probe_is_held() {
        let found = found_flow().await;
        found.flow.username_changed("@a:other.org");
        let probe = next_probe(&found.fake).await;
        found.flow.sign_in_with_password("@a:other.org", "pw");
        assert_eq!(found.flow.state().get().activity, Activity::CheckingPassword);
        assert!(!password_called(&found.fake).await);

        probe.reply(Ok(FakeProbe::new(offer())));
        assert_eq!(next_password(&found.fake).await.attempt, 1);
    }

    #[tokio::test(start_paused = true)]
    async fn unreachable_repoint_moves_the_server_and_drops_the_password() {
        let found = found_flow().await;
        found.flow.username_changed("@a:other.org");
        found.flow.sign_in_with_password("@a:other.org", "pw");
        next_probe(&found.fake).await.reply(Err(Unreachable));
        until(|| found.flow.state().get().repointing.is_none()).await;
        let state = found.flow.state().get();
        assert_eq!(state.server, "other.org");
        assert_eq!(
            (state.check, state.activity),
            (ServerCheck::CouldntReach, Activity::Idle)
        );
        assert!(!password_called(&found.fake).await);
    }

    #[tokio::test(start_paused = true)]
    async fn set_server_cancels_a_pending_repoint_and_held_password() {
        let found = found_flow().await;
        found.flow.username_changed("@a:other.org");
        // A plain username names no server, so it waits on the pending re-point.
        found.flow.sign_in_with_password("bob", "pw");
        found.flow.set_server("example.org");
        assert_eq!(found.flow.state().get(), probing("example.org"));
        let probe = next_probe(&found.fake).await;
        assert_eq!(probe.server, "example.org");
        advance_ms(1000).await;
        assert!(no_probe_queued(&found.fake).await);

        probe.reply(Ok(FakeProbe::new(offer())));
        until(|| matches!(found.flow.state().get().check, ServerCheck::Found(_))).await;
        assert_eq!(found.flow.state().get().activity, Activity::Idle);
        assert!(!password_called(&found.fake).await);
    }

    #[tokio::test(start_paused = true)]
    async fn retry_cancels_a_repoint_in_flight() {
        let found = found_flow().await;
        found.flow.username_changed("@a:other.org");
        let repoint = next_probe(&found.fake).await;
        found.flow.sign_in_with_password("@a:other.org", "pw");
        found.flow.retry();
        assert_eq!(found.flow.state().get(), probing("loaf.moe"));
        // Held unanswered, so the retry stays in flight.
        let again = next_probe(&found.fake).await;
        assert_eq!(again.server, "loaf.moe");

        repoint.reply(Ok(FakeProbe::new(offer())));
        until(|| found.fake.discarded() == 2).await;
        assert_eq!(found.flow.state().get(), probing("loaf.moe"));
        assert!(!password_called(&found.fake).await);
    }

    #[tokio::test(start_paused = true)]
    async fn repoint_clears_the_countdown() {
        let found = found_flow().await;
        answer_password(&found, Err(PasswordError::RateLimited { retry_after: None })).await;
        until(|| found.flow.state().get().retry_in.is_some()).await;
        found.flow.username_changed("@a:other.org");
        let probe = next_probe(&found.fake).await;
        assert_eq!(found.flow.state().get().retry_in, None);
        advance_ms(2000).await;
        assert_eq!(found.flow.state().get().retry_in, None);

        probe.reply(Ok(FakeProbe::new(offer())));
        until(|| found.flow.state().get().repointing.is_none()).await;
        found.flow.sign_in_with_password("@a:other.org", "pw");
        assert_eq!(next_password(&found.fake).await.attempt, 1);
    }

    #[tokio::test(start_paused = true)]
    async fn held_password_follows_its_own_user_id() {
        let found = found_flow().await;
        found.flow.username_changed("@a:other.org");
        let other = next_probe(&found.fake).await;
        found.flow.username_changed("@a:third.org");
        found.flow.sign_in_with_password("@a:third.org", "pw");

        // The password's own id re-points at once, leaving other.org behind.
        let third = next_probe(&found.fake).await;
        assert_eq!(third.server, "third.org");
        assert_eq!(found.flow.state().get().repointing.as_deref(), Some("third.org"));
        other.reply(Ok(FakeProbe::new(offer())));
        assert!(!password_called(&found.fake).await);

        third.reply(Ok(FakeProbe::new(offer())));
        let call = next_password(&found.fake).await;
        assert_eq!((call.attempt, call.user.as_str()), (2, "@a:third.org"));
    }

    #[tokio::test(start_paused = true)]
    async fn password_after_a_lost_repoint_goes_to_its_own_server() {
        let found = found_flow().await;
        found.flow.sign_in_with_password("bob", "pw");
        let first = next_password(&found.fake).await;
        // The quiet period ends while the flow is busy, so it re-points nothing.
        found.flow.username_changed("@a:other.org");
        advance_ms(400).await;
        assert!(no_probe_queued(&found.fake).await);
        first.reply(Err(PasswordError::Forbidden));
        until(|| found.flow.state().get().wrong_password).await;

        found.flow.sign_in_with_password("@a:other.org", "pw");
        assert_eq!(found.flow.state().get().activity, Activity::CheckingPassword);
        let probe = next_probe(&found.fake).await;
        assert_eq!(probe.server, "other.org");
        assert_eq!(found.flow.state().get().repointing.as_deref(), Some("other.org"));
        assert!(!password_called(&found.fake).await);

        probe.reply(Ok(FakeProbe::new(offer())));
        let call = next_password(&found.fake).await;
        assert_eq!((call.attempt, call.user.as_str()), (1, "@a:other.org"));
    }

    #[tokio::test(start_paused = true)]
    async fn set_server_to_the_old_server_during_a_repoint_wins() {
        let found = found_flow().await;
        found.flow.username_changed("@a:other.org");
        let repoint = next_probe(&found.fake).await;
        found.flow.set_server("loaf.moe");
        assert_eq!(found.flow.state().get(), probing("loaf.moe"));
        // Held unanswered, so the new probe stays in flight.
        let again = next_probe(&found.fake).await;
        assert_eq!(again.server, "loaf.moe");

        repoint.reply(Ok(FakeProbe::new(offer())));
        until(|| found.fake.discarded() == 2).await;
        assert_eq!(found.flow.state().get(), probing("loaf.moe"));
    }

    #[tokio::test(start_paused = true)]
    async fn half_typed_server_cancels_a_pending_repoint() {
        let found = found_flow().await;
        found.flow.username_changed("@a:other.org");
        found.flow.sign_in_with_password("bob", "pw");
        assert_eq!(found.flow.state().get().activity, Activity::CheckingPassword);
        found.flow.set_server("loa");
        assert_eq!(found.flow.state().get().activity, Activity::Idle);

        advance_ms(1000).await;
        assert!(no_probe_queued(&found.fake).await);
        let state = found.flow.state().get();
        assert_eq!((state.server.as_str(), state.repointing), ("loaf.moe", None));
        assert!(!password_called(&found.fake).await);
    }

    #[tokio::test(start_paused = true)]
    async fn repoint_clears_the_old_servers_refusal() {
        for refusal in [
            PasswordError::Forbidden,
            PasswordError::Refused { message: "nope".into() },
        ] {
            let found = found_flow().await;
            answer_password(&found, Err(refusal)).await;
            until(|| {
                let state = found.flow.state().get();
                state.wrong_password || state.failure.is_some()
            })
            .await;

            found.flow.username_changed("@a:other.org");
            let _probe = next_probe(&found.fake).await;
            let state = found.flow.state().get();
            assert_eq!(state.repointing.as_deref(), Some("other.org"));
            assert_eq!((state.wrong_password, state.failure), (false, None));
        }
    }

    #[tokio::test(start_paused = true)]
    async fn resent_username_keeps_the_held_password() {
        let found = found_flow().await;
        found.flow.username_changed("@a:other.org");
        found.flow.sign_in_with_password("@a:other.org", "pw");
        let probe = next_probe(&found.fake).await;
        found.flow.username_changed(" @a:other.org ");
        assert_eq!(found.flow.state().get().activity, Activity::CheckingPassword);

        probe.reply(Ok(FakeProbe::new(offer())));
        assert_eq!(next_password(&found.fake).await.attempt, 1);
    }

    #[tokio::test(start_paused = true)]
    async fn editing_the_username_lets_a_held_password_go() {
        let found = found_flow().await;
        found.flow.username_changed("@a:other.org");
        found.flow.sign_in_with_password("@a:other.org", "pw");
        found.flow.username_changed("@ab:other.org");
        assert_eq!(found.flow.state().get().activity, Activity::Idle);

        next_probe(&found.fake).await.reply(Ok(FakeProbe::new(offer())));
        until(|| found.flow.state().get().repointing.is_none()).await;
        assert!(!password_called(&found.fake).await);
    }

    #[tokio::test(start_paused = true)]
    async fn busy_flow_is_not_repointed() {
        let found = found_flow().await;
        found.flow.sign_in_with_password("bob", "pw");
        let _call = next_password(&found.fake).await;
        found.flow.username_changed("@a:other.org");
        advance_ms(1000).await;
        assert!(no_probe_queued(&found.fake).await);
    }

    #[tokio::test(start_paused = true)]
    async fn dropped_flow_cancels_a_pending_repoint() {
        let found = found_flow().await;
        found.flow.username_changed("@a:other.org");
        let Found {
            core: _core,
            fake,
            secrets: _,
            flow,
            passphrase: _,
        } = found;
        drop(flow);
        advance_ms(1000).await;
        assert!(no_probe_queued(&fake).await);
    }
}
