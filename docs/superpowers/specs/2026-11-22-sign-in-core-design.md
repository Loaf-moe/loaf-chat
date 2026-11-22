# Sign-in and session: Core

Phase 1, step 1 of the rewrite (architecture spec, "Order of work"): the
session area of `loaf-core`, with the `SecretStore` and `AuthBrowser` traits
and their fakes. Desktop, iOS and CI are later steps with their own specs;
this one defines only the seams they plug into.

Reference: the architecture spec (PR #25, branch `docs/architecture`),
sections 1, 2, 5 and 6, and main's sign-in (`lib/ui/auth/`,
`lib/matrix/matrix_session.dart`, `lib/matrix/matrix_homeserver.dart`,
`lib/matrix/sso_browser.dart`) for behaviour.

## Why

Every later feature needs a signed-in matrix-sdk `Client`. This step gives
the shells one: find a server, sign in to it by browser or password, keep the
session across launches, and sign out. It is headless and fully tested, so
the Desktop and iOS steps only draw screens and implement two small traits.

## Goals

- Sign in to any homeserver by OAuth 2.0, SSO or password, behaving as main
  does (the rules below).
- Restore a stored session at start, signed in, with no network.
- Keep tokens in the platform keychain and the SDK store encrypted at rest.
- Sign out, wiping local data even when the server can't be reached.
- `SecretStore` and `AuthBrowser` defined, with fakes; every rule tested
  headless.

## Non-goals

| | Where it goes |
|---|---|
| Starting `SyncService`, sync state, MSC4186 | Sync and the room list (phase 2) |
| `trust` on `SignedIn` | Sync: device keys only load once sync runs, so it can't be correct before |
| `SoftLoggedOut` and `SessionRevoked` | Sync: they're detected on authenticated requests, and sync makes the first ones. Until then main's behaviour holds: a token the SDK can't refresh signs out |
| Removing the pusher on sign-out | iOS push |
| Clearing downloaded media on sign-out | Media |
| The SDK's cross-process refresh lock | The Notification Service Extension, the second process |
| Log files | The shells' steps; this step only emits `tracing` events |
| Screens, copy, platform `SecretStore`/`AuthBrowser` | Desktop and iOS steps |
| Verification, recovery | Their own feature |

## Approaches

| | Shape | Trade-off |
|---|---|---|
| **A (chosen)** | `SignInFlow` state machine over a crate-private `Homeserver` trait; the real one wraps matrix-sdk, a fake drives the flow tests | One trait and a fake (~100 lines) buy deterministic timing tests on paused tokio time |
| B | `SignInFlow` calls matrix-sdk directly; every test goes through matrix-sdk's mock server | Fewer types, but the mock server is a real socket on real time, so debounce, countdown and late-answer tests sleep and race |
| C | A, with discovery over hand-rolled HTTP | Only needed to tell discovery failures apart, which was dropped: one "couldn't reach" is enough |

Chris picked A, and matrix-sdk's mock server for the session tests.

## Public surface

```rust
let core = Core::start(CoreConfig {
    data_dir,                // matrix-sdk's store goes in data_dir/matrix
    device_name,             // shown to other sessions; the shell builds it
    platform: Platform { secrets, auth_browser },
}).await?;                   // Result<Arc<Core>, StartError>; restore is done

let session = core.session();
session.state()              // eyeball Subscriber<SessionState>
session.begin_sign_in()      // SignInFlow, only while SignedOut
session.sign_out().await     // never fails visibly
```

`Core::start` is async and resolves once restore has finished, so a shell
opens on the right screen with no flash of sign-in, as main does.

One flow at a time: `begin_sign_in()` makes any earlier `SignInFlow` inert
(its answers are dropped as stale), so two flows can never both commit.

`Platform` holds only the two traits this step needs; later features add
theirs. `Core` has only `session()` for now. Main's device names ("loaf on
<host>", "loaf on iPhone") are the shells' to build.

