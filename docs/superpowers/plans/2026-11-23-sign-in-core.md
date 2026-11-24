# Sign-in and session, Core: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The session area of `loaf-core`: sign in by OAuth, SSO or password, keep the session across launches, sign out. It sits behind the Matrix, `SecretStore` and `AuthBrowser` ports, with a fake for each and a Matrix adapter over matrix-sdk.

**Architecture:** `session/` holds the rules (`SignInFlow`, session keeping) and only talks to `ports/`. `matrix/` adapts matrix-sdk to the Matrix port. The flow and keeping are tested on paused tokio time against `#[cfg(test)]` fakes; the adapter is tested on matrix-sdk's mock server.

**Tech stack:** Rust 1.100, tokio, matrix-sdk 0.19.1, eyeball, async-trait, thiserror, serde/serde_json, tracing, url.

**Spec:** `docs/superpowers/specs/2026-11-22-sign-in-core-design.md`. Read it with `docs/superpowers/specs/2026-11-21-rust-rewrite-architecture-design.md` ("Ground rules", sections 1, 5 and 6).

## Global constraints

- From scratch: never read, port or cite the Dart app (`main`) code, tests or docs.
- Only stable Matrix, no MSCs. Every discovery failure is one failure, `CouldntReach`.
- Names: `Auth` in type names (`AuthMethods`, `AuthBrowser`), the full verb in methods (`authenticate`).
- Lint policy from the workspace `Cargo.toml`: no `unwrap`, `expect`, `panic`, indexing, `dbg`, `todo` or print outside tests. Silence a lint with `#[expect(lint, reason = "…")]`, never `#[allow]`.
- No matrix-sdk type crosses `ports/`. `session/` never imports `matrix_sdk`.
- Tokens, passwords and the store passphrase are never logged. Types that hold them implement `Debug` by hand and redact those fields.
- Build only what this step uses. `Core` has only `session()`. Fakes stay `#[cfg(test)]`.
- Every runnable step is a mise task. `mise run check` is the commit gate.
- Commits say what the code does. No "instead of", no AI phrasing. End each with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Re-check the branch (`git branch --show-current` is `feat/core-build`) before each commit.

## Decisions for Chris to confirm

Each of these was left open by the spec, or makes a small departure from it:

1. **Runtime.** The architecture says the core owns a tokio runtime so that GPUI and Swift never need one. In this step, nothing calls the core from outside tokio. `Core::start` therefore runs on the caller's tokio runtime, and the Desktop step adds the owned runtime when GPUI first needs it. Paused-time tests need the test's own runtime anyway.
2. **matrix-sdk features.** `default-features = false, features = ["e2e-encryption", "sqlite", "bundled-sqlite", "rustls-aws-lc-rs"]`. The spec names `sqlite` and `e2e-encryption`. Turning the defaults off means picking a TLS backend by name. `bundled-sqlite` gives Windows and iOS the same SQLite as Linux. Both compile C through their build scripts. That C is a dependency's, not code we write.
3. **Extra dependencies** beyond the spec's list: `async-trait` (matches UniFFI's documented way to export async traits), `serde` + `serde_json` (the `session` secret), `rand` (the store passphrase; matrix-sdk already pulls in 0.10). Dev-only: `tempfile`, `wiremock`, `tracing-subscriber`.
4. **Port signatures stay as in the spec** (`&str` parameters). The UniFFI docs say foreign trait methods take owned values and return `Result`. `loaf-core` has no FFI dependency, so the iOS step mirrors `SecretStore` and `AuthBrowser` as foreign traits in `loaf-ffi`, with a small adapter to these ports.
5. **The Matrix port reports what the server offers, not `AuthMethods`.** "OAuth hides SSO" and provider naming are policy, so they live in `session/` (architecture: "no policy lives in an adapter"). The port returns a raw `ServerOffer`.
6. **Restriction lints.** The workspace enables all of `clippy::restriction`. Some of its lints reject idiomatic code, such as `question_mark_used`, `single_call_fn`, `missing_inline_in_public_items`, `exhaustive_structs`/`exhaustive_enums`, `pub_use`, `min_ident_chars` and `arbitrary_source_item_ordering`, and some pairs contradict each other. When code first hits one, it is set to `allow` in `[workspace.lints.clippy]` with a one-line reason, in the commit that hits it. Everything else is fixed in code.

## Review focus

These are inputs and conditions the spec implies but doesn't list. Each one has its test in the task named.

1. **Two OAuth tries on one attempt** (cancel, then "continue" again). matrix-sdk's `restore_registered_client` panics if auth data is already set. The second try must work → Task 9, `oauth_after_cancelled_oauth_signs_in`.
2. **A loopback redirect with a port.** The Matrix spec says a native client registers loopback redirects *without* a port and sends the port at authorization. If a port is registered, the server rejects the client → Task 9, `loopback_redirect_registers_without_port`.
3. **The SDK hides rate limits.** By default matrix-sdk retries `429` itself, without limit, so `M_LIMIT_EXCEEDED` never reaches the countdown. Attempt clients turn retries off → Task 9, `rate_limited_password_returns_promptly`.
4. **`Retry-After` as an HTTP date.** ruma gives `RetryAfter::DateTime` when the header carries a date. It must map to the time remaining, at least 1 s → Task 9, `retry_after_date_maps_to_remaining`.
5. **The flow dropped mid-sign-in** (the window is closed). A late success must still be discarded and its token logged out, leaving no device and no pending store → Task 6, `dropped_flow_discards_late_success`.

