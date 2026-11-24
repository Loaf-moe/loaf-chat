//! In-memory stand-ins for the ports, driven by the core's tests.

use core::sync::atomic::{AtomicBool, Ordering};
use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard, PoisonError};

use async_trait::async_trait;

use crate::ports::secret_store::{SecretStore, SecretStoreError};

/// A `SecretStore` in memory that fails when a test says so.
#[derive(Default)]
pub struct FakeSecretStore {
    values: Mutex<HashMap<String, String>>,
    fail_next_set: AtomicBool,
    fail_gets: AtomicBool,
}

impl FakeSecretStore {
    pub fn new() -> Self {
        Self::default()
    }

    /// The next `set` fails; the one after succeeds.
    pub fn fail_next_set(&self) {
        self.fail_next_set.store(true, Ordering::SeqCst);
    }

    /// Every `get` fails from now on.
    #[expect(dead_code, reason = "used from Task 9")]
    pub fn fail_gets(&self) {
        self.fail_gets.store(true, Ordering::SeqCst);
    }

    /// What is stored under `key`, read without going through the port.
    pub fn value(&self, key: &str) -> Option<String> {
        self.values().get(key).cloned()
    }

    // A poisoned lock only means another test thread panicked; the map is still sound.
    fn values(&self) -> MutexGuard<'_, HashMap<String, String>> {
        self.values.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

#[async_trait]
impl SecretStore for FakeSecretStore {
    async fn get(&self, key: &str) -> Result<Option<String>, SecretStoreError> {
        if self.fail_gets.load(Ordering::SeqCst) {
            return Err(SecretStoreError("keychain locked".into()));
        }
        Ok(self.value(key))
    }

    async fn set(&self, key: &str, value: &str) -> Result<(), SecretStoreError> {
        if self.fail_next_set.swap(false, Ordering::SeqCst) {
            return Err(SecretStoreError("keychain locked".into()));
        }
        self.values().insert(key.to_owned(), value.to_owned());
        Ok(())
    }

    async fn delete(&self, key: &str) -> Result<(), SecretStoreError> {
        self.values().remove(key);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn fake_secret_store_fails_on_command() {
        let store = FakeSecretStore::new();
        store.fail_next_set();
        assert!(store.set("k", "v").await.is_err());
        store.set("k", "v").await.unwrap();
        assert_eq!(store.value("k").as_deref(), Some("v"));
    }
}