```rust
enum SessionState {
    SignedOut,
    SignedIn { user: UserId, device: DeviceId },
}
```

While a `SignInFlow` runs, `SessionState` stays `SignedOut`; the flow carries
its own state. The architecture spec's `SigningIn(step)` is therefore the
flow's state, not a session state.

## The sign-in flow

`begin_sign_in()` returns a `SignInFlow` that starts probing `loaf.moe` at
once. Its state is one observable:

```rust
struct SignInState {
    server: String,                 // as typed, never the delegated base URL
    check: ServerCheck,             // Probing | Found(WaysIn) | CouldntReach
    activity: Activity,             // Idle | InBrowser | CheckingPassword | SignedIn
    wrong_password: bool,
    retry_in: Option<Duration>,
    repointing: Option<String>,
    failure: Option<SignInFailure>,
}

struct WaysIn {
    browser: Vec<BrowserWay>,       // OAuth, or SSO identity providers
    password: bool,
}
```

Commands are plain methods that return at once; their outcome lands in the
state: `set_server(input)`, `retry()`, `username_changed(text)`,
`continue_with(way)`, `reopen_browser()`, `cancel_browser()`,
`sign_in_with_password(user, password)`. Dropping the flow cancels whatever it
has in flight.

### Rules (main's, unless marked)

**Server input.** `set_server` takes a name, a URL, or a full user id of which
only the domain is kept: trimmed, scheme and path stripped, lowercased, kept
only if it looks like a host (a dot with something either side, or
`localhost`; optional port; no spaces). Input that names no server is
ignored. Ports `serverNameFrom` and `serverFromUserId` as they are.

**Discovery** goes through matrix-sdk
(`ClientBuilder::server_name_or_homeserver_url`), then reads `/login` and
the OAuth server metadata. Any failure is `CouldntReach`. A server that
answers but offers no way loaf can use is `Found` with empty `WaysIn`.

**Ways in.**
- **OAuth 2.0** (Matrix v1.15) when the server publishes its metadata. It is
  then the only browser way, one "continue with <server>", and any
  `m.login.sso` providers are not shown *(new: main deferred OAuth; its
  design spec says it looks like this)*.
- Otherwise **SSO**, one `BrowserWay` per `identity_providers` entry, in the
  server's order, named by `name` or else `id`. `m.login.sso` listing no
  providers is one way named "single sign-on" with no provider id.
- **Password** wherever `/login` offers `m.login.password`.

**A full id in the username field** re-points the server once typing pauses
for 400 ms, if it names a different server and the flow is idle; the form
stays up and `repointing` names the server being probed. A password submitted
while a re-point is pending or in flight is held and sent once that server is
found, if it takes passwords.

**Password sign-in** does nothing unless idle, not rate-limited, and both the
trimmed username and the password are non-empty. It signs in as `m.id.user`
with the trimmed username and requests a refresh token.
- `M_FORBIDDEN` → `wrong_password`, back to idle.
- `M_LIMIT_EXCEEDED` → `retry_in` = `retry_after_ms` rounded up to whole
  seconds, at least 1 s, 30 s if the server names none, counting down once a
  second; sign-in is refused until it reaches zero. Changing server clears it.
- Any other error → `failure`. A new attempt clears `failure` and
  `wrong_password`.

**Browser sign-in.** `continue_with(way)` sets `InBrowser` and asks the
`AuthBrowser` for its redirect URI, then:
- OAuth: registers loaf as a public client dynamically (each sign-in; nothing
  cached), builds the authorization URL, and finishes from the callback.
- SSO: builds `/login/sso/redirect[/{idp}]` with the redirect, and signs in
  with the `loginToken` the callback carries (`m.login.token`).

`reopen_browser()` opens the pending page again (a no-op where the browser
is a modal sheet). `cancel_browser()` drops the attempt and returns to idle.
A browser that couldn't open is a failure; one the person closed is a quiet
cancel.

