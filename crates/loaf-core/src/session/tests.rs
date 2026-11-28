//! The session rules against matrix-sdk's mock server, with real clients on
//! temp dirs and in-memory doubles for the platform ports.

use alloc::sync::Arc;
use core::time::Duration;
use std::fs::{File, read_to_string};
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::SystemTime;

use matrix_sdk::ruma::api::error::RetryAfter;
use matrix_sdk::test_utils::mocks::MatrixMockServer;
use serde_json::{Value, json};
use tempfile::TempDir;
use tokio::time::{sleep, timeout};
use tracing::Level;
use tracing::subscriber::set_default;
use url::Url;
use wiremock::matchers::{body_partial_json, header, method, path};
use wiremock::{Mock, ResponseTemplate};

use super::sdk::{registered_redirect, retry_after};
use super::stored::{PASSPHRASE_KEY, SESSION_KEY, StoredAuth, StoredSession};
use super::*;
use crate::core::{Core, CoreConfig, Platform};
use crate::fakes::{FakeSecretStore, ScriptedAuthBrowser};
use crate::ports::auth_browser::AuthBrowserError;
use crate::ports::secret_store::{SecretStore as _, SecretStoreError};

const ACCESS: &str = "syt_access_secret";
const REFRESH: &str = "syr_refresh_secret";
const PASSWORD: &str = "hunter2-password-secret";
const REDIRECT: &str = "http://127.0.0.1:4567/callback";
/// A rate limit that doesn't fall on a whole second.
const RETRY_AFTER_MS: u32 = 1500;

/// A homeserver on a local port that answers only what a test mounts on it.
/// Discovery needs `/versions`, so that is always mounted.
struct MockHomeserver {
    /// The wiremock server, for mounting answers a test writes itself.
    mock: MatrixMockServer,
}

impl MockHomeserver {
    async fn new() -> Self {
        let mock = MatrixMockServer::new().await;
        mock.mock_versions().ok().mount().await;
        Self { mock }
    }

    /// What the person types to reach this server.
    fn address(&self) -> String {
        self.mock.uri()
    }

    /// The host `discover` keeps from [`Self::address`].
    fn host(&self) -> String {
        self.mock.uri().trim_start_matches("http://").to_owned()
    }

    /// Answers `GET /login` with these `flows`.
    async fn offers_logins(&self, flows: Value) {
        Mock::given(method("GET"))
            .and(path("/_matrix/client/v3/login"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "flows": flows })))
            .mount(&self.mock)
            .await;
    }

    /// Answers the OAuth metadata with `M_UNRECOGNIZED`.
    async fn offers_no_oauth(&self) {
        self.mock
            .oauth()
            .mock_server_metadata()
            .error_unrecognized()
            .mount()
            .await;
    }

    /// Publishes OAuth metadata with dynamic registration.
    async fn offers_oauth(&self) {
        self.mock.oauth().mock_server_metadata().ok().mount().await;
    }

    /// Accepts `alice` with [`PASSWORD`], handing out [`ACCESS`] and [`REFRESH`].
    async fn accepts_password(&self) {
        Mock::given(method("POST"))
            .and(path("/_matrix/client/v3/login"))
            .and(body_partial_json(json!({
                "type": "m.login.password",
                "identifier": { "type": "m.id.user", "user": "alice" },
                "password": PASSWORD,
                "refresh_token": true,
                "initial_device_display_name": "Loaf test",
            })))
            .respond_with(login_ok())
            .mount(&self.mock)
            .await;
    }

    /// Answers the token exchange and whoami an OAuth sign-in makes after
    /// the authorization page.
    async fn accepts_oauth_code(&self) {
        self.mock.oauth().mock_token().ok().mount().await;
        self.mock.mock_who_am_i().ok().mount().await;
    }

    /// Answers `/logout` with `response`, expecting it `times` times.
    async fn answers_logout(&self, response: ResponseTemplate, times: u64) {
        Mock::given(method("POST"))
            .and(path("/_matrix/client/v3/logout"))
            .respond_with(response)
            .expect(times)
            .mount(&self.mock)
            .await;
    }

    /// Answers whoami with an unknown token for [`ACCESS`], so the client
    /// refreshes with `refresh`, and with alice for any other token.
    async fn expires_first_token(&self, refresh: ResponseTemplate) {
        Mock::given(method("GET"))
            .and(path("/_matrix/client/v3/account/whoami"))
            .and(header("authorization", format!("Bearer {ACCESS}").as_str()))
            .respond_with(matrix_error(401, "M_UNKNOWN_TOKEN", "Token expired"))
            .mount(&self.mock)
            .await;
        Mock::given(method("GET"))
            .and(path("/_matrix/client/v3/account/whoami"))
            .respond_with(
                ResponseTemplate::new(200)
                    .set_body_json(json!({ "user_id": "@alice:example.org", "device_id": "DEVICE1" })),
            )
            .mount(&self.mock)
            .await;
        Mock::given(method("POST"))
            .and(path("/_matrix/client/v3/refresh"))
            .respond_with(refresh)
            .mount(&self.mock)
            .await;
    }
}

