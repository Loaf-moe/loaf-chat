# Sign-in and session: Core

Phase 1, step 1 of the rewrite (architecture spec, "Order of work"): the
session area of `loaf-core` over matrix-sdk, plus the `SecretStore` and
`AuthBrowser` platform ports with a test double for each. Desktop, iOS and CI
are later steps with their own specs; this one defines only the API they call
and the two ports they implement.

Built from scratch: the Dart app is not a reference. The rules below are
this design's own, on the Matrix spec.

## Why

Every later feature needs a signed-in matrix-sdk `Client`. This step gives
the shells one: find a server, sign in to it by browser or password, keep the
session across launches, and sign out.

## Shape

The core answers questions and makes transitions. It reports valid state and
offers only the transitions that state allows; its types rule out the rest.
It does no waiting or queuing for the UI: debouncing input, counting down a
rate limit, re-pointing to the server in a typed user id, and cancelling are
the UI's job. The UI reacts to state and calls transitions.

matrix-sdk is used directly. It is tested on its own mock server
(`MatrixMockServer`, feature `testing`), so the core has no Matrix trait of
its own.

## Goals

- Sign in to any homeserver by OAuth 2.0, SSO or password.
- Make invalid sign-ins unrepresentable: no sign-in before discovery, no
  password on a server that doesn't take one, OAuth and SSO never offered
  together.
- Restore a stored session at start, signed in, with no network.
- Keep tokens in the platform keychain and the SDK store encrypted at rest.
- Sign out, wiping local data even when the server can't be reached.

## Non-goals

| | Where it goes |
|---|---|
| Debounce, countdown, re-pointing from a typed user id, cancel buttons | The shells: they react to the state and errors below |
| Starting `SyncService`, sync state, MSC4186 | Sync and the room list (phase 2) |
| `trust` on `SignedIn` | Sync: device keys only load once sync runs |
| `SoftLoggedOut` and `SessionRevoked` | Sync: they're detected on authenticated requests. Until then a token the SDK can't refresh signs out |
| Removing the pusher on sign-out | iOS push |
| Clearing downloaded media on sign-out | Media |
| The SDK's cross-process refresh lock | The Notification Service Extension |
| Log files | The shells' steps; this step only emits `tracing` events |
| Screens, copy, device names, platform `SecretStore`/`AuthBrowser` | Desktop and iOS steps |
| `Arc` wrapping of the handles for Swift | `loaf-ffi`, in the iOS step |

## Public surface

```rust
let core = Core::start(CoreConfig {
    data_dir,                // matrix-sdk's store goes in data_dir/matrix
    device_name,             // shown to other sessions; the shell builds it
    platform: Platform { secrets, auth_browser },
}).await?;                   // Result<Arc<Core>, StartError>; restore is done

let session = core.session();
session.state()              // eyeball Subscriber<SessionState>; first next() is the current state
session.discover(input).await        // Result<Server, DiscoverError>
session.sign_out().await             // never fails visibly

server.name()                // the host as typed, never the delegated base URL
server.password()            // Option<PasswordSignIn>
server.browser()             // Vec<BrowserSignIn>

password.sign_in(user, password).await   // Result<(), Failed<PasswordSignIn, PasswordError>>
browser.name()                            // provider name, or the server's for OAuth
browser.sign_in().await                   // Result<(), Failed<BrowserSignIn, BrowserError>>

server_in_user_id(text)      // Option<String>: the server a full user id names
```

```rust
enum SessionState {
    SignedOut,
    SignedIn { user: UserId, device: DeviceId },
}

/// A failed sign-in hands its handle back, so the UI can try again.
struct Failed<H, E> { pub handle: H, pub error: E }
```

`Core::start` is async and resolves once restore has finished, so a shell
opens on the right screen with no flash of sign-in. `Core` has only
`session()` for now.

**Handles are moves.** `sign_in` takes `self`: success consumes the handle,
failure returns it in `Failed`. The `Server` and its handles are plain values;
the UI drops what it no longer needs. Dropping a `sign_in` future cancels it.
For Swift, `loaf-ffi` wraps each handle (iOS step).

