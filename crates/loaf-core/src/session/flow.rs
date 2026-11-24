//! The sign-in flow: discovering a server, signing in with a password,
//! and dropping answers gone stale.

use alloc::sync::Arc;
use core::time::Duration;
use std::sync::{Mutex, MutexGuard, PoisonError};

use eyeball::{SharedObservable, Subscriber};
use tokio::runtime::Handle;
use tokio::time::interval;

use crate::ports::matrix::{Attempt, PasswordError, Probe, Unreachable};
use crate::session::keeping::{CommitClaim, Keeping};
use crate::session::server::{auth_methods, parse_server};
use crate::session::{AuthMethods, StoredSession};

/// The server a flow probes before the person types one.
const DEFAULT_SERVER: &str = "loaf.moe";
/// How long password sign-in is refused when a rate-limiting server names no time.
const DEFAULT_RETRY_AFTER: Duration = Duration::from_secs(30);
/// How often the rate-limit countdown moves.
const COUNTDOWN_TICK: Duration = Duration::from_secs(1);

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
            inner: Mutex::new(Inner { epoch: 0, probe: None }),
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
    /// user id. Half-typed input, or the server already chosen, changes nothing.
    pub fn set_server(&self, input: &str) {
        let Some(server) = parse_server(input) else {
            return;
        };
        Shared::start_probe(&self.shared, |current| (current.server != server).then_some(server));
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
}

impl Drop for SignInFlow {
    /// Work still in flight sees the bumped epoch when it answers and
    /// discards what it got; the attempt already held is discarded here.
    fn drop(&mut self) {
        let held = {
            let mut inner = self.shared.lock();
            inner.epoch = inner.epoch.wrapping_add(1);
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
    /// one, in a new epoch that replaces the attempt held so far.
    fn start_probe(self: &Arc<Self>, choose: impl FnOnce(&SignInState) -> Option<String>) {
        let (server, epoch, replaced) = {
            let mut inner = self.lock();
            let current = self.state.get();
            // Past the point of no return, the session is being kept.
            if !self.is_current_flow() || current.activity == Activity::SignedIn {
                return;
            }
            let Some(server) = choose(&current) else {
                return;
            };
            inner.epoch = inner.epoch.wrapping_add(1);
            self.state.update(|state| *state = SignInState::probing(server.clone()));
            (server, inner.epoch, inner.probe.take())
        };
        self.discard_later(replaced);
        let passphrase = new_passphrase();
        let shared = Arc::clone(self);
        self.runtime.spawn(async move {
            let answer = shared.keeping.matrix().probe(&server, &passphrase).await;
            shared.apply_probe(epoch, answer, passphrase).await;
        });
    }

    /// Publishes a probe's answer if `epoch` is still current; otherwise
    /// discards the attempt it started.
    async fn apply_probe(&self, epoch: u64, answer: Result<Probe, Unreachable>, passphrase: String) {
        let unwanted = {
            let mut inner = self.lock();
            if self.is_current(&inner, epoch) {
                if let Ok(Probe { offer, attempt }) = answer {
                    self.state
                        .update(|state| state.check = ServerCheck::Found(auth_methods(&offer)));
                    inner.probe.replace(Pending { attempt, passphrase })
                } else {
                    self.state.update(|state| state.check = ServerCheck::CouldntReach);
                    None
                }
            } else {
                answer.ok().map(|probe| Pending {
                    attempt: probe.attempt,
                    passphrase,
                })
            }
        };
        if let Some(pending) = unwanted {
            pending.attempt.discard().await;
        }
    }

    /// Sends `user` and `password` through the held attempt in a new epoch,
    /// if the state allows a password sign-in now.
    fn start_password(self: &Arc<Self>, user: String, password: String) {
        let (pending, epoch) = {
            let mut inner = self.lock();
            let current = self.state.get();
            let takes_passwords = matches!(&current.check, ServerCheck::Found(methods) if methods.password);
            if !self.is_current_flow()
                || current.activity != Activity::Idle
                || !takes_passwords
                || current.retry_in.is_some()
            {
                return;
            }
            // The attempt is needed by value across the call; a server change
            // meanwhile finds none held and simply probes.
            let Some(pending) = inner.probe.take() else {
                return;
            };
            inner.epoch = inner.epoch.wrapping_add(1);
            self.state.update(|state| {
                state.activity = Activity::CheckingPassword;
                state.failure = None;
                state.wrong_password = false;
            });
            (pending, inner.epoch)
        };
        let shared = Arc::clone(self);
        self.runtime.spawn(async move {
            let answer = pending
                .attempt
                .sign_in_with_password(&user, &password, shared.keeping.device_name())
                .await;
            shared.apply_password(epoch, pending, answer).await;
        });
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
                    let _inner = self.lock();
                    self.state.update(|state| {
                        state.failure = Some(SignInFailure::CouldntFinish);
                        state.activity = Activity::Idle;
                    });
                }
            }
        }
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

        // The controls are back: a new probe starts a fresh attempt.
        found.flow.retry();
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
}