/// The device the app runs on: its data dir, keychain and system browser.
/// Launching it twice is quitting the app and opening it again.
struct TestDevice {
    data_dir: TempDir,
    secrets: Arc<FakeSecretStore>,
    browser: Arc<ScriptedAuthBrowser>,
}

impl TestDevice {
    fn new() -> Self {
        Self {
            data_dir: TempDir::new().unwrap(),
            secrets: Arc::new(FakeSecretStore::new()),
            browser: ScriptedAuthBrowser::new(REDIRECT),
        }
    }

    /// Starts Core on this device; any stored session is restored.
    async fn launch(&self) -> Arc<Core> {
        Core::start(CoreConfig {
            data_dir: self.data_dir.path().to_owned(),
            device_name: "Loaf test".into(),
            platform: Platform {
                secrets: Arc::<FakeSecretStore>::clone(&self.secrets),
                auth_browser: Arc::<ScriptedAuthBrowser>::clone(&self.browser),
            },
        })
        .await
        .unwrap()
    }

    fn store_dir(&self) -> PathBuf {
        self.data_dir.path().join("matrix")
    }

    /// The session in the keychain, if any.
    fn stored_session(&self) -> Option<StoredSession> {
        self.secrets
            .value(SESSION_KEY)
            .map(|secret| StoredSession::from_secret(&secret).unwrap())
    }

    /// Nothing of a session is left on this device.
    fn is_wiped(&self) -> bool {
        !self.store_dir().exists()
            && self.secrets.value(SESSION_KEY).is_none()
            && self.secrets.value(PASSPHRASE_KEY).is_none()
    }
}

/// `homeserver` offers only a password; `device` launches and discovers it.
async fn launch_and_discover_password(homeserver: &MockHomeserver, device: &TestDevice) -> (Arc<Core>, PasswordSignIn) {
    homeserver.offers_logins(json!([{ "type": "m.login.password" }])).await;
    homeserver.offers_no_oauth().await;
    let core = device.launch().await;
    let server = core.session().discover(&homeserver.address()).await.unwrap();
    (core, server.password_sign_in().unwrap())
}

/// `homeserver` offers SSO through GitHub; `device` launches and discovers it.
async fn launch_and_discover_sso(homeserver: &MockHomeserver, device: &TestDevice) -> (Arc<Core>, BrowserSignIn) {
    homeserver
        .offers_logins(json!([{ "type": "m.login.sso", "identity_providers": [{ "id": "gh", "name": "GitHub" }] }]))
        .await;
    homeserver.offers_no_oauth().await;
    let core = device.launch().await;
    let server = core.session().discover(&homeserver.address()).await.unwrap();
    (core, server.browser_sign_ins().remove(0))
}

/// `homeserver` offers OAuth; `device` launches and discovers it.
async fn launch_and_discover_oauth(homeserver: &MockHomeserver, device: &TestDevice) -> (Arc<Core>, BrowserSignIn) {
    homeserver.offers_logins(json!([{ "type": "m.login.sso" }])).await;
    homeserver.offers_oauth().await;
    let core = device.launch().await;
    let server = core.session().discover(&homeserver.address()).await.unwrap();
    (core, server.browser_sign_ins().remove(0))
}

/// `device` launched and signed in as alice by password on `homeserver`.
async fn launch_signed_in(homeserver: &MockHomeserver, device: &TestDevice) -> Arc<Core> {
    homeserver.accepts_password().await;
    let (core, password) = launch_and_discover_password(homeserver, device).await;
    password.sign_in("alice", PASSWORD).await.unwrap();
    core
}

/// Ends `core` as quitting the app does: its stores released, then dropped.
async fn quit(core: Arc<Core>) {
    if let Some(client) = core.session().client() {
        client.pause().await.unwrap();
    }
    drop(core);
}

fn login_ok() -> ResponseTemplate {
    ResponseTemplate::new(200).set_body_json(json!({
        "access_token": ACCESS,
        "refresh_token": REFRESH,
        "device_id": "DEVICE1",
        "user_id": "@alice:example.org",
    }))
}

fn matrix_error(status: u16, errcode: &str, message: &str) -> ResponseTemplate {
    ResponseTemplate::new(status).set_body_json(json!({ "errcode": errcode, "error": message }))
}

fn alice() -> SessionState {
    SessionState::SignedIn {
        user: UserId::try_from("@alice:example.org").unwrap(),
        device: DeviceId::from("DEVICE1".to_owned()),
    }
}

fn state(core: &Core) -> SessionState {
    core.session().state().get()
}

fn is_signed_in(core: &Core) -> bool {
    matches!(state(core), SessionState::SignedIn { user: _, device: _ })
}

