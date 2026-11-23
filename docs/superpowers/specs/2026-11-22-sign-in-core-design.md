# Sign-in and session: Core

Phase 1, step 1 of the rewrite (architecture spec, "Order of work"): the
session area of `loaf-core`, the Matrix port for sign-in and session, the
`SecretStore` and `AuthBrowser` ports, a fake for each, and the Matrix
adapter over matrix-sdk. Desktop, iOS and CI are later steps with their own
specs; this one defines only the ports they implement and the API they call.

Built from scratch: the Dart app is not a reference. The rules below are
this design's own, on the Matrix spec.

## Why

Every later feature needs a signed-in matrix-sdk `Client`. This step gives
the shells one: find a server, sign in to it by browser or password, keep the
session across launches, and sign out. It is headless and fully tested, so
the Desktop and iOS steps only draw screens and implement two small ports.

## Goals

- Sign in to any homeserver by OAuth 2.0, SSO or password, by the rules
  below.
- Restore a stored session at start, signed in, with no network.
- Keep tokens in the platform keychain and the SDK store encrypted at rest.
- Sign out, wiping local data even when the server can't be reached.
- The Matrix, `SecretStore` and `AuthBrowser` ports defined, each with a
  fake; every rule tested headless against the fakes, and the Matrix adapter
  tested on matrix-sdk's mock server.

## Non-goals

| | Where it goes |
|---|---|
| Starting `SyncService`, sync state, MSC4186 | Sync and the room list (phase 2) |
| `trust` on `SignedIn` | Sync: device keys only load once sync runs, so it can't be correct before |
| `SoftLoggedOut` and `SessionRevoked` | Sync: they're detected on authenticated requests, and sync makes the first ones. Until then a token the SDK can't refresh signs out |
| Removing the pusher on sign-out | iOS push |
| Clearing downloaded media on sign-out | Media |
| The SDK's cross-process refresh lock | The Notification Service Extension, the second process |
| Log files | The shells' steps; this step only emits `tracing` events |
| Screens, copy, device names, platform `SecretStore`/`AuthBrowser` | Desktop and iOS steps |
| Verification, recovery | Their own feature |

## Approaches

| | Shape | Trade-off |
|---|---|---|
| **A (chosen)** | `SignInFlow` and session keeping over a Matrix port; the adapter wraps matrix-sdk, a fake drives the logic tests | A trait and a fake buy deterministic timing tests on paused tokio time |
| B | `SignInFlow` calls matrix-sdk directly; every test goes through matrix-sdk's mock server | Fewer types, but the mock server is a real socket on real time, so debounce, countdown and late-answer tests sleep and race |
| C | A, with discovery over hand-rolled HTTP | Only needed to tell discovery failures apart, which isn't wanted: one "couldn't reach" is enough |

Chris picked A, and matrix-sdk's mock server for the adapter's tests. The
architecture spec has since made A the rule for every I/O ("Ports and
adapters").

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
opens on the right screen with no flash of sign-in.

One flow at a time: `begin_sign_in()` makes any earlier `SignInFlow` inert
(its answers are dropped as stale), so two flows can never both commit.

`Platform` holds only the two platform ports this step needs; later features
add theirs. `Core::start` builds the Matrix adapter from `data_dir`; tests
start the core with the Matrix fake instead. `Core` has only `session()` for
now.

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
    check: ServerCheck,             // Probing | Found(AuthMethods) | CouldntReach
    activity: Activity,             // Idle | InBrowser | CheckingPassword | SignedIn
    wrong_password: bool,
    retry_in: Option<Duration>,
    repointing: Option<String>,
    failure: Option<SignInFailure>,
}