## Rules

**Server input.** `discover` takes a server name, a URL, or a full user id.
It keeps only the host (with any port as typed), lowercased: from a URL, the
authority; from a user id, the part after the first `:`. Input with no
plausible host (empty, no dot and not `localhost`, containing spaces) is
`DiscoverError::NotAServer`, with no network call.

**Discovery** resolves the server with matrix-sdk and reads `/login` and the
OAuth server metadata, on a client with no store. Any failure is
`CouldntReach`. A server that answers but offers no method loaf can use is a
`Server` with no password and no browser methods. `discover` while signed in
is `NotSignedOut`.

**Authentication methods.**
- **OAuth 2.0** (Matrix v1.15) when the server publishes its metadata. It is
  then the only browser method, named after the server, and any
  `m.login.sso` providers are not offered.
- Otherwise **SSO**, one `BrowserSignIn` per `identity_providers` entry, in
  the server's order, named by `name` or else `id`. `m.login.sso` listing no
  providers is one method, named after the server, with no provider id.
- **Password** wherever `/login` offers `m.login.password`.

**One sign-in at a time.** A `sign_in` that starts while another is running
fails at once with `Busy`, and one that starts while signed in fails with
`NotSignedOut`. Nothing waits.

**Password sign-in** signs in as `m.id.user` with the trimmed username and
requests a refresh token. An empty trimmed username or empty password is
`Refused` without a network call.
- `M_FORBIDDEN` → `WrongPassword`.
- `M_LIMIT_EXCEEDED` → `RateLimited { retry_after }`: the server's delay
  (`retry_after_ms`, or the `Retry-After` header as a delay or a date)
  rounded up to whole seconds, at least 1 s, 30 s if it names none. The SDK's
  own retrying is off on sign-in clients, so the limit reaches the UI.