/// Waits until `condition` holds, failing the test after five seconds.
async fn eventually(mut condition: impl FnMut() -> bool) {
    timeout(Duration::from_secs(5), async {
        while !condition() {
            sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
}

/// The callback a provider sends back to `page`'s redirect with `query` and its `state`.
fn callback_from(page: &Url, query: &[(&str, &str)]) -> Url {
    let mut callback = Url::parse(REDIRECT).unwrap();
    {
        let mut pairs = callback.query_pairs_mut();
        pairs.extend_pairs(query);
        if let Some((_, state)) = page.query_pairs().find(|(key, _)| key == "state") {
            pairs.append_pair("state", &state);
        }
    }
    callback
}

fn empty_ok() -> ResponseTemplate {
    ResponseTemplate::new(200).set_body_json(json!({}))
}

// ---- Discovery and methods ----

#[tokio::test]
async fn found_server_reports_oauth_and_password_and_oauth_hides_sso() {
    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    homeserver
        .offers_logins(json!([
            { "type": "m.login.password" },
            { "type": "m.login.sso", "identity_providers": [{ "id": "gh", "name": "GitHub" }] },
        ]))
        .await;
    homeserver.offers_oauth().await;
    let core = device.launch().await;

    let server = core.session().discover(&homeserver.address()).await.unwrap();
    assert_eq!(server.name(), homeserver.host());
    assert!(server.password_sign_in().is_some());
    let browser = server.browser_sign_ins();
    assert_eq!(browser.len(), 1);
    assert_eq!(browser[0].name(), homeserver.host());
}

#[tokio::test]
async fn sso_keeps_order_and_falls_back_to_the_id() {
    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    homeserver
        .offers_logins(json!([{ "type": "m.login.sso", "identity_providers": [
        { "id": "gh", "name": "GitHub" },
        { "id": "kanidm", "name": "" },
    ] }]))
        .await;
    homeserver.offers_no_oauth().await;
    let core = device.launch().await;

    let server = core.session().discover(&homeserver.address()).await.unwrap();
    let names: Vec<_> = server
        .browser_sign_ins()
        .iter()
        .map(|browser| browser.name().to_owned())
        .collect();
    assert_eq!(names, ["GitHub", "kanidm"]);
    assert!(server.password_sign_in().is_none());
}

#[tokio::test]
async fn sso_with_no_providers_is_one_method_named_after_the_server() {
    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    homeserver.offers_logins(json!([{ "type": "m.login.sso" }])).await;
    let core = device.launch().await;

    // Wiremock's bare 404 for the OAuth metadata, as a proxy would send.
    let server = core.session().discover(&homeserver.address()).await.unwrap();
    let browser = server.browser_sign_ins();
    assert_eq!(browser.len(), 1);
    assert_eq!(browser[0].name(), homeserver.host());
}

#[tokio::test]
async fn nothing_usable_is_a_server_with_no_methods() {
    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    homeserver.offers_logins(json!([{ "type": "m.login.token" }])).await;
    homeserver.offers_no_oauth().await;
    let core = device.launch().await;

    let server = core.session().discover(&homeserver.address()).await.unwrap();
    assert!(server.password_sign_in().is_none());
    assert!(server.browser_sign_ins().is_empty());
}

#[tokio::test]
async fn implausible_input_is_not_a_server_and_unreachable_is_couldnt_reach() {
    let device = TestDevice::new();
    let core = device.launch().await;
    assert_eq!(
        core.session().discover("not a server").await.unwrap_err(),
        DiscoverError::NotAServer
    );
    assert_eq!(
        core.session().discover("http://127.0.0.1:1").await.unwrap_err(),
        DiscoverError::CouldntReach(Unreachable::Connect)
    );
}

#[tokio::test]
async fn a_web_server_that_isnt_matrix_is_not_matrix() {
    // No `/versions`, no well-known: a plain web server answering 404s.
    let web_server = MatrixMockServer::new().await;
    let device = TestDevice::new();
    let core = device.launch().await;
    assert_eq!(
        core.session().discover(&web_server.uri()).await.unwrap_err(),
        DiscoverError::CouldntReach(Unreachable::NotMatrix)
    );
}

#[tokio::test]
async fn discover_while_signed_in_is_not_signed_out() {
    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    let core = launch_signed_in(&homeserver, &device).await;
    assert_eq!(
        core.session().discover(&homeserver.address()).await.unwrap_err(),
        DiscoverError::NotSignedOut
    );
}

#[test]
fn a_user_id_names_its_server() {
    let user = UserId::try_from(" @alice:loaf.moe:8448 ").unwrap();
    assert_eq!(user.as_str(), "@alice:loaf.moe:8448");
    assert_eq!(user.server_name(), "loaf.moe:8448");
}

#[test]
fn text_that_isnt_a_user_id_says_why() {
    for (text, why) in [
        ("alice", InvalidUserId::MissingAt),
        ("@alice", InvalidUserId::MissingServer),
        ("@alice:", InvalidUserId::MissingServer),
        ("@:loaf.moe", InvalidUserId::EmptyUsername),
        ("@al ice:loaf.moe", InvalidUserId::HasSpaces),
    ] {
        assert_eq!(UserId::try_from(text), Err(why), "{text:?}");
    }
}

#[test]
fn a_stored_user_id_that_isnt_one_is_corrupt() {
    let stored: Result<UserId, _> = serde_json::from_str("\"alice\"");
    stored.unwrap_err();
}

#[test]
fn a_typed_user_id_discovers_its_server() {
    assert_eq!(
        server::parse_server_name("@alice:Loaf.moe").as_deref(),
        Some("loaf.moe")
    );
}

// ---- Password ----

#[tokio::test]
async fn right_credentials_sign_in_and_keep_the_session() {
    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    let core = launch_signed_in(&homeserver, &device).await;

    assert_eq!(state(&core), alice());
    let stored = device.stored_session().unwrap();
    assert_eq!(
        stored.auth,
        StoredAuth::Matrix {
            access_token: ACCESS.into(),
            refresh_token: Some(REFRESH.into()),
        }
    );
    assert_eq!(stored.homeserver.as_str().trim_end_matches('/'), homeserver.address());
    assert!(
        device
            .secrets
            .value(PASSPHRASE_KEY)
            .is_some_and(|passphrase| passphrase.len() >= 32)
    );
    assert!(device.store_dir().exists());
}

#[tokio::test]
async fn username_is_trimmed() {
    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    homeserver.accepts_password().await;
    let (core, password) = launch_and_discover_password(&homeserver, &device).await;
    password.sign_in("  alice ", PASSWORD).await.unwrap();
    assert_eq!(state(&core), alice());
}

#[tokio::test]
async fn empty_fields_are_refused_without_a_request() {
    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    Mock::given(method("POST"))
        .and(path("/_matrix/client/v3/login"))
        .respond_with(login_ok())
        .expect(0)
        .mount(&homeserver.mock)
        .await;
    let (_core, password) = launch_and_discover_password(&homeserver, &device).await;

    let no_user = password.sign_in("   ", PASSWORD).await.unwrap_err();
    assert_eq!(no_user.error, PasswordError::Empty(EmptyFields::Username));
    let no_password = no_user.handle.sign_in("alice", "").await.unwrap_err();
    assert_eq!(no_password.error, PasswordError::Empty(EmptyFields::Password));
    let neither = no_password.handle.sign_in("", "").await.unwrap_err();
    assert_eq!(neither.error, PasswordError::Empty(EmptyFields::Both));
}

#[tokio::test]
async fn wrong_password_hands_the_handle_back() {
    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    Mock::given(method("POST"))
        .and(path("/_matrix/client/v3/login"))
        .and(body_partial_json(json!({ "password": "wrong" })))
        .respond_with(matrix_error(403, "M_FORBIDDEN", "Invalid password"))
        .mount(&homeserver.mock)
        .await;
    homeserver.accepts_password().await;
    let (core, password) = launch_and_discover_password(&homeserver, &device).await;

    let failed = password.sign_in("alice", "wrong").await.unwrap_err();
    assert_eq!(failed.error, PasswordError::WrongPassword);
    assert_eq!(state(&core), SessionState::SignedOut);
    assert!(device.is_wiped());

    failed.handle.sign_in("alice", PASSWORD).await.unwrap();
    assert_eq!(state(&core), alice());
}

#[tokio::test]
async fn rate_limit_is_rounded_up_and_requested_once() {
    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    Mock::given(method("POST"))
        .and(path("/_matrix/client/v3/login"))
        .respond_with(ResponseTemplate::new(429).set_body_json(json!({
            "errcode": "M_LIMIT_EXCEEDED",
            "error": "Too many requests",
            "retry_after_ms": RETRY_AFTER_MS,
        })))
        .expect(1)
        .mount(&homeserver.mock)
        .await;
    let (_core, password) = launch_and_discover_password(&homeserver, &device).await;

    let failed = password.sign_in("alice", PASSWORD).await.unwrap_err();
    assert_eq!(
        failed.error,
        PasswordError::RateLimited {
            retry_after: Duration::from_secs(2)
        }
    );
}

#[tokio::test]
async fn rate_limit_reads_the_retry_after_header() {
    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    Mock::given(method("POST"))
        .and(path("/_matrix/client/v3/login"))
        .respond_with(matrix_error(429, "M_LIMIT_EXCEEDED", "Too many requests").insert_header("Retry-After", "5"))
        .mount(&homeserver.mock)
        .await;
    let (_core, password) = launch_and_discover_password(&homeserver, &device).await;

    let failed = password.sign_in("alice", PASSWORD).await.unwrap_err();
    assert_eq!(
        failed.error,
        PasswordError::RateLimited {
            retry_after: Duration::from_secs(5)
        }
    );
}

#[tokio::test]
async fn a_proxy_error_page_is_unreachable_with_its_status() {
    let response = ResponseTemplate::new(502).set_body_string("<html>Bad Gateway</html>");
    assert_eq!(
        password_error_for(response).await,
        PasswordError::CouldntReach(Unreachable::Status { code: 502 })
    );
}

#[test]
fn retry_after_rounds_up_to_at_least_a_second_and_defaults_to_thirty() {
    let now = SystemTime::now();
    let delay = |millis| retry_after(Some(&RetryAfter::Delay(Duration::from_millis(millis))), now);
    assert_eq!(retry_after(None, now), Duration::from_secs(30));
    assert_eq!(delay(0), Duration::from_secs(1));
    assert_eq!(delay(2000), Duration::from_secs(2));
    assert_eq!(delay(2001), Duration::from_secs(3));
    let at = |offset| retry_after(Some(&RetryAfter::DateTime(offset)), now);
    assert_eq!(at(now + Duration::from_millis(2200)), Duration::from_secs(3));
    assert_eq!(at(now - Duration::from_secs(10)), Duration::from_secs(1));
}

/// What a password sign-in fails with when `/login` answers `response`.
async fn password_error_for(response: ResponseTemplate) -> PasswordError {
    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    Mock::given(method("POST"))
        .and(path("/_matrix/client/v3/login"))
        .respond_with(response)
        .mount(&homeserver.mock)
        .await;
    let (_core, password) = launch_and_discover_password(&homeserver, &device).await;
    password.sign_in("alice", PASSWORD).await.unwrap_err().error
}

#[tokio::test]
async fn account_problems_have_their_own_errors() {
    for (response, expected) in [
        (
            matrix_error(403, "M_USER_DEACTIVATED", "This account is gone"),
            AccountError::Deactivated,
        ),
        (
            matrix_error(401, "M_USER_LOCKED", "Locked by an admin"),
            AccountError::Locked,
        ),
        (
            ResponseTemplate::new(403).set_body_json(json!({
                "errcode": "M_RESOURCE_LIMIT_EXCEEDED",
                "error": "Monthly active user limit reached",
                "admin_contact": "mailto:admin@example.org",
            })),
            AccountError::ServerFull {
                admin_contact: "mailto:admin@example.org".into(),
            },
        ),
    ] {
        assert_eq!(password_error_for(response).await, PasswordError::Account(expected));
    }
}

#[tokio::test]
async fn invalid_username_is_its_own_error() {
    let response = matrix_error(400, "M_INVALID_USERNAME", "Bad username");
    assert_eq!(password_error_for(response).await, PasswordError::InvalidUsername);
}

#[tokio::test]
async fn other_server_errors_keep_the_code_and_the_servers_text() {
    let response = matrix_error(400, "M_UNKNOWN", "Something went wrong");
    assert_eq!(
        password_error_for(response).await,
        PasswordError::Refused {
            code: "M_UNKNOWN".into(),
            message: "Something went wrong".into(),
        }
    );
    let custom = matrix_error(403, "ORG_EXAMPLE_TERMS", "Accept the terms first");
    assert_eq!(
        password_error_for(custom).await,
        PasswordError::Refused {
            code: "ORG_EXAMPLE_TERMS".into(),
            message: "Accept the terms first".into(),
        }
    );
    assert_eq!(
        password_error_for(ResponseTemplate::new(418)).await,
        PasswordError::Refused {
            code: "418".into(),
            message: "I'm a teapot".into(),
        }
    );
}

// ---- Browser ----

#[tokio::test]
async fn sso_signs_in_with_the_login_token() {
    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    Mock::given(method("POST"))
        .and(path("/_matrix/client/v3/login"))
        .and(body_partial_json(json!({
            "type": "m.login.token",
            "token": "login-token",
            "refresh_token": true,
        })))
        .respond_with(login_ok())
        .expect(1)
        .mount(&homeserver.mock)
        .await;
    let (core, browser) = launch_and_discover_sso(&homeserver, &device).await;
    device
        .browser
        .then(|page| Ok(callback_from(page, &[("loginToken", "login-token")])));

    browser.sign_in().await.unwrap();

    assert_eq!(state(&core), alice());
    let page = &device.browser.opened()[0];
    assert!(page.path().ends_with("/login/sso/redirect/gh"), "{page}");
    assert!(
        page.query_pairs()
            .any(|(key, value)| key == "redirectUrl" && value == REDIRECT)
    );
}

#[tokio::test]
async fn refused_login_token_is_provider_didnt_finish() {
    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    Mock::given(method("POST"))
        .and(path("/_matrix/client/v3/login"))
        .respond_with(matrix_error(403, "M_FORBIDDEN", "Invalid token"))
        .mount(&homeserver.mock)
        .await;
    let (core, browser) = launch_and_discover_sso(&homeserver, &device).await;
    device
        .browser
        .then(|page| Ok(callback_from(page, &[("loginToken", "stale")])));

    let failed = browser.sign_in().await.unwrap_err();
    assert_eq!(failed.error, BrowserError::ProviderDidntFinish);
    assert_eq!(state(&core), SessionState::SignedOut);
    assert!(device.is_wiped());
}

#[tokio::test]
async fn sso_account_problems_are_account_errors() {
    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    Mock::given(method("POST"))
        .and(path("/_matrix/client/v3/login"))
        .respond_with(matrix_error(403, "M_USER_DEACTIVATED", "This account is gone"))
        .mount(&homeserver.mock)
        .await;
    let (_core, browser) = launch_and_discover_sso(&homeserver, &device).await;
    device
        .browser
        .then(|page| Ok(callback_from(page, &[("loginToken", "login-token")])));

    let failed = browser.sign_in().await.unwrap_err();
    assert_eq!(failed.error, BrowserError::Account(AccountError::Deactivated));
    assert!(device.is_wiped());
}

#[tokio::test]
async fn closed_browser_is_cancelled_and_one_that_wont_open_is_browser_didnt_open() {
    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    let (_core, browser) = launch_and_discover_sso(&homeserver, &device).await;

    let closed = browser.sign_in().await.unwrap_err();
    assert_eq!(closed.error, BrowserError::Cancelled);

    device.browser.then(|_page| Err(AuthBrowserError::CouldntOpen));
    let didnt_open = closed.handle.sign_in().await.unwrap_err();
    assert_eq!(didnt_open.error, BrowserError::BrowserDidntOpen);
}

#[tokio::test]
async fn oauth_registers_without_the_loopback_port_and_signs_in() {
    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    Mock::given(method("POST"))
        .and(path("/oauth2/registration"))
        .and(body_partial_json(json!({
            "application_type": "native",
            "client_name": "Loaf Chat",
            "client_uri": "https://loaf.moe/",
            "redirect_uris": ["http://127.0.0.1/callback"],
            "grant_types": ["authorization_code", "refresh_token"],
        })))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "client_id": "loaf-client" })))
        .expect(1)
        .mount(&homeserver.mock)
        .await;
    homeserver.accepts_oauth_code().await;
    let (core, browser) = launch_and_discover_oauth(&homeserver, &device).await;
    device
        .browser
        .then(|page| Ok(callback_from(page, &[("code", "authorization-code")])));

    browser.sign_in().await.unwrap();

    assert!(is_signed_in(&core));
    let page = &device.browser.opened()[0];
    assert!(
        page.query_pairs()
            .any(|(key, value)| key == "redirect_uri" && value == REDIRECT)
    );
    assert!(matches!(
        device.stored_session().unwrap().auth,
        StoredAuth::OAuth { client_id, access_token: _, refresh_token: _ } if client_id == "loaf-client"
    ));
}

