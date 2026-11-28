//! The one place that touches matrix-sdk's types: building clients, probing
//! a server, the browser sign-ins, and converting SDK errors and sessions
//! into the core's own types.

use core::error::Error;
use core::iter::{empty, successors};
use core::time::Duration;
use std::path::Path;
use std::time::SystemTime;

use matrix_sdk::authentication::matrix::MatrixSession;
use matrix_sdk::authentication::oauth::error::{OAuthAuthorizationCodeError, OAuthDiscoveryError};
use matrix_sdk::authentication::oauth::registration::{ApplicationType, ClientMetadata, Localized, OAuthGrantType};
use matrix_sdk::authentication::oauth::{ClientId, ClientRegistrationData, OAuthError, OAuthSession, UserSession};
use matrix_sdk::config::RequestConfig;
use matrix_sdk::reqwest::{self, StatusCode};
use matrix_sdk::ruma::api::client::session::get_login_types::v3::LoginType;
use matrix_sdk::ruma::api::client::session::login::{
    self,
    v3::{LoginInfo, Password, Token},
};
use matrix_sdk::ruma::api::client::uiaa::{MatrixUserIdentifier, UserIdentifier};
use matrix_sdk::ruma::api::error::{ErrorBody, ErrorKind, RetryAfter};
use matrix_sdk::ruma::serde::Raw;
use matrix_sdk::ruma::{OwnedDeviceId, OwnedUserId, UserId as SdkUserId};
use matrix_sdk::store::RoomLoadSettings;
use matrix_sdk::{AuthSession, Client, ClientBuildError, HttpError, SessionMeta, SessionTokens};
use url::{Host, Url};

use super::UserId;
use super::error::{AccountError, BrowserError, FinishError, PasswordError, Unreachable};
use super::server::{IdentityProvider, ServerOffer};
use super::stored::{CorruptSession, StoredAuth, StoredSession};
use crate::ports::auth_browser::AuthBrowser;

/// How long a rate limit lasts when the server doesn't say.
const DEFAULT_RETRY_AFTER: Duration = Duration::from_secs(30);

/// The query parameter an SSO callback carries the login token in.
const LOGIN_TOKEN_PARAM: &str = "loginToken";

/// Sign-in requests fail at once, so a rate limit reaches the UI instead of
/// being waited out by the SDK.
fn no_retry_requests() -> RequestConfig {
    RequestConfig::new().disable_retry()
}

/// A server that answered discovery.
pub(crate) struct DiscoveredServer {
    /// The base URL the server delegates to.
    pub homeserver: Url,
    /// The ways to sign in it offers.
    pub offer: ServerOffer,
}

/// Resolves `address` (a host, or `http://` and a host) and reads what it
/// offers, on a client with no store.
pub(crate) async fn discover_server(address: &str) -> Result<DiscoveredServer, Unreachable> {
    let client = Client::builder()
        .server_name_or_homeserver_url(address)
        .request_config(no_retry_requests())
        .build()
        .await
        .map_err(|error| {
            tracing::debug!(%error, "server didn't resolve");
            Unreachable::from(&error)
        })?;
    let login_types = client.matrix_auth().get_login_types().await.map_err(|error| {
        tracing::debug!(%error, "server's login types didn't load");
        Unreachable::from(&error)
    })?;
    let password = login_types
        .flows
        .iter()
        .any(|flow| matches!(flow, LoginType::Password(_)));
    let sso = login_types.flows.into_iter().find_map(|flow| {
        if let LoginType::Sso(sso_type) = flow {
            Some(
                sso_type
                    .identity_providers
                    .into_iter()
                    .map(|provider| IdentityProvider {
                        id: provider.id,
                        name: (!provider.name.is_empty()).then_some(provider.name),
                    })
                    .collect(),
            )
        } else {
            None
        }
    });
    let oauth = match client.oauth().server_metadata().await {
        Ok(_) => true,
        // A 404 that isn't `M_UNRECOGNIZED`, as a proxy in front of the
        // server answers, is still a server without OAuth.
        Err(OAuthDiscoveryError::NotSupported) => false,
        Err(OAuthDiscoveryError::Http(error))
            if error
                .as_client_api_error()
                .is_some_and(|api_error| api_error.status_code == StatusCode::NOT_FOUND) =>
        {
            false
        }
        Err(error) => {
            tracing::debug!(%error, "server's OAuth metadata didn't load");
            return Err(Unreachable::from(&error));
        }
    };
    Ok(DiscoveredServer {
        homeserver: client.homeserver(),
        offer: ServerOffer { oauth, sso, password },
    })
}