**Stale answers are dropped.** Every probe and attempt carries an epoch,
bumped by anything new: a server change, a cancel, a newer attempt, dropping
the flow. An answer from an older epoch changes nothing. If it was a
successful sign-in, its access token is logged out (best effort, 15 s
timeout), so no orphan device is left.

**The point of no return.** Once an attempt that is still current gets its
tokens, `activity` becomes `SignedIn` and stays there: cancel, `set_server`
and new attempts are ignored. If keeping the session then fails (below), the
token is logged out, `failure` is set, and the controls come back.

**Failures are typed.** The shell words them; main's copy is the reference:

| `SignInFailure` | Main's copy |
|---|---|
| `CouldntReach` | "couldn't reach <server>" |
| `Refused { message }` | "<server> said no: <message>" |
| `BrowserDidntOpen` | "couldn't open the sign-in page" |
| `ProviderDidntFinish { name }` | "<name> didn't finish signing you in" (a refused login token) |
| `CouldntFinish` | "couldn't finish signing in to <server>" |

`CouldntReach` as a `ServerCheck` is "couldn't reach <server>" too.

## Keeping the session

**Committing a sign-in.** Each attempt signs in on its own client, on a
fresh SQLite store in `data_dir/pending-<epoch>` with a random passphrase and
end-to-end encryption on. The device's encryption keys are made there, once,
and keep their identity through the commit. An abandoned attempt's store is
deleted. Once an attempt is current and has its tokens:
1. Write the session and the passphrase to `SecretStore`. A failed write
   fails the sign-in (`CouldntFinish`) rather than leave a session that can't
   be restored.
2. Close the attempt's client, move its store to `data_dir/matrix`, reopen
   it as the app's client with the session restored, and publish `SignedIn`.

What `SecretStore` holds: `session` (homeserver URL, user id, device id, and
either the access and refresh tokens or, for OAuth, the client id and its
tokens) and `store-passphrase`.

**Restoring at start.** Leftover `pending-*` stores are deleted. If `session`
is present, build the client on the store and restore it: `SignedIn` with no
network. A missing or corrupt `session`, or a store that won't restore, wipes
what's there and starts `SignedOut`. A `SecretStore` that errors (a keychain
not yet unlocked or not running) starts `SignedOut` *without* wiping, so the
next launch can still restore.

**Token refresh** is matrix-sdk's (`handle_refresh_tokens`). New tokens are
written to `SecretStore` as soon as the SDK reports them. A refresh in flight
never changes `SessionState`. If the SDK reports an unknown token after a
failed refresh, the core wipes local data and publishes `SignedOut`, as main
does.

**Signing out.** A second call while one is in flight does nothing. The core
logs out on the server (best effort, 15 s timeout), then always deletes
`data_dir/matrix` and both `SecretStore` entries and publishes `SignedOut`.
Signing in again afterwards starts clean. A wipe step that fails is logged
and the rest still run; since restore needs both the store and `session`,
losing either one means the next launch wipes the other.

## Platform traits

In `loaf-core::platform`, passed as `Arc<dyn Trait + Send + Sync>`.
Dyn-compatible async; the plan picks `async-trait` or boxed futures, whichever
UniFFI's foreign traits need for the iOS step.

```rust
trait SecretStore {
    async fn get(&self, key: &str) -> Result<Option<String>, SecretStoreError>;
    async fn set(&self, key: &str, value: &str) -> Result<(), SecretStoreError>;
    async fn delete(&self, key: &str) -> Result<(), SecretStoreError>;
}

trait AuthBrowser {
    /// Where the provider sends the browser back to. Desktop binds its
    /// loopback listener here, so the port is known; Apple returns its
    /// callback scheme.
    async fn redirect_uri(&self) -> Result<Url, AuthBrowserError>;
    /// Opens `url` and resolves with the URL the browser came back to.
    async fn authenticate(&self, url: Url) -> Result<Url, AuthBrowserError>;
    /// Opens the pending page again, where that means anything.
    fn reopen(&self);
    /// Gives up on a pending `authenticate`, which resolves `Cancelled`.
    fn cancel(&self);
}

enum AuthBrowserError { Cancelled, CouldntOpen }
```