---

## File structure

```
crates/loaf-core/
  Cargo.toml                 dependencies (added task by task)
  src/lib.rs                 pub mod core, ports, session; mod matrix
  src/core.rs                Core, CoreConfig, Platform, StartError
  src/ports.rs               pub mod matrix, secret_store, auth_browser
  src/ports/secret_store.rs  SecretStore, SecretStoreError
  src/ports/auth_browser.rs  AuthBrowser, AuthBrowserError
  src/ports/matrix.rs        Matrix, Attempt, Account and their types
  src/session.rs             Session handle, SessionState, UserId, DeviceId
  src/session/stored.rs      StoredSession, its serialisation, the secret keys
  src/session/server.rs      parse_server, auth_methods (pure)
  src/session/flow.rs        SignInFlow, SignInState and the flow rules
  src/session/keeping.rs     commit, restore, refresh persistence, sign-out
  src/fakes.rs               #[cfg(test)] FakeMatrix, FakeSecretStore, FakeAuthBrowser
  src/matrix.rs              MatrixAdapter (impl Matrix)
  src/matrix/attempt.rs      SdkAttempt (impl Attempt)
  src/matrix/account.rs      SdkAccount (impl Account)
  src/matrix/errors.rs       SDK error → port error mapping
  tests/full_session.rs      Core over the adapter and the mock server, plus the log check
```

The `mod.rs` vs `self_named_module_files` choice follows the scaffold: named module files (`ports.rs` + `ports/`).

## Port shapes (Task 3 defines them; every later task consumes them)

```rust
// ports/secret_store.rs — as in the spec
#[async_trait] pub trait SecretStore: Send + Sync {
    async fn get(&self, key: &str) -> Result<Option<String>, SecretStoreError>;
    async fn set(&self, key: &str, value: &str) -> Result<(), SecretStoreError>;
    async fn delete(&self, key: &str) -> Result<(), SecretStoreError>;
}
#[derive(Debug, thiserror::Error)] #[error("secret store unavailable: {0}")]
pub struct SecretStoreError(pub String);

// ports/auth_browser.rs — as in the spec
#[async_trait] pub trait AuthBrowser: Send + Sync {
    async fn redirect_uri(&self) -> Result<Url, AuthBrowserError>;
    async fn authenticate(&self, url: Url) -> Result<Url, AuthBrowserError>;
    fn reopen(&self);
    fn cancel(&self);
}
pub enum AuthBrowserError { Cancelled, CouldntOpen }

// ports/matrix.rs
#[async_trait] pub trait Matrix: Send + Sync {
    /// `server` is a host (from parse_server) or, in adapter tests, a URL.
    async fn probe(&self, server: &str, passphrase: &str) -> Result<Probe, Unreachable>;
    async fn restore(&self, session: &StoredSession, passphrase: &str)
        -> Result<Arc<dyn Account>, WontRestore>;
    async fn wipe(&self) -> Result<(), WipeError>;
}
pub struct Probe { pub offer: ServerOffer, pub attempt: Box<dyn Attempt> }
pub struct ServerOffer { pub oauth: bool, pub sso: Option<Vec<IdentityProvider>>, pub password: bool }
pub struct IdentityProvider { pub id: String, pub name: Option<String> }

#[async_trait] pub trait Attempt: Send + Sync {
    async fn sign_in_with_password(&self, user: &str, password: &str, device_name: &str)
        -> Result<StoredSession, PasswordError>;
    async fn browser_url(&self, method: &BrowserMethod, redirect: &Url, device_name: &str)
        -> Result<Url, AttemptError>;
    async fn finish_browser(&self, callback: &Url) -> Result<StoredSession, FinishError>;
    /// Closes the attempt's client, moves its store to data_dir/matrix, reopens it signed in.
    async fn commit(self: Box<Self>, session: &StoredSession) -> Result<Arc<dyn Account>, CommitError>;
    /// Logs out any token it got (15 s timeout) and deletes its store.
    async fn discard(self: Box<Self>);
}
pub enum PasswordError { Forbidden, RateLimited { retry_after: Option<Duration> }, Refused { message: String }, Other }
pub enum FinishError { TokenRefused, Other }

#[async_trait] pub trait Account: Send + Sync {
    fn session_changes(&self) -> tokio::sync::mpsc::UnboundedReceiver<SessionChange>;
    async fn logout(&self) -> Result<(), LogoutError>;
}
pub enum SessionChange { TokensRefreshed(StoredSession), Unrecoverable }
```

