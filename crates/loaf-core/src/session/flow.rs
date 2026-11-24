//! The sign-in flow: discovering a server and dropping answers gone stale.

use alloc::sync::Arc;
use core::sync::atomic::{AtomicU64, Ordering};
use core::time::Duration;
use std::sync::{Mutex, MutexGuard, PoisonError};

use eyeball::{SharedObservable, Subscriber};
use tokio::runtime::Handle;

use crate::ports::matrix::{Attempt, Probe, Unreachable};
use crate::session::AuthMethods;
use crate::session::keeping::Keeping;
use crate::session::server::{auth_methods, parse_server};

/// The server a flow probes before the person types one.
const DEFAULT_SERVER: &str = "loaf.moe";

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
    /// The Matrix port, and later the device name and the commit.
    keeping: Arc<Keeping>,
    /// Where spawned work and discards run.
    runtime: Handle,
    /// The session's flow generation; this flow is inert once it moves on.
    generations: Arc<AtomicU64>,
    /// The generation this flow began in.
    generation: u64,
    /// What the shell observes; written only under `inner`'s lock, so it
    /// changes in epoch order.
    state: SharedObservable<SignInState>,
    /// Never held across an `.await`.
    inner: Mutex<Inner>,
}

/// The flow's mutable core, behind `Shared::inner`.
struct Inner {
    /// Bumped by anything that makes earlier answers stale: a new probe, or
    /// dropping the flow.
    epoch: u64,
    /// The attempt the found server started, kept for the sign-in that follows.
    probe: Option<Pending>,
}

/// An attempt and the passphrase its pending store was opened under.
struct Pending {
    /// Signs in against the found server; discarded when not committed.
    attempt: Box<dyn Attempt>,
    /// Committing the attempt stores this beside the session.
    #[expect(dead_code, reason = "used from Task 6")]
    passphrase: String,
}

impl SignInFlow {
    /// A flow in `generation` that starts probing the default server.
    pub(crate) fn begin(keeping: Arc<Keeping>, runtime: Handle, generations: Arc<AtomicU64>, generation: u64) -> Self {
        let shared = Arc::new(Shared {
            keeping,
            runtime,
            generations,
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
        self.generations.load(Ordering::SeqCst) == self.generation
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
            if !self.is_current_flow() {
                return;
            }
            let Some(server) = choose(&self.state.get()) else {
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

    /// Discards `unwanted` on the runtime, for callers that can't await.
    fn discard_later(&self, unwanted: Option<Pending>) {
        if let Some(pending) = unwanted {
            self.runtime.spawn(pending.attempt.discard());
        }
    }
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
    use crate::fakes::{FakeAccount, FakeAuthBrowser, FakeMatrix, FakeProbe, FakeSecretStore, ProbeCall};
    use crate::ports::matrix::{IdentityProvider, ServerOffer};
    use crate::ports::secret_store::SecretStore as _;
    use crate::session::stored::{PASSPHRASE_KEY, SESSION_KEY, StoredAuth};
    use crate::session::{DeviceId, NotSignedOut, StoredSession, UserId};
    use std::path::PathBuf;
    use tokio::time::{sleep, timeout};
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
}
