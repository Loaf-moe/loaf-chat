use async_trait::async_trait;

/// Where the platform keeps secrets: the keychain on each OS.
#[async_trait]
pub trait SecretStore: Send + Sync {
    async fn get(&self, key: &str) -> Result<Option<String>, SecretStoreError>;
    async fn set(&self, key: &str, value: &str) -> Result<(), SecretStoreError>;
    async fn delete(&self, key: &str) -> Result<(), SecretStoreError>;
}

/// The store couldn't be used, for instance a keychain that isn't unlocked yet.
#[derive(Debug, thiserror::Error)]
#[error("secret store unavailable: {0}")]
pub struct SecretStoreError(pub String);