`Unreachable`, `WontRestore`, `WipeError`, `AttemptError`, `CommitError` and `LogoutError` are unit-like `thiserror` structs. `StoredSession` and `BrowserMethod` come from Tasks 1 and 2.

---

### Task 1: StoredSession and the SecretStore port

**Files:**
- Modify: `crates/loaf-core/Cargo.toml` (add `serde` with `derive`, `serde_json`, `thiserror`, `url` with `serde`, `async-trait`; dev: `tokio` with `macros, rt, test-util`)
- Create: `src/session.rs` (only `UserId`, `DeviceId` and `mod stored` for now), `src/session/stored.rs`, `src/ports.rs`, `src/ports/secret_store.rs`, `src/fakes.rs` (`FakeSecretStore` only)
- Modify: `src/lib.rs`

**Interfaces:**
- Produces:
  - `pub struct UserId(String)` and `pub struct DeviceId(String)`, each with `as_str()` and `From<String>`.
  - `pub struct StoredSession { pub homeserver: Url, pub user: UserId, pub device: DeviceId, pub auth: StoredAuth }`.
  - `pub enum StoredAuth { Matrix { access_token: String, refresh_token: Option<String> }, OAuth { client_id: String, access_token: String, refresh_token: Option<String> } }`.
  - `StoredSession::to_secret(&self) -> String` and `StoredSession::from_secret(&str) -> Result<StoredSession, CorruptSession>`.
  - `pub(crate) const SESSION_KEY: &str = "session"` and `pub(crate) const PASSPHRASE_KEY: &str = "store-passphrase"`.
  - `FakeSecretStore::new()`, `.fail_next_set()`, `.fail_gets()`, `.value(key) -> Option<String>`.

- [ ] **Step 1: Write the failing tests** in `stored.rs`:
  - `round_trips_matrix_and_oauth`: `from_secret(to_secret(s)) == s` for both `StoredAuth` variants.
  - `corrupt_secret_is_an_error`: `from_secret("{")` and `from_secret("{}")` are `Err(CorruptSession)`.
  - `debug_redacts_tokens`: `format!("{s:?}")` contains neither the access token, the refresh token nor the client id's token fields.
- [ ] **Step 2:** Run `cargo nextest run -p loaf-core stored`. Expected: FAIL (does not compile).
- [ ] **Step 3: Implement.** serde JSON with `StoredAuth` tagged `#[serde(tag = "kind")]`. `Debug` by hand on `StoredSession` and `StoredAuth`; token fields print as `"<redacted>"`.
- [ ] **Step 4:** Add the `SecretStore` port and `FakeSecretStore`, which holds a `Mutex<HashMap>` and fails on command. Test `fake_secret_store_fails_on_command`: after `fail_next_set()`, one `set` is `Err` and the next `set` is `Ok`.
- [ ] **Step 5:** Run `mise run check`. Expected: PASS. Change the `test` task in `mise.toml` to drop `--no-tests=warn`, since the workspace now has tests.
- [ ] **Step 6: Commit** `feat(core): stored session and the SecretStore port`.

### Task 2: Server input and authentication methods

**Files:**
- Create: `src/session/server.rs`

**Interfaces:**
- Consumes: `ServerOffer` and `IdentityProvider` (write their definitions here first; Task 3 moves them into `ports/matrix.rs` if the reviewer prefers).
- Produces:
  - `pub(crate) fn parse_server(input: &str) -> Option<String>`.
  - `pub(crate) fn user_id_server(text: &str) -> Option<String>`: the host of a full user id typed into the username field.
  - `pub(crate) fn auth_methods(offer: &ServerOffer) -> AuthMethods`.
  - `pub struct AuthMethods { pub browser: Vec<BrowserMethod>, pub password: bool }`.
  - `pub enum BrowserMethod { OAuth, Sso { provider: Option<String>, name: Option<String> } }`.

- [ ] **Step 1: Write the failing tests.**
  - `names_urls_and_user_ids_give_the_host`: `"loaf.moe"`, `"https://loaf.moe/"`, `"https://matrix.loaf.moe:8448/path"` → `"matrix.loaf.moe:8448"`, `"@alice:Loaf.Moe"` → `"loaf.moe"`, `"  LOAF.moe "` → `"loaf.moe"`, `"localhost:8008"` → `"localhost:8008"`.
  - `implausible_input_gives_nothing`: `""`, `"loaf"`, `"loaf moe"`, `"@alice"`, `"https://"` → `None`.
  - `every_prefix_is_none_or_plausible`: for each prefix of `"https://matrix.loaf.moe:8448"` and `"@alice:loaf.moe"`, the result is `None` or a string containing `.` or starting with `localhost`, and nothing panics.
  - `user_id_server_only_for_full_ids`: `"@bob:example.org"` → `Some("example.org")`; `"bob"`, `"@bob"` and `"@bob:"` → `None`.
  - `oauth_hides_sso`: `{oauth: true, sso: Some([a, b]), password: true}` → `browser == [OAuth]`, `password`.
  - `sso_keeps_order_and_falls_back_to_id`: providers `[{id:"gh", name:Some("GitHub")}, {id:"kanidm", name:None}]` → `[Sso{provider:Some("gh"), name:Some("GitHub")}, Sso{provider:Some("kanidm"), name:Some("kanidm")}]`.
  - `sso_without_providers_is_one_method`: `sso: Some([])` → `[Sso{provider:None, name:None}]`.
  - `password_only_when_offered` and `nothing_usable_is_empty`.