#[tokio::test]
async fn oauth_declined_on_the_providers_page_is_declined() {
    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    homeserver.mock.oauth().mock_registration().ok().mount().await;
    let (core, browser) = launch_and_discover_oauth(&homeserver, &device).await;
    device
        .browser
        .then(|page| Ok(callback_from(page, &[("error", "access_denied")])));

    let failed = browser.sign_in().await.unwrap_err();
    assert_eq!(failed.error, BrowserError::Declined);
    assert_eq!(state(&core), SessionState::SignedOut);
}

#[tokio::test]
async fn a_server_without_dynamic_registration_refuses_registration() {
    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    homeserver.offers_logins(json!([{ "type": "m.login.sso" }])).await;
    homeserver
        .mock
        .oauth()
        .mock_server_metadata()
        .ok_without_registration()
        .mount()
        .await;
    let core = device.launch().await;
    let browser = core
        .session()
        .discover(&homeserver.address())
        .await
        .unwrap()
        .browser_sign_ins()
        .remove(0);

    let failed = browser.sign_in().await.unwrap_err();
    assert_eq!(failed.error, BrowserError::RegistrationRefused);
    assert_eq!(device.browser.opened(), Vec::<Url>::new());
}

#[test]
fn empty_fields_name_what_was_empty() {
    assert_eq!(EmptyFields::of(" ", "pw"), Some(EmptyFields::Username));
    assert_eq!(EmptyFields::of("alice", ""), Some(EmptyFields::Password));
    assert_eq!(EmptyFields::of("", ""), Some(EmptyFields::Both));
    assert_eq!(EmptyFields::of("alice", "pw"), None);
}