This refines the architecture spec's
`authenticate(url, callback) -> Result<Url, AuthCancelled>`: the loopback
port isn't known until the listener binds, and main's "open it again" needs
`reopen`.

## Inside

- `session/flow.rs`: `SignInFlow`, its state, epochs, debounce and countdown.
- `session/homeserver.rs`: the crate-private `Homeserver` trait (probe,
  password, browser sign-in) and its matrix-sdk implementation.
- `session/store.rs`: committing, restoring, refresh persistence, sign-out.
- `platform/`: the two traits.

SDK and platform errors are mapped to the types above at this boundary; no
matrix-sdk type is public. The lint policy from the scaffold (PR #24) applies.
Tokens, passwords and the store passphrase are never logged; a test captures
the `tracing` output of a full sign-in, refresh and sign-out and checks.

**Dependencies:** `matrix-sdk` 0.19.1 (`sqlite`, `e2e-encryption`), `tokio`,
`eyeball`, `thiserror`, `tracing`, `url`; dev: `matrix-sdk`'s `testing`
feature (its mock server). No `matrix-sdk-ui` yet: nothing here uses it.

## Fakes

`FakeSecretStore` (in memory; can be told to fail the next write) and
`FakeAuthBrowser` (scripted redirect and callback, or cancel, or fails to
open; records reopen and cancel). `FakeHomeserver` is crate-private. All are
`#[cfg(test)]` for now; they become public when a shell's tests need them.

## Tests

Unit tests with the fakes on paused tokio time, and the session tests on
matrix-sdk's mock server. The plan ports main's tests by name:

**`test/sign_in_controller_test.dart`** → `SignInFlow` over `FakeHomeserver`.
All of it, with these changes: "each failure is its own problem" becomes one
`CouldntReach`; "a computer waits on the browser" and "a phone finishes in the
system sheet" become one `InBrowser` test; "the failure lever turns a right
password away once" is dropped (main's debug lever for the mock).

**`test/sign_in_state_test.dart`** → the server-input parsing tests, all of
them; "each discovery failure says something different" is dropped (one
failure now). "The fixture servers cover every face" and "a provider without
an icon falls back to its initial" are mock and UI concerns and are not ported.

**`test/matrix/matrix_session_test.dart`** → on the mock server: a fresh
store is signed out; signing in signs the session in; signing out signs it
out; signing in again after signing out works; a second sign-out in flight
does nothing; a failed store open inside sign-in is a failure, not a panic; a
token refresh in flight does not sign out; the device keys made at sign-in
are the ones the restored client has. Not ported here: "keys not yet
known never read as no identity" (trust, with sync), "signing out clears
downloaded media" (media), "device names say where they are" (the shells).

**New, for behaviour main didn't have:** OAuth discovery hides SSO
providers; an OAuth sign-in completes through `FakeAuthBrowser`; a failed
`SecretStore` write fails sign-in and logs the token out; a stored session
restores signed in with the mock server offline; a `SecretStore` error at
start signs out without wiping; a second `begin_sign_in()` makes the first
flow inert; refreshed tokens reach
`SecretStore`; secrets never appear in logs.

**`test/session_root_test.dart`** and **`test/login_page_test.dart`** are
screen tests and belong to the Desktop and iOS steps.

## Left to the plan

Exact matrix-sdk calls (checked against 0.19.1's docs, not assumed), the
OAuth client metadata (`client_name`, `client_uri`) and how each shell's
redirect URI satisfies the OAuth rules for native clients, the serialisation
of `session` in `SecretStore`, and how the fakes script timing.