- [ ] **Step 2:** Run `cargo nextest run -p loaf-core server`. Expected: FAIL.
- [ ] **Step 3: Implement.** Use `url::Url` for input with `://`. For a user id, take the part after the first `:`. Lowercase the result and keep the port. Plausible means it contains `.` or the host is `localhost`, and it has no whitespace.
- [ ] **Step 4:** Run `mise run check`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): parse server input and derive authentication methods`.

### Task 3: The Matrix and AuthBrowser ports, and the fakes

**Files:**
- Create: `src/ports/matrix.rs`, `src/ports/auth_browser.rs`
- Modify: `src/fakes.rs`, `src/session/server.rs` (move `ServerOffer` and `IdentityProvider` into the port)

**Interfaces:**
- Produces: the port shapes above, plus:
  - `FakeMatrix::new() -> Arc<FakeMatrix>`. Each port call sends a `Call` on an internal channel and waits for the test to answer: `fake.next_probe().await -> ProbeCall { server, passphrase, reply(Result<FakeProbe, Unreachable>) }`; `next_password()`, `next_browser_url()`, `next_finish()`, `next_commit()`, `next_restore()` and `next_logout()` work the same way. Discards and wipes answer at once.
  - Records: `fake.discarded() -> usize`, `fake.discarded_logged_out() -> usize`, `fake.wipes() -> usize`, `fake.commits() -> usize`.
  - `FakeProbe::new(offer)`. `FakeAccount::send(SessionChange)`.
  - `FakeAuthBrowser::new(redirect)`; `next_authenticate().await -> AuthCall { url, reply(Result<Url, AuthBrowserError>) }`; `.fail_open()`; records `reopens()` and `cancels()`. `cancel()` resolves a pending authenticate with `Cancelled`.

- [ ] **Step 1:** Write the port traits and types exactly as in "Port shapes".
- [ ] **Step 2:** Write the fakes. The answer-on-command model uses one `tokio::sync::mpsc` of calls per method, and each call carries a `oneshot::Sender` for its reply. Under paused time, a test controls exactly when each answer lands.
- [ ] **Step 3:** Test `fake_matrix_answers_when_told`: spawn `probe("a.b", "p")`; `next_probe()` shows `server == "a.b"`; the spawned task is still pending until `reply`, and resolves after it.
- [ ] **Step 4:** Run `mise run check`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): Matrix and AuthBrowser ports with fakes`.

### Task 4: Core, SessionState and restoring at start

**Files:**
- Modify: `Cargo.toml` (add `eyeball`, `tracing`, `tokio` with `sync, time, rt, macros`)
- Create: `src/core.rs`, `src/session/keeping.rs`
- Modify: `src/session.rs`

**Interfaces:**
- Consumes: Tasks 1 and 3.
- Produces:
  - `pub struct CoreConfig { pub data_dir: PathBuf, pub device_name: String, pub platform: Platform }`.
  - `pub struct Platform { pub secrets: Arc<dyn SecretStore>, pub auth_browser: Arc<dyn AuthBrowser> }`.
  - `Core::start(config) -> Result<Arc<Core>, StartError>`, which builds `MatrixAdapter` in Task 12. Until then: `pub(crate) async fn start_with(config, matrix: Arc<dyn Matrix>) -> Result<Arc<Core>, StartError>`.
  - `Core::session(&self) -> &Session`.
  - `pub enum SessionState { SignedOut, SignedIn { user: UserId, device: DeviceId } }`.
  - `Session::state(&self) -> eyeball::Subscriber<SessionState>`.
  - `Keeping` (crate-private) holds the `SharedObservable<SessionState>`, the ports, the device name and the current `Arc<dyn Account>`. `Keeping::restore()` is called by `start_with`.

- [ ] **Step 1: Write the failing tests** (`#[tokio::test(start_paused = true)]`, over the fakes):
  - `nothing_stored_starts_signed_out`: no `session` secret → `SignedOut`, `fake.wipes() == 1`, and the passphrase secret is deleted.
  - `stored_session_restores_signed_in`: secrets hold a session and passphrase; `next_restore()` gets them; reply `Ok(account)` → `SignedIn { user, device }` once `start_with` resolves.
  - `secret_store_error_signs_out_without_wiping`: `fail_gets()` → `SignedOut`, `wipes() == 0`, secrets untouched.
  - `corrupt_session_wipes`: `session = "{"` → `SignedOut`, `wipes() == 1`, both secrets deleted.
  - `store_that_wont_restore_wipes`: restore replies `Err(WontRestore)` → same as above.