#[tokio::test]
async fn oauth_retried_after_a_cancel_signs_in() {
    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    homeserver.mock.oauth().mock_registration().ok().mount().await;
    homeserver.accepts_oauth_code().await;
    let (core, browser) = launch_and_discover_oauth(&homeserver, &device).await;

    let failed = browser.sign_in().await.unwrap_err();
    assert_eq!(failed.error, BrowserError::Cancelled);

    device
        .browser
        .then(|page| Ok(callback_from(page, &[("code", "authorization-code")])));
    failed.handle.sign_in().await.unwrap();
    assert!(is_signed_in(&core));
}

#[test]
fn only_loopback_redirects_lose_their_port() {
    for (redirect, registered) in [
        ("http://127.0.0.1:4567/callback", "http://127.0.0.1/callback"),
        ("http://[::1]:4567/callback", "http://[::1]/callback"),
        ("http://localhost:4567/callback", "http://localhost/callback"),
        ("https://loaf.moe:8443/callback", "https://loaf.moe:8443/callback"),
        ("moe.loaf.chat:/callback", "moe.loaf.chat:/callback"),
    ] {
        assert_eq!(registered_redirect(&Url::parse(redirect).unwrap()).as_str(), registered);
    }
}

// ---- One at a time ----

#[tokio::test]
async fn sign_in_during_another_is_busy() {
    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    Mock::given(method("POST"))
        .and(path("/_matrix/client/v3/login"))
        .respond_with(login_ok().set_delay(Duration::from_millis(500)))
        .mount(&homeserver.mock)
        .await;
    let (core, first) = launch_and_discover_password(&homeserver, &device).await;
    let second = first.clone();

    let (first_result, second_result) = tokio::join!(first.sign_in("alice", PASSWORD), async {
        sleep(Duration::from_millis(100)).await;
        second.sign_in("alice", PASSWORD).await
    });
    first_result.unwrap();
    assert_eq!(second_result.unwrap_err().error, PasswordError::Busy);
    assert_eq!(state(&core), alice());
}

