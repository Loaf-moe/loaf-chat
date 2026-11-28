use core::fmt;

use serde::{Deserialize, Serialize};
use url::Url;

use super::{DeviceId, UserId};

/// Keychain entry holding the serialised [`StoredSession`].
pub(crate) const SESSION_KEY: &str = "session";
/// Keychain entry holding the passphrase that encrypts the SDK store.
pub(crate) const PASSPHRASE_KEY: &str = "store-passphrase";

/// Everything needed to restore a signed-in account without the network.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct StoredSession {
    /// The base URL the client talks to.
    pub homeserver: Url,
    /// The signed-in account.
    pub user: UserId,
    /// This device's login on the server.
    pub device: DeviceId,
    /// The tokens, by the kind of login.
    pub auth: StoredAuth,
}

/// The credentials a login produced, by the kind of login.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind")]
pub(crate) enum StoredAuth {
    /// A password or SSO login, with the Matrix API's own tokens.
    Matrix {
        /// Sent with every request.
        access_token: String,
        /// Gets a new access token; `None` for a server that issued none.
        refresh_token: Option<String>,
    },
    /// An OAuth 2.0 login.
    OAuth {
        /// What dynamic registration issued for this sign-in.
        client_id: String,
        /// Sent with every request.
        access_token: String,
        /// Gets a new access token; `None` for a server that issued none.
        refresh_token: Option<String>,
    },
}

/// The stored secret isn't a session this version can read.
#[derive(Debug, thiserror::Error)]
#[error("stored session is unreadable")]
pub(crate) struct CorruptSession;

impl StoredSession {
    /// The text kept in the secret store.
    #[must_use]
    pub fn to_secret(&self) -> String {
        // Serialising strings and a URL can't fail; an empty secret would
        // read back as `CorruptSession` rather than as another session.
        serde_json::to_string(self).unwrap_or_default()
    }

    /// Reads back what [`Self::to_secret`] wrote.
    ///
    /// # Errors
    /// Returns [`CorruptSession`] when `secret` isn't a stored session.
    pub fn from_secret(secret: &str) -> Result<Self, CorruptSession> {
        serde_json::from_str(secret).map_err(|_error| CorruptSession)
    }
}

// Hand-written so a log line or panic message can't carry a token.
impl fmt::Debug for StoredSession {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("StoredSession")
            .field("homeserver", &self.homeserver.as_str())
            .field("user", &self.user)
            .field("device", &self.device)
            .field("auth", &self.auth)
            .finish()
    }
}

impl fmt::Debug for StoredAuth {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        const REDACTED: &str = "<redacted>";
        match self {
            Self::Matrix {
                access_token: _,
                refresh_token,
            } => f
                .debug_struct("Matrix")
                .field("access_token", &REDACTED)
                .field("refresh_token", &refresh_token.as_ref().map(|_| REDACTED))
                .finish(),
            Self::OAuth {
                client_id,
                refresh_token,
                access_token: _,
            } => f
                .debug_struct("OAuth")
                .field("client_id", client_id)
                .field("access_token", &REDACTED)
                .field("refresh_token", &refresh_token.as_ref().map(|_| REDACTED))
                .finish(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(auth: StoredAuth) -> StoredSession {
        StoredSession {
            homeserver: Url::parse("https://matrix.example.org").unwrap(),
            user: UserId::from("@alice:example.org".to_owned()),
            device: DeviceId::from("DEVICE1".to_owned()),
            auth,
        }
    }

    fn matrix() -> StoredAuth {
        StoredAuth::Matrix {
            access_token: "syt_access_secret".into(),
            refresh_token: Some("syr_refresh_secret".into()),
        }
    }

    fn oauth() -> StoredAuth {
        StoredAuth::OAuth {
            client_id: "client-123".into(),
            access_token: "oat_access_secret".into(),
            refresh_token: Some("ort_refresh_secret".into()),
        }
    }

    #[test]
    fn round_trips_matrix_and_oauth() {
        for auth in [matrix(), oauth()] {
            let original = session(auth);
            let restored = StoredSession::from_secret(&original.to_secret()).unwrap();
            assert_eq!(restored, original);
        }
    }

    #[test]
    fn corrupt_secret_is_an_error() {
        StoredSession::from_secret("{").unwrap_err();
        StoredSession::from_secret("{}").unwrap_err();
    }

    #[test]
    fn debug_redacts_tokens() {
        for auth in [matrix(), oauth()] {
            let shown = format!("{:?}", session(auth));
            for secret in ["access_secret", "refresh_secret"] {
                assert!(!shown.contains(secret), "{shown}");
            }
            assert!(shown.contains("<redacted>"));
        }
    }
}