struct AuthMethods {
    browser: Vec<BrowserMethod>,    // OAuth, or SSO identity providers
    password: bool,
}
```

Commands are plain methods that return at once; their outcome lands in the
state: `set_server(input)`, `retry()`, `username_changed(text)`,
`continue_with(method)`, `reopen_browser()`, `cancel_browser()`,
`sign_in_with_password(user, password)`. Dropping the flow cancels whatever it
has in flight.

### Rules

**Server input.** `set_server` takes a server name, a URL, or a full user id.
It keeps only the host (with any port), lowercased: from a URL, the authority;
from a user id, the part after the first `:`. Input with no plausible host
yet (empty, no dot and not `localhost`, containing spaces) is ignored, since
half-typed input is normal.

**Discovery** goes through the Matrix port; the adapter resolves the server
with matrix-sdk and reads `/login` and the OAuth server metadata. Any failure
is `CouldntReach`. A server that
answers but offers no method loaf can use is `Found` with empty `AuthMethods`.

**Authentication methods.**
- **OAuth 2.0** (Matrix v1.15) when the server publishes its metadata. It is
  then the only browser method, one "continue with <server>", and any
  `m.login.sso` providers are not shown.
- Otherwise **SSO**, one `BrowserMethod` per `identity_providers` entry, in the
  server's order, named by `name` or else `id`. `m.login.sso` listing no
  providers is one method with no provider id.
- **Password** wherever `/login` offers `m.login.password`.

**A full user id in the username field** re-points the server once typing
pauses for 400 ms, if it names a different server and the flow is idle; the
form stays up and `repointing` names the server being probed. A password
submitted while a re-point is pending or in flight is held and sent once that
server is found, if it takes passwords, so it never goes to the old server.

**Password sign-in** does nothing unless idle, not rate-limited, and both the
trimmed username and the password are non-empty. It signs in as `m.id.user`
with the trimmed username and requests a refresh token.
- `M_FORBIDDEN` → `wrong_password`, back to idle.
- `M_LIMIT_EXCEEDED` → `retry_in` = `retry_after_ms` rounded up to whole
  seconds, at least 1 s, 30 s if the server names none, counting down once a
  second; sign-in is refused until it reaches zero. Changing server clears it.
- Any other error → `failure`. A new attempt clears `failure` and
  `wrong_password`.

**Browser sign-in.** `continue_with(method)` sets `InBrowser` and asks the
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

**Failures are typed** so the shells word them without parsing text:
`CouldntReach`, `Refused { message }` (the server's own error text),
`BrowserDidntOpen`, `ProviderDidntFinish { name }` (the server refused the
login token), `CouldntFinish` (keeping the session failed).

## Keeping the session

**Committing a sign-in.** Each attempt signs in on its own client, on a
fresh SQLite store in `data_dir/pending-<epoch>` with end-to-end encryption
on, encrypted with a random passphrase the core makes. The device's
encryption keys are made there, once, and keep their identity through the
commit. An abandoned attempt's store is deleted. Once an attempt is current
and has its tokens:
1. Write the session and the passphrase to `SecretStore`. A failed write
   fails the sign-in (`CouldntFinish`) rather than leave a session that can't
   be restored.
2. Commit the attempt through the Matrix port: the adapter closes its client,
   moves its store to `data_dir/matrix`, and reopens it as the account with
   the session restored. Then publish `SignedIn`.

What `SecretStore` holds: `session` (homeserver URL, user id, device id, and
either the access and refresh tokens or, for OAuth, the client id and its
tokens) and `store-passphrase`.

**Restoring at start.** Leftover `pending-*` stores are deleted. If `session`
is present, build the client on the store and restore it: `SignedIn` with no
network. A missing or corrupt `session`, or a store that won't restore, wipes
what's there and starts `SignedOut`. A `SecretStore` that errors (a keychain
not yet unlocked or not running) starts `SignedOut` *without* wiping, so the
next launch can still restore.

**Token refresh** is matrix-sdk's (`handle_refresh_tokens`). The adapter
reports new tokens on the account's session changes, and the core writes them
to `SecretStore` at once. A refresh in flight never changes `SessionState`. If
the adapter reports a token that couldn't be refreshed, the core wipes local
data and publishes `SignedOut`.

**Signing out.** A second call while one is in flight does nothing. The core
logs out on the server (best effort, 15 s timeout), then always deletes
`data_dir/matrix` and both `SecretStore` entries and publishes `SignedOut`.
Signing in again afterwards starts clean. A wipe step that fails is logged
and the rest still run; since restore needs both the store and `session`,
losing either one means the next launch wipes the other.

## Ports

In `loaf-core::ports`, each a small trait in the core's own types, held as
`Arc<dyn Trait + Send + Sync>`. Dyn-compatible async; the plan picks
`async-trait` or boxed futures, whichever UniFFI's foreign traits need for
the iOS step.

### Matrix

What sign-in and session need from a homeserver, and nothing else. Its parts:

- **Probe** a server name: its `AuthMethods`, or `Unreachable`. A found
  server comes back as an attempt, with its pending store opened under the
  passphrase the core passes in.
- **On an attempt:** sign in with a password (wrong password, rate limit
  with its delay, or the server's refusal text); build the browser URL for a
  `BrowserMethod` and redirect URI; finish from the callback URL (or the
  login token refused); commit, which yields the account; discard, which
  logs out any token it got (15 s) and deletes its store.
- **Restore** the account from a stored session and passphrase, with no
  network, or say the store won't restore.
- **On the account:** session changes (new tokens, or a token that couldn't
  be refreshed) and server logout.
- **Wipe** `data_dir/matrix`.

The stored session (homeserver URL, user id, device id, tokens, and the
OAuth client id where used) is a core type the adapter fills; the core
serialises it into `SecretStore`. The adapter maps matrix-sdk's types and
errors into these; nothing above it sees the SDK. The plan sets the exact
signatures.

### Platform

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
port isn't known until the listener binds, and "open it again" needs
`reopen`.

## Inside

- `session/flow.rs`: `SignInFlow`, its state, epochs, debounce and countdown.
- `session/keeping.rs`: committing, restoring, refresh persistence, sign-out.
- `ports/`: the Matrix, `SecretStore` and `AuthBrowser` ports.
- `matrix/`: the Matrix adapter over matrix-sdk.

The adapter maps SDK errors into port errors; the session area maps port
errors into the types above. The scaffold's lint policy applies. Tokens,
passwords and the store passphrase are never logged.

**Dependencies:** `matrix-sdk` 0.19.1 (`sqlite`, `e2e-encryption`), `tokio`,
`eyeball`, `thiserror`, `tracing`, `url`; dev: `matrix-sdk`'s `testing`
feature (its mock server). No `matrix-sdk-ui` yet: nothing here uses it.

## Fakes

`FakeMatrix` (scripted probe answers, sign-in results and session changes,
each answering when the test says; records commits, discards, logouts and
wipes), `FakeSecretStore` (in memory; can be told to fail) and
`FakeAuthBrowser` (scripted redirect and callback, or cancel, or fails to
open; records reopen and cancel). All are `#[cfg(test)]` for now; they become
public when a shell's tests need them.