#[tokio::test]
async fn sign_in_after_success_with_another_handle_is_not_signed_out() {
    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    homeserver.accepts_password().await;
    let (_core, first) = launch_and_discover_password(&homeserver, &device).await;
    let second = first.clone();

    first.sign_in("alice", PASSWORD).await.unwrap();
    assert_eq!(
        second.sign_in("alice", PASSWORD).await.unwrap_err().error,
        PasswordError::NotSignedOut
    );
}

// ---- Keeping the session across launches ----

#[tokio::test]
async fn nothing_stored_starts_signed_out() {
    let device = TestDevice::new();
    let core = device.launch().await;
    assert_eq!(state(&core), SessionState::SignedOut);
}

#[tokio::test]
async fn stored_session_restores_offline_with_the_keys_made_at_sign_in() {
    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    let first_core = launch_signed_in(&homeserver, &device).await;
    let first_client = first_core.session().client().unwrap();
    let key = first_client.encryption().ed25519_key().await.unwrap();
    drop(first_client);
    quit(first_core).await;

    // Point the stored session at a port nothing listens on.
    let mut stored = device.stored_session().unwrap();
    stored.homeserver = Url::parse("http://127.0.0.1:1").unwrap();
    device.secrets.set(SESSION_KEY, &stored.to_secret()).await.unwrap();

    let core = device.launch().await;
    assert_eq!(state(&core), alice());
    let client = core.session().client().unwrap();
    assert_eq!(client.encryption().ed25519_key().await.unwrap(), key);
}

