//! Every way discovery and signing in can fail, as types a UI matches on.
//! Each outcome a UI would handle differently has its own variant; anything
//! without one still arrives whole.

use core::time::Duration;

use crate::ports::auth_browser::AuthBrowserError;
use crate::ports::secret_store::SecretStoreError;

/// Why `discover` found no server.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum DiscoverError {
    #[error("that isn't a server name")]
    NotAServer,
    #[error(transparent)]
    CouldntReach(#[from] Unreachable),
    #[error("an account is already signed in")]
    NotSignedOut,
}

/// Why a password sign-in didn't sign in.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PasswordError {
    #[error("another sign-in is running")]
    Busy,
    #[error("an account is already signed in")]
    NotSignedOut,
    /// A field was empty, so nothing was sent.
    #[error("enter a username and password")]
    Empty(EmptyFields),
    /// `M_FORBIDDEN`.
    #[error("wrong username or password")]
    WrongPassword,
    /// `M_INVALID_USERNAME`.
    #[error("that isn't a valid username")]
    InvalidUsername,
    /// The account can't sign in, whatever the password.
    #[error(transparent)]
    Account(#[from] AccountError),
    /// `M_LIMIT_EXCEEDED`: try again after `retry_after`, whole seconds and at least one.
    #[error("too many attempts; try again in {} s", retry_after.as_secs())]
    RateLimited { retry_after: Duration },
    /// Any other answer, kept whole: the `errcode` (or the HTTP status for a
    /// body that isn't a Matrix error) and the server's own text.
    #[error("sign-in refused: {message} ({code})")]
    Refused { code: String, message: String },
    #[error(transparent)]
    CouldntReach(#[from] Unreachable),
    /// The server may have accepted, but nothing was kept and any token was logged out.
    #[error(transparent)]
    CouldntFinish(#[from] FinishError),
}

/// Why a browser sign-in didn't sign in.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum BrowserError {
    #[error("another sign-in is running")]
    Busy,
    #[error("an account is already signed in")]
    NotSignedOut,
    /// The person closed the browser.
    #[error("the browser was closed")]
    Cancelled,
    #[error("the browser couldn't be opened")]
    BrowserDidntOpen,
    /// The person declined on the provider's page (OAuth `access_denied`).
    #[error("sign-in was declined")]
    Declined,
    /// The server wouldn't register loaf as an OAuth client: it doesn't offer
    /// dynamic registration, or it refused loaf's metadata.
    #[error("the server wouldn't register this app")]
    RegistrationRefused,
    /// The account can't sign in, whichever way it tries.
    #[error(transparent)]
    Account(#[from] AccountError),
    /// The server refused what the provider sent back: a login token or
    /// authorization code, or a callback that doesn't match the request.
    #[error("the provider didn't finish signing in")]
    ProviderDidntFinish,
    #[error(transparent)]
    CouldntReach(#[from] Unreachable),
    /// The server may have accepted, but nothing was kept and any token was logged out.
    #[error(transparent)]
    CouldntFinish(#[from] FinishError),
}

impl From<AuthBrowserError> for BrowserError {
    fn from(error: AuthBrowserError) -> Self {
        match error {
            AuthBrowserError::Cancelled => Self::Cancelled,
            AuthBrowserError::CouldntOpen => Self::BrowserDidntOpen,
        }
    }
}

/// Which fields of a password sign-in were empty.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EmptyFields {
    Username,
    Password,
    Both,
}

impl EmptyFields {
    /// Which of `user` (trimmed) and `password` are empty; `None` when neither is.
    #[must_use]
    pub fn of(user: &str, password: &str) -> Option<Self> {
        match (user.trim().is_empty(), password.is_empty()) {
            (true, true) => Some(Self::Both),
            (true, false) => Some(Self::Username),
            (false, true) => Some(Self::Password),
            (false, false) => None,
        }
    }
}

/// What the server said about the account itself, the same for every way of
/// signing in.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum AccountError {
    /// `M_USER_DEACTIVATED`: the account is gone for good.
    #[error("this account has been deactivated")]
    Deactivated,
    /// `M_USER_LOCKED`: the server's admins locked it; it may be unlocked.
    #[error("this account is locked")]
    Locked,
    /// `M_RESOURCE_LIMIT_EXCEEDED`: the server is at a limit, such as its
    /// monthly active users; `admin_contact` is a URI for its admins.
    #[error("the server is at its limit; contact {admin_contact}")]
    ServerFull { admin_contact: String },
}

/// Why the server gave no Matrix answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum Unreachable {
    /// No connection: the name didn't resolve, nothing answered, or TLS failed.
    #[error("couldn't connect to the server")]
    Connect,
    /// The server didn't answer in time.
    #[error("the server didn't answer in time")]
    Timeout,
    /// Something answered, but not with a Matrix answer loaf could read: a
    /// web server that isn't a homeserver, or a malformed reply.
    #[error("that isn't a Matrix server")]
    NotMatrix,
    /// The server answered with an error status, such as a 502 from its proxy.
    #[error("the server answered with HTTP {code}")]
    Status { code: u16 },
}

/// Why a sign-in the server may have accepted couldn't be kept on this device.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum FinishError {
    /// matrix-sdk failed on this device: opening its store or setting up the
    /// session in it. `message` is its own text.
    #[error("couldn't set up the session on this device: {message}")]
    Sdk { message: String },
    /// The platform's secret store wouldn't take the session.
    #[error("couldn't store the session: {0}")]
    Secrets(#[from] SecretStoreError),
}