/// A client for signing in to `homeserver`, on a new store at `store`
/// encrypted with `passphrase`, refreshing its own tokens once signed in.
pub(crate) async fn build_sign_in_client(
    homeserver: &Url,
    store: &Path,
    passphrase: &str,
) -> Result<Client, FinishError> {
    Ok(Client::builder()
        .homeserver_url(homeserver.as_str())
        .sqlite_store(store, Some(passphrase))
        .request_config(no_retry_requests())
        .handle_refresh_tokens()
        .build()
        .await?)
}

/// Why a stored session didn't come back.
#[derive(Debug, thiserror::Error)]
pub(crate) enum RestoreError {
    /// Its ids don't parse.
    #[error(transparent)]
    Session(#[from] CorruptSession),
    /// Its store wouldn't open, for instance with the wrong passphrase.
    #[error("store wouldn't open: {0}")]
    Store(#[from] ClientBuildError),
    /// The store opened but wouldn't take the session.
    #[error("session wouldn't restore: {0}")]
    Restore(#[from] matrix_sdk::Error),
}

/// Brings `session` back on its store, with no network.
pub(crate) async fn restore_client(
    session: &StoredSession,
    store: &Path,
    passphrase: &str,
) -> Result<Client, RestoreError> {
    let auth = AuthSession::try_from(session)?;
    let client = Client::builder()
        .homeserver_url(session.homeserver.as_str())
        .sqlite_store(store, Some(passphrase))
        .handle_refresh_tokens()
        .build()
        .await?;
    if let Err(error) = client.restore_session(auth).await {
        // Closed before the caller wipes the store it opened.
        if let Err(close_error) = close_stores(&client).await {
            tracing::warn!(error = %close_error, "couldn't close the Matrix store");
        }
        return Err(error.into());
    }
    Ok(client)
}

/// Closes every store `client` holds, waiting for operations in flight.
pub(crate) async fn close_stores(client: &Client) -> Result<(), matrix_sdk::Error> {
    client.pause().await
}

/// Logs out on the server; the caller bounds how long it may take.
pub(crate) async fn log_out_on_server(client: &Client) -> Result<(), matrix_sdk::Error> {
    client.logout().await
}

/// Sends one `/login` with `info`, asking for a refresh token, and signs
/// `client` in with the answer. The SDK's own login builder retries on its
/// own, which would hide a rate limit from the UI.
async fn send_login(client: &Client, info: LoginInfo, device_name: &str) -> Result<(), matrix_sdk::Error> {
    let mut request = login::v3::Request::new(info);
    request.initial_device_display_name = Some(device_name.to_owned());
    request.refresh_token = true;
    let response = client.send(request).with_request_config(no_retry_requests()).await?;
    let session = MatrixSession {
        meta: SessionMeta {
            user_id: response.user_id,
            device_id: response.device_id,
        },
        tokens: SessionTokens {
            access_token: response.access_token,
            refresh_token: response.refresh_token,
        },
    };
    client
        .matrix_auth()
        .restore_session(session, RoomLoadSettings::default())
        .await
}

/// Signs in as `m.id.user` with `user` and `password`.
pub(crate) async fn password_sign_in(
    client: &Client,
    user: &str,
    password: &str,
    device_name: &str,
) -> Result<(), PasswordError> {
    let identifier = UserIdentifier::Matrix(MatrixUserIdentifier::new(user.to_owned()));
    let info = LoginInfo::Password(Password::new(identifier, password.to_owned()));
    send_login(client, info, device_name)
        .await
        .map_err(|error| PasswordError::from_login(&error, SystemTime::now()))
}

/// Opens the server's SSO page for `provider` (or its only page) and signs
/// in with the login token the browser comes back with.
pub(crate) async fn sso_sign_in(
    client: &Client,
    browser: &dyn AuthBrowser,
    provider: Option<&str>,
    device_name: &str,
) -> Result<(), BrowserError> {
    let redirect = browser.redirect_uri().await?;
    let page_text = client
        .matrix_auth()
        .get_sso_login_url(redirect.as_str(), provider)
        .await
        .map_err(|error| BrowserError::from_browser_login(&error))?;
    let page = Url::parse(&page_text).map_err(|error| FinishError::Sdk {
        message: error.to_string(),
    })?;
    let callback = browser.authenticate(page).await?;
    let token = callback
        .query_pairs()
        .find_map(|(key, value)| (key == LOGIN_TOKEN_PARAM).then(|| value.into_owned()))
        .ok_or(BrowserError::ProviderDidntFinish)?;
    send_login(client, LoginInfo::Token(Token::new(token)), device_name)
        .await
        .map_err(|error| {
            tracing::debug!(%error, "server refused the login token");
            BrowserError::from_browser_login(&error)
        })
}

/// Registers loaf as a public client, opens the authorization page and
/// finishes from the authorization code the browser comes back with.
pub(crate) async fn oauth_sign_in(client: &Client, browser: &dyn AuthBrowser) -> Result<(), BrowserError> {
    let redirect = browser.redirect_uri().await?;
    let registration = oauth_registration_data(&redirect)?;
    let oauth = client.oauth();
    let authorization = oauth
        .login(redirect, None, Some(registration), None)
        .build()
        .await
        .map_err(|error| {
            tracing::debug!(%error, "couldn't start the OAuth authorization");
            BrowserError::from_oauth_start(&error)
        })?;
    let callback = browser.authenticate(authorization.url).await?;
    oauth.finish_login(callback.into()).await.map_err(|error| {
        tracing::debug!(%error, "OAuth authorization didn't finish");
        BrowserError::from_browser_login(&error)
    })
}

/// What dynamic registration sends for loaf: a native public client using
/// the authorization-code grant with `redirect`.
fn oauth_registration_data(redirect: &Url) -> Result<ClientRegistrationData, FinishError> {
    let sdk_error = |error: &dyn Error| FinishError::Sdk {
        message: error.to_string(),
    };
    let client_uri = Url::parse("https://loaf.moe").map_err(|error| sdk_error(&error))?;
    let mut metadata = ClientMetadata::new(
        ApplicationType::Native,
        vec![OAuthGrantType::AuthorizationCode {
            redirect_uris: vec![registered_redirect(redirect)],
        }],
        Localized::new(client_uri, empty()),
    );
    metadata.client_name = Some(Localized::new("Loaf Chat".to_owned(), empty()));
    Raw::new(&metadata)
        .map(ClientRegistrationData::new)
        .map_err(|error| sdk_error(&error))
}

/// The redirect as registered: a loopback redirect without its port, as the
/// Matrix spec requires of native clients; any other redirect as it is.
pub(crate) fn registered_redirect(redirect: &Url) -> Url {
    let loopback = match redirect.host() {
        Some(Host::Ipv4(address)) => address.is_loopback(),
        Some(Host::Ipv6(address)) => address.is_loopback(),
        Some(Host::Domain(domain)) => domain == "localhost",
        None => false,
    };
    let mut registered = redirect.clone();
    if loopback && registered.set_port(None).is_ok() {
        registered
    } else {
        redirect.clone()
    }
}

/// The network failure somewhere in `error`'s chain of causes, if any. An
/// error wrapped transparently is skipped by `source()`, so callers holding
/// one match it directly.
fn find_unreachable(error: &(dyn Error + 'static)) -> Option<Unreachable> {
    successors(Some(error), |&cause| cause.source())
        .find_map(|cause| {
            cause
                .downcast_ref::<reqwest::Error>()
                .or_else(|| cause.downcast_ref::<Box<reqwest::Error>>().map(AsRef::as_ref))
        })
        .map(Unreachable::from)
}

impl From<&reqwest::Error> for Unreachable {
    fn from(failure: &reqwest::Error) -> Self {
        if failure.is_timeout() {
            Self::Timeout
        } else {
            Self::Connect
        }
    }
}

impl From<&HttpError> for Unreachable {
    fn from(error: &HttpError) -> Self {
        if let HttpError::Cached(inner) = error {
            return Self::from(inner.as_ref());
        }
        if let HttpError::Reqwest(failure) = error {
            return Self::from(failure);
        }
        match error.as_client_api_error() {
            Some(api_error)
                if api_error.status_code.is_server_error() || matches!(api_error.body, ErrorBody::Standard(_)) =>
            {
                Self::Status {
                    code: api_error.status_code.as_u16(),
                }
            }
            Some(_) | None => Self::NotMatrix,
        }
    }
}

impl From<&ClientBuildError> for Unreachable {
    fn from(error: &ClientBuildError) -> Self {
        if let ClientBuildError::Http(http) = error {
            Self::from(http)
        } else {
            // Discovery found no homeserver: the name's well-known and its
            // `/versions` didn't answer as Matrix.
            find_unreachable(error).unwrap_or(Self::NotMatrix)
        }
    }
}

impl From<&OAuthDiscoveryError> for Unreachable {
    fn from(error: &OAuthDiscoveryError) -> Self {
        if let OAuthDiscoveryError::Http(http) = error {
            Self::from(http)
        } else {
            Self::NotMatrix
        }
    }
}

impl Unreachable {
    /// The reason a login request got no Matrix answer; `None` when the
    /// server answered with an error the caller classifies.
    fn from_login(error: &matrix_sdk::Error) -> Option<Self> {
        let matrix_sdk::Error::Http(http) = error else {
            return None;
        };
        let answered = http.as_client_api_error().is_some_and(|api_error| {
            matches!(api_error.body, ErrorBody::Standard(_)) || api_error.status_code.is_client_error()
        });
        (!answered).then(|| Self::from(http.as_ref()))
    }
}

impl From<ClientBuildError> for FinishError {
    fn from(error: ClientBuildError) -> Self {
        Self::Sdk {
            message: error.to_string(),
        }
    }
}

impl From<&matrix_sdk::Error> for FinishError {
    fn from(error: &matrix_sdk::Error) -> Self {
        Self::Sdk {
            message: error.to_string(),
        }
    }
}

impl AccountError {
    /// What `kind` says about the account, if it is about the account.
    fn from_kind(kind: &ErrorKind) -> Option<Self> {
        if matches!(kind, ErrorKind::UserDeactivated) {
            Some(Self::Deactivated)
        } else if matches!(kind, ErrorKind::UserLocked) {
            Some(Self::Locked)
        } else if let ErrorKind::ResourceLimitExceeded(limit) = kind {
            Some(Self::ServerFull {
                admin_contact: limit.admin_contact.clone(),
            })
        } else {
            None
        }
    }
}

impl PasswordError {
    /// A failed password login, as of `now` for a rate limit given as a date.
    pub(crate) fn from_login(error: &matrix_sdk::Error, now: SystemTime) -> Self {
        if let Some(unreachable) = Unreachable::from_login(error) {
            return unreachable.into();
        }
        let Some(api_error) = error.as_client_api_error() else {
            return FinishError::from(error).into();
        };
        let kind = api_error.error_kind();
        if let Some(account) = kind.and_then(AccountError::from_kind) {
            return account.into();
        }
        match kind {
            Some(ErrorKind::Forbidden) => Self::WrongPassword,
            Some(ErrorKind::InvalidUsername) => Self::InvalidUsername,
            Some(ErrorKind::LimitExceeded(limit)) => Self::RateLimited {
                retry_after: retry_after(limit.retry_after.as_ref(), now),
            },
            _ => {
                let (code, message) = if let ErrorBody::Standard(body) = &api_error.body {
                    (body.kind.errcode().as_str().to_owned(), body.message.clone())
                } else {
                    let status = api_error.status_code;
                    (
                        status.as_str().to_owned(),
                        status.canonical_reason().unwrap_or_default().to_owned(),
                    )
                };
                Self::Refused { code, message }
            }
        }
    }
}

impl BrowserError {
    /// A failed request while signing in through the browser: building the
    /// SSO page, the login token, or finishing OAuth.
    fn from_browser_login(error: &matrix_sdk::Error) -> Self {
        if let matrix_sdk::Error::OAuth(oauth) = error {
            return if matches!(
                oauth.as_ref(),
                OAuthError::AuthorizationCode(OAuthAuthorizationCodeError::Cancelled)
            ) {
                Self::Declined
            } else {
                find_unreachable(oauth.as_ref()).map_or(Self::ProviderDidntFinish, Self::from)
            };
        }
        if let Some(unreachable) = Unreachable::from_login(error) {
            return unreachable.into();
        }
        match error.client_api_error_kind() {
            Some(kind) => AccountError::from_kind(kind).map_or(Self::ProviderDidntFinish, Self::from),
            None => FinishError::from(error).into(),
        }
    }

    /// A failure before the authorization page opens: discovery or registration.
    fn from_oauth_start(error: &OAuthError) -> Self {
        if let Some(unreachable) = find_unreachable(error) {
            return unreachable.into();
        }
        if let OAuthError::Discovery(discovery) = error {
            Unreachable::from(discovery).into()
        } else if let OAuthError::ClientRegistration(_) = error {
            Self::RegistrationRefused
        } else {
            FinishError::Sdk {
                message: error.to_string(),
            }
            .into()
        }
    }
}

/// The server's delay as of `now`, rounded up to whole seconds and at least
/// one; thirty seconds when it names none.
pub(crate) fn retry_after(retry_after: Option<&RetryAfter>, now: SystemTime) -> Duration {
    let delay = match retry_after {
        None => return DEFAULT_RETRY_AFTER,
        Some(RetryAfter::Delay(delay)) => *delay,
        Some(RetryAfter::DateTime(at)) => at.duration_since(now).unwrap_or(Duration::ZERO),
    };
    let seconds = delay.as_secs().saturating_add(u64::from(delay.subsec_nanos() > 0));
    Duration::from_secs(seconds.max(1))
}

/// A signed-in client turned out to hold no session.
#[derive(Debug, thiserror::Error)]
#[error("signed-in client holds no session")]
pub(crate) struct NoSession;

impl From<NoSession> for FinishError {
    fn from(error: NoSession) -> Self {
        Self::Sdk {
            message: error.to_string(),
        }
    }
}

impl TryFrom<&Client> for StoredSession {
    type Error = NoSession;

    /// The session `client` holds, in the form the secret store keeps.
    fn try_from(client: &Client) -> Result<Self, NoSession> {
        let (meta, auth) = match client.session().ok_or(NoSession)? {
            AuthSession::Matrix(MatrixSession { meta, tokens }) => (
                meta,
                StoredAuth::Matrix {
                    access_token: tokens.access_token,
                    refresh_token: tokens.refresh_token,
                },
            ),
            AuthSession::OAuth(session) => {
                let OAuthSession {
                    client_id,
                    user: UserSession { meta, tokens },
                } = *session;
                (
                    meta,
                    StoredAuth::OAuth {
                        client_id: client_id.as_str().to_owned(),
                        access_token: tokens.access_token,
                        refresh_token: tokens.refresh_token,
                    },
                )
            }
            _ => return Err(NoSession),
        };
        Ok(Self {
            homeserver: client.homeserver(),
            user: UserId::from(&*meta.user_id),
            device: meta.device_id.to_string().into(),
            auth,
        })
    }
}

impl TryFrom<&StoredSession> for AuthSession {
    type Error = CorruptSession;

    /// The SDK's form of a stored session.
    fn try_from(session: &StoredSession) -> Result<Self, CorruptSession> {
        let meta = SessionMeta {
            user_id: OwnedUserId::try_from(session.user.as_str()).map_err(|_error| CorruptSession)?,
            device_id: OwnedDeviceId::from(session.device.as_str()),
        };
        Ok(match &session.auth {
            StoredAuth::Matrix {
                access_token,
                refresh_token,
            } => Self::Matrix(MatrixSession {
                meta,
                tokens: SessionTokens {
                    access_token: access_token.clone(),
                    refresh_token: refresh_token.clone(),
                },
            }),
            StoredAuth::OAuth {
                client_id,
                access_token,
                refresh_token,
            } => Self::OAuth(Box::new(OAuthSession {
                client_id: ClientId::new(client_id.clone()),
                user: UserSession {
                    meta,
                    tokens: SessionTokens {
                        access_token: access_token.clone(),
                        refresh_token: refresh_token.clone(),
                    },
                },
            })),
        })
    }
}

impl From<&SdkUserId> for UserId {
    /// An id the server sent, which matrix-sdk has already checked.
    fn from(id: &SdkUserId) -> Self {
        Self {
            id: id.as_str().to_owned(),
            server_name: id.server_name().as_str().to_owned(),
        }
    }
}