#[tokio::test]
async fn failed_secret_write_fails_sign_in_logs_out_and_wipes() {
    for failing_key in [SESSION_KEY, PASSPHRASE_KEY] {
        let homeserver = MockHomeserver::new().await;
        let device = TestDevice::new();
        homeserver.accepts_password().await;
        homeserver.answers_logout(empty_ok(), 1).await;
        let (core, password) = launch_and_discover_password(&homeserver, &device).await;
        device.secrets.fail_next_set_of(failing_key);

        let failed = password.sign_in("alice", PASSWORD).await.unwrap_err();
        assert_eq!(
            failed.error,
            PasswordError::CouldntFinish(FinishError::Secrets(SecretStoreError::Unavailable)),
            "{failing_key}"
        );
        assert_eq!(state(&core), SessionState::SignedOut);
        assert!(device.is_wiped(), "{failing_key}");
    }
}

#[tokio::test]
async fn secret_store_error_at_start_signs_out_without_wiping() {
    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    quit(launch_signed_in(&homeserver, &device).await).await;
    device.secrets.fail_gets();

    let core = device.launch().await;
    assert_eq!(state(&core), SessionState::SignedOut);
    assert!(device.store_dir().exists());
    assert!(device.secrets.value(SESSION_KEY).is_some());
    assert!(device.secrets.value(PASSPHRASE_KEY).is_some());
}

#[tokio::test]
async fn corrupt_session_wipes() {
    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    quit(launch_signed_in(&homeserver, &device).await).await;
    device.secrets.set(SESSION_KEY, "{").await.unwrap();

    let core = device.launch().await;
    assert_eq!(state(&core), SessionState::SignedOut);
    assert!(device.is_wiped());
}

#[tokio::test]
async fn store_that_wont_restore_wipes() {
    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    quit(launch_signed_in(&homeserver, &device).await).await;
    device.secrets.set(PASSPHRASE_KEY, "not-the-passphrase").await.unwrap();

    let core = device.launch().await;
    assert_eq!(state(&core), SessionState::SignedOut);
    assert!(device.is_wiped());
}