- [ ] **Step 2:** Run `cargo nextest run -p loaf-core keeping`. Expected: FAIL.
- [ ] **Step 3: Implement** `Keeping::restore` by the spec's "Restoring at start". `wipe_local()` deletes `data_dir/matrix` through `Matrix::wipe` and both secrets. A failing step is logged with `tracing::warn!` and the remaining steps still run.
- [ ] **Step 4:** Run `mise run check`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): Core handle and restoring the session at start`.

### Task 5: SignInFlow, discovery and staleness

**Files:**
- Create: `src/session/flow.rs`
- Modify: `src/session.rs` (`begin_sign_in`)

**Interfaces:**
- Consumes: `parse_server`, `auth_methods`, `Matrix::probe`, `Keeping`.
- Produces:
  - `pub struct SignInState` exactly as in the spec, with `pub enum ServerCheck { Probing, Found(AuthMethods), CouldntReach }`, `pub enum Activity { Idle, InBrowser, CheckingPassword, SignedIn }` and `pub enum SignInFailure { CouldntReach, Refused { message: String }, BrowserDidntOpen, ProviderDidntFinish { name: String }, CouldntFinish }`.
  - `Session::begin_sign_in(&self) -> Result<SignInFlow, NotSignedOut>`.
  - `SignInFlow::state() -> Subscriber<SignInState>`, `set_server(&self, input: &str)`, `retry(&self)`.
  - Inside: `Inner { epoch: u64, probe: Option<Box<dyn Attempt>>, … }` behind a `Mutex`. Each command bumps `epoch` when it starts something new, then spawns. A spawned result is applied only if its epoch is still current; otherwise any `Attempt` it carries is `discard`ed. `Drop for SignInFlow` bumps the epoch and aborts its tasks. `Session` holds a flow generation counter so that `begin_sign_in` makes the older flow inert.
  - Each probe gets a fresh 32-byte random passphrase, hex-encoded (`rand`), which travels with the attempt to commit.

- [ ] **Step 1: Write the failing tests:**
  - `opens_probing_loaf_moe`: `next_probe().server == "loaf.moe"`; the state is `{server:"loaf.moe", check:Probing}`.
  - `found_server_publishes_methods`: reply `Found` with an offer → `check == Found(auth_methods(offer))`.
  - `unreachable_is_couldnt_reach_and_retry_probes_again`.
  - `half_typed_server_is_ignored`: `set_server("loa")` makes no probe call and leaves the state alone.
  - `answer_to_old_probe_is_dropped`: `set_server("a.org")`, then `set_server("b.org")`; answer the first probe → the state still shows `b.org` `Probing`, and the first attempt is discarded (`discarded() == 1`).
  - `second_begin_makes_first_inert`: flow 1 probing; `begin_sign_in()` again; flow 1's probe answers → flow 1's state doesn't change and its attempt is discarded.
  - `begin_while_signed_in_is_refused`.
- [ ] **Step 2:** Run `cargo nextest run -p loaf-core flow`. Expected: FAIL.
- [ ] **Step 3: Implement** to pass.
- [ ] **Step 4:** Run `mise run check`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): sign-in flow discovery with stale answers dropped`.

### Task 6: Password sign-in and committing

**Files:**
- Modify: `src/session/flow.rs`, `src/session/keeping.rs`

**Interfaces:**
- Produces:
  - `SignInFlow::sign_in_with_password(&self, user: &str, password: &str)`.
  - `Keeping::commit(attempt: Box<dyn Attempt>, session: StoredSession, passphrase: String) -> Result<(), CommitFailed>`. `CommitFailed` is a crate-private unit struct; the flow maps it to `SignInFailure::CouldntFinish`. It writes `session`, then `store-passphrase`, then calls `attempt.commit`, then publishes `SignedIn` and starts the refresh listener (Task 10 fills in the listener). If a write fails, it calls `attempt.discard()` and deletes whatever was written. If commit fails, it deletes both secrets.

- [ ] **Step 1: Write the failing tests:**
  - `right_credentials_sign_in`: password call gets the trimmed user and the device name → reply `Ok(session)` → `next_commit()` → reply `Ok(account)` → flow `activity == SignedIn`, session `SignedIn`, both secrets set.
  - `empty_fields_do_nothing`: `("  ", "pw")` and `("bob", "")` make no call.
  - `forbidden_sets_wrong_password`: back to `Idle`, `wrong_password == true`.
  - `rate_limit_counts_down`: `RateLimited{Some(2.3 s)}` → `retry_in == Some(3 s)`. Advance 1 s → 2 s. A sign-in attempt now makes no call. Advance 2 s → `None`, and sign-in works again.
  - `rate_limit_defaults_and_minimum`: `None` → 30 s; `Some(200 ms)` → 1 s.
  - `changing_server_clears_countdown`.
  - `other_error_sets_failure_and_next_attempt_clears_it`: `Refused{"nope"}` → `failure == Refused{"nope"}`; the next attempt clears both `failure` and `wrong_password`.
  - `failed_secret_write_fails_sign_in`: `fail_next_set()` → `failure == CouldntFinish`, `activity == Idle`, `discarded_logged_out() == 1`, session `SignedOut`, no secrets.
  - `failed_commit_brings_controls_back`: commit replies `Err` → `CouldntFinish`, `Idle`, secrets deleted.
  - `after_tokens_cancel_and_set_server_are_ignored`: while `next_commit()` is pending, `set_server("x.org")` and `cancel_browser()` change nothing, and no probe is made.
  - `dropped_flow_discards_late_success` (review focus 5): start a password sign-in, drop the flow, then reply `Ok(session)` → no commit, `discarded_logged_out() == 1`, session `SignedOut`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3: Implement.** The point of no return is when a current attempt's tokens arrive: set `activity = SignedIn` before calling `Keeping::commit`.