## Tests

Written from the rules above. The flow and session keeping run over the
three fakes on paused tokio time. The Matrix adapter runs on matrix-sdk's
mock server. Each rule gets at least one test; these are the cases the plan
must cover:

**Server input:** names, URLs and user ids each give the host; ports are
kept; case and whitespace are normalised; every prefix of a typed name,
URL or id either gives nothing or a plausible host, never an error.

**Discovery and methods:** the flow opens probing `loaf.moe`; a found server
publishes its methods; any failure is `CouldntReach`, and `retry()` probes
again; OAuth hides SSO providers; SSO providers keep the server's order and
fall back to their id for a name; no providers is one method; password shows
only when offered; no usable method is `Found` with nothing in it.

**Re-pointing:** a full user id re-points after 400 ms of quiet, not before;
a plain username leaves the server alone; a password submitted inside the
debounce or during the re-point probe goes to the new server.

**Password:** right credentials sign in; empty fields do nothing;
`M_FORBIDDEN` sets `wrong_password`; `M_LIMIT_EXCEEDED` counts down by the
second and refuses sign-in until zero; the 30 s default and the 1 s minimum;
changing server clears the countdown; other errors set `failure`, which the
next attempt clears.

**Browser:** SSO and OAuth each sign in through `FakeAuthBrowser`;
`reopen_browser()` reaches the browser; cancel returns to idle and drops a
late answer; a browser that won't open is `BrowserDidntOpen`; a refused login
token is `ProviderDidntFinish`.

**Staleness and the point of no return:** an answer to an old probe is
dropped; a sign-in answering after cancel or a server change never signs in,
and its token is logged out; after commit, cancel and `set_server` are
ignored; a commit that fails brings the controls back; a second
`begin_sign_in()` makes the first flow inert.

**Keeping the session:** nothing stored starts signed out; signing in
publishes `SignedIn`; a stored session restores signed in; a failed
`SecretStore` write fails sign-in and discards the attempt; a `SecretStore`
error at start signs out without wiping; a corrupt `session` or a store that
won't restore wipes; refreshed tokens reach `SecretStore`; a refresh in
flight never signs out; an unrefreshable token signs out and wipes; signing
out wipes even when server logout fails; a second sign-out in flight does
nothing; signing in again after signing out works.

**The Matrix adapter** (mock server): probing reports OAuth, SSO providers
and password as the server offers them, and an unreachable server; password,
SSO and OAuth sign-ins each finish; a forbidden and a rate-limited password
map to their port errors; a refused login token maps to its error; a
discarded attempt logs out and leaves no store; a committed attempt restores
from `data_dir/matrix` with the server unreachable and keeps the device keys
made at sign-in; refreshed tokens and an unrefreshable token are reported;
wipe leaves no store.

**Logs:** the `tracing` output of a full sign-in, refresh and sign-out
contains no token, password or passphrase.

## Left to the plan

Exact matrix-sdk calls (checked against 0.19.1's docs, not assumed), the
OAuth client metadata (`client_name`, `client_uri`) and how each shell's
redirect URI satisfies the OAuth rules for native clients, the serialisation
of `session` in `SecretStore`, and how the fakes script timing.