fn refreshed_tokens() -> ResponseTemplate {
    ResponseTemplate::new(200).set_body_json(json!({
        "access_token": "syt_refreshed_secret",
        "refresh_token": "syr_refreshed_secret",
    }))
}

#[tokio::test]
async fn refreshed_tokens_reach_the_secret_store() {
    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    let core = launch_signed_in(&homeserver, &device).await;
    homeserver.expires_first_token(refreshed_tokens()).await;

    let client = core.session().client().unwrap();
    client.whoami().await.unwrap();

    eventually(|| {
        device.stored_session().is_some_and(|stored| {
            stored.auth
                == StoredAuth::Matrix {
                    access_token: "syt_refreshed_secret".into(),
                    refresh_token: Some("syr_refreshed_secret".into()),
                }
        })
    })
    .await;
    assert_eq!(state(&core), alice());
}

#[tokio::test]
async fn unrefreshable_token_signs_out_and_wipes() {
    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    let core = launch_signed_in(&homeserver, &device).await;
    homeserver
        .expires_first_token(matrix_error(401, "M_UNKNOWN_TOKEN", "Refresh token revoked"))
        .await;

    let client = core.session().client().unwrap();
    client.whoami().await.unwrap_err();
    drop(client);

    eventually(|| state(&core) == SessionState::SignedOut).await;
    eventually(|| device.is_wiped()).await;
}

#[tokio::test]
async fn sign_out_wipes_even_when_server_logout_fails() {
    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    let core = launch_signed_in(&homeserver, &device).await;
    homeserver.answers_logout(ResponseTemplate::new(500), 1).await;

    core.session().sign_out().await;
    assert_eq!(state(&core), SessionState::SignedOut);
    assert!(device.is_wiped());
}

#[tokio::test]
async fn second_sign_out_in_flight_does_nothing() {
    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    let core = launch_signed_in(&homeserver, &device).await;
    homeserver
        .answers_logout(empty_ok().set_delay(Duration::from_millis(300)), 1)
        .await;

    tokio::join!(core.session().sign_out(), core.session().sign_out());
    eventually(|| state(&core) == SessionState::SignedOut).await;
    assert!(device.is_wiped());
}

#[tokio::test]
async fn signing_in_again_after_signing_out_works() {
    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    let core = launch_signed_in(&homeserver, &device).await;
    homeserver.answers_logout(empty_ok(), 1).await;
    core.session().sign_out().await;

    let server = core.session().discover(&homeserver.address()).await.unwrap();
    server
        .password_sign_in()
        .unwrap()
        .sign_in("alice", PASSWORD)
        .await
        .unwrap();
    assert_eq!(state(&core), alice());
}

#[tokio::test]
async fn sign_in_futures_are_send() {
    fn assert_send<T>(_: &T)
    where
        T: Send,
    {
    }
    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    let (core, password) = launch_and_discover_password(&homeserver, &device).await;
    let other_homeserver = MockHomeserver::new().await;
    let browser = launch_and_discover_sso(&other_homeserver, &TestDevice::new()).await.1;
    let discover = core.session().discover("loaf.moe");
    assert_send(&discover);
    assert_send(&password.sign_in("alice", PASSWORD));
    assert_send(&browser.sign_in());
    assert_send(&core.session().sign_out());
}

// ---- Logs ----

#[tokio::test]
async fn logs_of_sign_in_refresh_and_sign_out_carry_no_secrets() {
    let logs_dir = TempDir::new().unwrap();
    let log_path = logs_dir.path().join("trace.log");
    let subscriber = tracing_subscriber::fmt()
        .with_max_level(Level::TRACE)
        .with_writer(Mutex::new(File::create(&log_path).unwrap()))
        .finish();
    let _default = set_default(subscriber);

    let homeserver = MockHomeserver::new().await;
    let device = TestDevice::new();
    let core = launch_signed_in(&homeserver, &device).await;
    let passphrase = device.secrets.value(PASSPHRASE_KEY).unwrap();
    homeserver.expires_first_token(refreshed_tokens()).await;
    core.session().client().unwrap().whoami().await.unwrap();
    eventually(|| {
        device.stored_session().is_some_and(|stored| {
            matches!(&stored.auth, StoredAuth::Matrix { access_token, refresh_token: _ } if access_token == "syt_refreshed_secret")
        })
    })
    .await;
    homeserver.answers_logout(empty_ok(), 1).await;
    core.session().sign_out().await;

    let logs = read_to_string(&log_path).unwrap();
    // The capture works: the SDK's per-request line is there.
    assert!(logs.contains("Sending request"));
    for secret in [
        ACCESS,
        REFRESH,
        PASSWORD,
        "syt_refreshed_secret",
        "syr_refreshed_secret",
        &passphrase,
    ] {
        assert!(!logs.contains(secret), "logs contain {secret:?}");
    }
}