- [ ] **Step 4:** Run `mise run check`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): password sign-in, rate limit countdown and committing the session`.

### Task 7: Re-pointing from a full user id

**Files:**
- Modify: `src/session/flow.rs`

**Interfaces:**
- Produces: `SignInFlow::username_changed(&self, text: &str)`.

- [ ] **Step 1: Write the failing tests:**
  - `full_id_repoints_after_400ms_quiet`: `username_changed("@a:other.org")`; advance 399 ms → no probe; advance 1 ms → `next_probe().server == "other.org"`, `repointing == Some("other.org")`, and the form is still `Found`.
  - `typing_restarts_the_debounce`: changes at 0 and 300 ms → the probe comes at 700 ms.
  - `plain_username_leaves_server_alone`, and `same_server_does_nothing`.
  - `password_inside_debounce_goes_to_new_server`: change the id, then submit a password at 100 ms → no password call yet. The probe for `other.org` answers with password offered → the password call arrives on the new attempt.
  - `password_held_for_server_without_passwords_is_dropped`: the new server doesn't offer passwords → no password call, `activity == Idle`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3: Implement.** The debounce is a spawned `tokio::time::sleep(400 ms)` keyed by its own counter. A held password lives in `Inner` and is sent when the re-point probe lands.
- [ ] **Step 4:** Run `mise run check`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): re-point the server from a full user id`.

### Task 8: Browser sign-in in the flow

**Files:**
- Modify: `src/session/flow.rs`

**Interfaces:**
- Produces: `continue_with(&self, method: BrowserMethod)`, `reopen_browser(&self)`, `cancel_browser(&self)`.
- Sequence: `activity = InBrowser` → `auth_browser.redirect_uri()` → `attempt.browser_url(method, redirect, device_name)` → `auth_browser.authenticate(url)` → `attempt.finish_browser(callback)` → `Keeping::commit`.

- [ ] **Step 1: Write the failing tests:**
  - `sso_signs_in_through_browser` and `oauth_signs_in_through_browser`: the browser gets the URL the fake attempt built; the callback reaches `finish_browser`; the result is signed in.
  - `reopen_reaches_browser`: `reopen_browser()` while `InBrowser` → `reopens() == 1`.
  - `cancel_returns_to_idle_and_drops_late_answer`: cancel → `Idle`, `cancels() == 1`. A late `finish_browser` reply `Ok(session)` makes no commit and its token is logged out.
  - `closed_browser_is_quiet`: authenticate replies `Cancelled` → `Idle`, `failure == None`.
  - `browser_that_wont_open_is_failure`: `fail_open()` → `BrowserDidntOpen`.
  - `refused_login_token_is_provider_didnt_finish`: `FinishError::TokenRefused` with method `Sso{name:Some("GitHub")}` → `ProviderDidntFinish{name:"GitHub"}`. For OAuth, the name is the server.
  - `sign_in_answering_after_server_change_never_signs_in`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3: Implement** to pass.