- Other server errors → `Refused { message }` (the server's own text);
  a server that can't be reached → `CouldntReach`.

**Browser sign-in** asks the `AuthBrowser` for its redirect URI, then:
- OAuth: registers loaf as a public client dynamically (each sign-in;
  nothing cached), opens the authorization URL, and finishes from the
  callback.
- SSO: opens `/login/sso/redirect[/{idp}]` with the redirect, and signs in
  with the `loginToken` the callback carries (`m.login.token`).

A browser the person closed is `Cancelled`; one that couldn't open is
`BrowserDidntOpen`; a login token or authorization code the server refused is
`ProviderDidntFinish { name }`.

**OAuth client metadata:** `application_type: native`, `client_name: "Loaf
Chat"`, `client_uri: https://loaf.moe`, the authorization-code grant with the
redirect URI. A loopback redirect (`127.0.0.1`, `[::1]`, `localhost`) is
registered without its port, as the Matrix spec requires of native clients;
the authorization request uses the port. The shells' redirects: desktop
`http://127.0.0.1:<port>/callback`; Apple `moe.loaf.chat:/callback`.

## Keeping the session

**Signing in.** A sign-in first wipes `data_dir/matrix` (the session is
signed out, so nothing there is kept), then signs in on a client with its
SQLite store there, end-to-end encryption on, encrypted with a fresh random
passphrase. The device's keys are made there at sign-in. Once the server
accepts:
1. Write the session and the passphrase to `SecretStore`. A failed write
   logs the token out (best effort, 15 s), wipes the store and is
   `CouldntFinish`, rather than leave a session that can't be restored.
2. Publish `SignedIn`.

Any other failure wipes the store before returning. A sign-in dropped
mid-way leaves a store with no `session` secret, which the next sign-in or
start wipes.

What `SecretStore` holds: `session` (homeserver URL, user id, device id, and
either the access and refresh tokens or, for OAuth, the client id and its
tokens) as JSON, and `store-passphrase`.

**Restoring at start.** If `session` is present, build the client on the
store and restore it: `SignedIn` with no network. A missing or corrupt
`session` or passphrase, or a store that won't restore, wipes what's there
and starts `SignedOut`. A `SecretStore` that errors (a keychain not yet
unlocked or not running) starts `SignedOut` *without* wiping, so the next
launch can still restore.

**Token refresh** is matrix-sdk's (`handle_refresh_tokens`). On the client's
session changes, refreshed tokens are written to `SecretStore` at once; a
token that couldn't be refreshed wipes local data and publishes `SignedOut`.
A refresh in flight never changes `SessionState`.

**Signing out.** A second call while one is in flight does nothing. The core
logs out on the server (best effort, 15 s timeout), then always deletes
`data_dir/matrix` and both `SecretStore` entries and publishes `SignedOut`. A
wipe step that fails is logged and the rest still run.

## Platform ports

In `loaf-core::ports`, held as `Arc<dyn Trait + Send + Sync>`, using
`async-trait` (UniFFI's documented form for async traits). They exist because
the keychain and the system browser differ per platform and matrix-sdk
provides neither.

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
    /// Dropping the future closes the pending page.
    async fn authenticate(&self, url: Url) -> Result<Url, AuthBrowserError>;
}

enum AuthBrowserError { Cancelled, CouldntOpen }
```

## Inside

- `session.rs`: `Session`, `SessionState`, ids, `discover`.
- `session/server.rs`: input parsing and the method rules (pure).
- `session/sign_in.rs`: `Server`, `PasswordSignIn`, `BrowserSignIn`, errors.
- `session/keeping.rs`: committing, restore, refresh persistence, sign-out.
- `session/stored.rs`: the `session` secret.
- `ports/`: `SecretStore`, `AuthBrowser`.

SDK errors are mapped to the error enums above in one place. The scaffold's
lint policy applies. Tokens, passwords and the store passphrase are never
logged.

**Dependencies:** `matrix-sdk` 0.19.1 (`e2e-encryption`, `sqlite`,
`bundled-sqlite`, `rustls-aws-lc-rs`, defaults off), `tokio`, `eyeball`,
`thiserror`, `tracing`, `url`, `serde`/`serde_json`, `rand`, `async-trait`;
dev: `matrix-sdk`'s `testing` feature, `wiremock`, `tempfile`,
`tracing-subscriber`.

## Tests

Against `MatrixMockServer` with real clients on temp dirs, plus in-memory
doubles for `SecretStore` and `AuthBrowser` (`#[cfg(test)]`). Each rule gets
at least one test:

**Server input:** names, URLs and user ids give the host; ports are kept as
typed; case and whitespace normalised; every prefix of a typed name, URL or
id gives `NotAServer` or a plausible host, never a panic.

**Discovery and methods:** a found server reports OAuth, SSO providers and
password as offered; OAuth hides SSO; SSO keeps the server's order and falls
back to the id for a name; no providers is one method; password only when
offered; an unreachable server is `CouldntReach`; discover while signed in
is `NotSignedOut`.

**Password:** right credentials sign in and publish `SignedIn`; empty fields
are refused without a request; `M_FORBIDDEN` is `WrongPassword` and hands the
handle back; `M_LIMIT_EXCEEDED` is `RateLimited` with the rounding above (and
the request is made once); other errors are `Refused`.

**Browser:** SSO and OAuth each sign in through the `AuthBrowser` double; a
closed browser is `Cancelled`; one that won't open is `BrowserDidntOpen`; a
refused login token is `ProviderDidntFinish`; OAuth retried after a cancel
signs in; a loopback redirect registers without its port.

**One at a time:** a sign-in during another is `Busy`; a sign-in after
success with another handle is `NotSignedOut`.

**Keeping the session:** nothing stored starts signed out; a stored session
restores signed in with the server unreachable and keeps the device keys
made at sign-in; a failed `SecretStore` write fails sign-in, logs out and
wipes; a `SecretStore` error at start signs out without wiping; a corrupt
session or a store that won't restore wipes; refreshed tokens reach
`SecretStore`; an unrefreshable token signs out and wipes; signing out wipes
even when server logout fails; a second sign-out in flight does nothing;
signing in again after signing out works.

**Logs:** the `tracing` output of a full sign-in, refresh and sign-out
contains no token, password or passphrase.
