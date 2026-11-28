use async_trait::async_trait;

/// Where the platform keeps secrets: the keychain on each OS.
#[async_trait]
pub trait SecretStore: Send + Sync {
    async fn get(&self, key: &str) -> Result<Option<String>, SecretStoreError>;
    async fn set(&self, key: &str, value: &str) -> Result<(), SecretStoreError>;
    async fn delete(&self, key: &str) -> Result<(), SecretStoreError>;
}

/// Why the platform's secret store couldn't be used.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum SecretStoreError {
    /// Locked or not running yet, such as a keychain before the first unlock;
    /// a later try may work.
    #[error("the secret store is locked or not running")]
    Unavailable,
    /// The person or the platform refused this app access.
    #[error("access to the secret store was denied")]
    Denied,
    /// Anything else the platform reported, in its own words.
    #[error("the secret store failed: {message}")]
    Other { message: String },
}