- [ ] **Step 4:** Run `mise run check`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): browser sign-in through AuthBrowser`.

### Task 9: Matrix adapter, probing and attempts

**Files:**
- Modify: `Cargo.toml` (`matrix-sdk = { version = "=0.19.1", default-features = false, features = [...] }` as in decision 2; `rand`; dev: `matrix-sdk` with `testing`, `wiremock` and `tempfile` at the versions matrix-sdk resolves, checked with `cargo tree -i wiremock`)
- Create: `src/matrix.rs`, `src/matrix/attempt.rs`, `src/matrix/errors.rs`

**Interfaces:**
- Consumes: the port shapes.
- Produces: `pub(crate) struct MatrixAdapter`, `MatrixAdapter::new(data_dir: &Path) -> Result<MatrixAdapter, StartError>`. The constructor creates `data_dir` and deletes leftover `pending-*` directories.

**matrix-sdk calls** (checked against the 0.19.1 source):
- Probe: `Client::builder().server_name_or_homeserver_url(server).sqlite_store(pending_dir, Some(passphrase)).request_config(RequestConfig::new().disable_retry()).handle_refresh_tokens().build()`. Any `ClientBuildError` → `Unreachable`. Then `client.matrix_auth().get_login_types()` (an error → `Unreachable`) and `client.oauth().server_metadata()` (`is_not_supported()` → `oauth: false`; any other error → `oauth: false` and a logged warning). Map `LoginType::Password` and `LoginType::Sso(identity_providers)` into `ServerOffer`. Name each pending directory `pending-<n>` from an adapter counter.
- Password: `matrix_auth().login_username(user, password).initial_device_display_name(device_name).request_refresh_token().send()`. Map `client_api_error_kind()`: `ErrorKind::Forbidden` → `Forbidden`; `ErrorKind::LimitExceeded(LimitExceededErrorData { retry_after })` → `RateLimited`, where `RetryAfter::Delay(d)` → `d` and `RetryAfter::DateTime(t)` → `t - now` (saturating); other API errors → `Refused { message }` from `StandardErrorBody.message`; anything else → `Other`. Build `StoredSession` from `client.session()` (`AuthSession::Matrix`).
- SSO URL: `matrix_auth().get_sso_login_url(redirect.as_str(), provider.as_deref())`. Finish: `login_with_sso_callback(UrlOrQuery::Url(callback))` followed by `.initial_device_display_name(..).request_refresh_token().send()`. `SsoError::CallbackUrlInvalid` or an API error → `TokenRefused`.
- OAuth URL: metadata is `ClientMetadata::new(ApplicationType::Native, vec![OAuthGrantType::AuthorizationCode { redirect_uris: vec![registered] }], Localized::new(Url::parse("https://loaf.moe")?, []))` with `client_name = Some(Localized::new("Loaf Chat".into(), []))`. `registered` is `redirect` with the port removed when the host is `127.0.0.1`, `[::1]` or `localhost`. Under the Matrix spec's native-client rules, the shells' redirects become: desktop `http://127.0.0.1:<port>/callback`, registered without the port; Apple `moe.loaf.chat:/callback`, a private-use scheme prefixed with `client_uri`'s host reversed (`moe.loaf`). Then `oauth().login(redirect, None, Some(Raw::new(&metadata)?.into()), None).build()`; the URL comes from `OAuthAuthorizationData::url`. Finish: `oauth().finish_login(UrlOrQuery::Url(callback))`. Build `StoredSession` from `oauth().full_session()` (`StoredAuth::OAuth` with `client_id`).
- OAuth after an earlier OAuth try: `restore_registered_client` panics if auth data is already set. Before the second and later OAuth tries, the attempt drops its client, deletes its pending store and rebuilds both from the same homeserver URL.
- Discard: if the client has a session, `tokio::time::timeout(15 s, client.logout())`. Then drop the client and `tokio::fs::remove_dir_all(pending_dir)`.

- [ ] **Step 1: Write the failing tests** (mock server; `MatrixMockServer::new()`; probe with `server.uri()`; raw endpoints such as `GET /_matrix/client/v3/login` are mounted with `wiremock::Mock::given` on `server.server()`):
  - `probe_reports_password_and_sso_providers`, `probe_reports_oauth` (via `server.oauth().mock_server_metadata()`), and `probe_unreachable_server` (a closed port → `Unreachable`).
  - `password_sign_in_finishes`, `forbidden_password_maps`, `rate_limited_password_returns_promptly` (review focus 3: a single `429` with `retry_after_ms: 2000` → `RateLimited{Some(2 s)}`, and the endpoint is hit exactly once), `retry_after_date_maps_to_remaining` (review focus 4: unit test of the mapping function with `RetryAfter::DateTime(now + 5 s)` → about 5 s).
  - `sso_sign_in_finishes` (the URL contains `/login/sso/redirect/<idp>?redirectUrl=`; finish with `?loginToken=t`) and `refused_login_token_maps`.
  - `oauth_sign_in_finishes` (`mock_registration`, `mock_token`), `loopback_redirect_registers_without_port` (review focus 2: the registration request body's `redirect_uris == ["http://127.0.0.1/callback"]` for redirect `http://127.0.0.1:43123/callback`) and `oauth_after_cancelled_oauth_signs_in` (review focus 1).
  - `discarded_attempt_logs_out_and_leaves_no_store`: `mock_logout` is called once, and the pending directory is gone.
  - `new_deletes_leftover_pending_stores`.
- [ ] **Step 2:** Run `cargo nextest run -p loaf-core matrix::`. Expected: FAIL.
- [ ] **Step 3: Implement** to pass. Error mapping lives in `errors.rs`, the only place that matches on SDK error types.
- [ ] **Step 4:** Run `mise run check`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): Matrix adapter probing and sign-in attempts`.

### Task 10: Refresh persistence and signing out

**Files:**
- Modify: `src/session/keeping.rs`, `src/session.rs`

**Interfaces:**
- Produces: `Session::sign_out(&self)` (async, returns `()`). It uses the refresh listener started by `commit` and `restore`: a task that reads `account.session_changes()`.

- [ ] **Step 1: Write the failing tests:**
  - `refreshed_tokens_reach_secret_store`: `TokensRefreshed(s2)` → `session` secret == `s2.to_secret()`, state stays `SignedIn`.
  - `refresh_in_flight_never_signs_out`: with no change sent, advance time 1 h → still `SignedIn`.
  - `unrefreshable_token_signs_out_and_wipes`: `Unrecoverable` → `SignedOut`, `wipes() == 1`, both secrets gone.
  - `sign_out_wipes_even_when_logout_fails`: logout replies `Err` → `SignedOut`, wipe done, secrets gone.
  - `sign_out_logout_times_out_after_15s`: logout never answers; advance 15 s → wiped and `SignedOut`.
  - `second_sign_out_in_flight_does_nothing`: two concurrent `sign_out()` → one `next_logout()` and `wipes() == 1`.
  - `sign_in_again_after_sign_out_works`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3: Implement.** On sign-out: stop the listener, `timeout(15 s, account.logout())`, drop the `Account` (so the adapter's client closes), then `wipe_local()`, then publish `SignedOut`. An `AtomicBool` guards against a second sign-out.
- [ ] **Step 4:** Run `mise run check`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): persist refreshed tokens and sign out`.

### Task 11: Matrix adapter, commit, restore, account and wipe

**Files:**
- Create: `src/matrix/account.rs`
- Modify: `src/matrix.rs`, `src/matrix/attempt.rs`

**matrix-sdk calls:**
- Commit: drop every clone of the attempt's `Client`, `tokio::fs::rename(pending_dir, data_dir/matrix)`, then restore as below.
- Restore: `Client::builder().homeserver_url(session.homeserver).sqlite_store(data_dir/matrix, Some(passphrase)).handle_refresh_tokens().build()`, then `client.restore_session(auth_session)`. For OAuth the session is `OAuthSession { client_id: ClientId::new(id), user: UserSession { meta, tokens } }`; for Matrix it is a `MatrixSession`. Any error → `WontRestore`. This makes no network call.
- Session changes: spawn a task over `client.subscribe_to_session_changes()`. `TokensRefreshed` → read `client.session()` into a `StoredSession` → `SessionChange::TokensRefreshed`. `UnknownToken(_)` → `Unrecoverable`. The task ends when the receiver drops.
- Logout: `client.logout()`.
- Wipe: `remove_dir_all(data_dir/matrix)`. A missing directory is `Ok`.

- [ ] **Step 1: Write the failing tests:**
  - `committed_attempt_restores_offline_and_keeps_device_keys`: password sign-in, record `client.encryption().ed25519_key().await`, commit, drop the account, stop the mock server, `restore` → `Ok`, and the same ed25519 key.
  - `refreshed_tokens_are_reported`: mount `POST /_matrix/client/v3/refresh` returning new tokens, plus `whoami` returning `401 M_UNKNOWN_TOKEN` once then `200`. Call `whoami` on the account's client → `TokensRefreshed` carries the new access token.
  - `unrefreshable_token_is_reported`: `refresh` returns `401 M_UNKNOWN_TOKEN` → `Unrecoverable`.
  - `wipe_leaves_no_store`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3: Implement** to pass.
- [ ] **Step 4:** Run `mise run check`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): commit, restore and session changes in the Matrix adapter`.

### Task 12: Core::start over the adapter, and the log check

**Files:**
- Modify: `src/core.rs` (`Core::start` builds `MatrixAdapter::new(&data_dir)` and calls `start_with`)
- Create: `tests/full_session.rs`
- Modify: `Cargo.toml` (dev: `tracing-subscriber` with `fmt`)

**Interfaces:**
- Consumes: everything above. The integration test needs a `SecretStore` and an `AuthBrowser` outside the crate, so it defines its own small in-memory `SecretStore` and a refusing `AuthBrowser`. The `#[cfg(test)]` fakes stay private.

- [ ] **Step 1: Write the failing test** `full_session_logs_no_secrets`. It installs a `tracing_subscriber::fmt` subscriber at `TRACE` that writes into a shared buffer. Then: `Core::start` over a tempdir; `begin_sign_in()`; `set_server(server.uri())`; password sign-in with password `hunter2-secret`; wait for `SignedIn`; trigger a refresh as in Task 11; `sign_out()`. It asserts that the buffer contains none of `hunter2-secret`, either access token, either refresh token, or the passphrase read from the in-memory store.
- [ ] **Step 2:** Run `cargo nextest run -p loaf-core --test full_session`. Expected: FAIL.
- [ ] **Step 3: Implement** `Core::start`. If the test finds a secret in matrix-sdk's own output, stop and report it rather than filtering it.
- [ ] **Step 4:** Run `mise run check`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): start the core over the Matrix adapter`.

### Task 13: Finish

- [ ] Run `mise run check` from a clean `cargo clean -p loaf-core`. Expected: PASS.
- [ ] Re-read the spec's "Tests" list and tick each case against a test name above.
- [ ] Open the PR into `rust` from `feat/core-build`, with the Basecamp card URL in the body, then bind it with the ccd_pr tools.
