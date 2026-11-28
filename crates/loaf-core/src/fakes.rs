//! In-memory stand-ins for the platform ports, driven by the core's tests.

use alloc::collections::VecDeque;
use alloc::sync::Arc;
use core::sync::atomic::{AtomicBool, Ordering};
use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard, PoisonError};

use async_trait::async_trait;
use url::Url;

use crate::ports::auth_browser::{AuthBrowser, AuthBrowserError};
use crate::ports::secret_store::{SecretStore, SecretStoreError};

/// A `SecretStore` in memory that fails when a test says so.
#[derive(Default)]
pub struct FakeSecretStore {
    values: Mutex<HashMap<String, String>>,
    fail_next_set_of: Mutex<Option<String>>,
    fail_gets: AtomicBool,
}

impl FakeSecretStore {
    pub fn new() -> Self {
        Self::default()
    }

    /// The next `set` of `key` fails; sets of other keys still succeed.
    pub fn fail_next_set_of(&self, key: &str) {
        *lock(&self.fail_next_set_of) = Some(key.to_owned());
    }

    /// Every `get` fails from now on.
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
            return Err(SecretStoreError::Unavailable);
        }
        Ok(self.value(key))
    }

    async fn set(&self, key: &str, value: &str) -> Result<(), SecretStoreError> {
        let failing_key = {
            let mut failing = lock(&self.fail_next_set_of);
            let matches = failing.as_deref() == Some(key);
            if matches {
                *failing = None;
            }
            matches
        };
        if failing_key {
            return Err(SecretStoreError::Unavailable);
        }
        self.values().insert(key.to_owned(), value.to_owned());
        Ok(())
    }

    async fn delete(&self, key: &str) -> Result<(), SecretStoreError> {
        self.values().remove(key);
        Ok(())
    }
}

// A poisoned lock only means another test thread panicked; the data is still sound.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// What the browser does with one page it is asked to open.
type Step = Box<dyn FnOnce(&Url) -> Result<Url, AuthBrowserError> + Send>;

/// An `AuthBrowser` that answers each `authenticate` with the next step a
/// test scripted, and records every page it was asked to open.
pub struct ScriptedAuthBrowser {
    redirect: Url,
    steps: Mutex<VecDeque<Step>>,
    opened: Mutex<Vec<Url>>,
}

impl ScriptedAuthBrowser {
    pub fn new(redirect: &str) -> Arc<Self> {
        Arc::new(Self {
            redirect: Url::parse(redirect).unwrap(),
            steps: Mutex::new(VecDeque::new()),
            opened: Mutex::new(Vec::new()),
        })
    }

    /// The next `authenticate` resolves with what `step` makes of the page.
    pub fn then(&self, step: impl FnOnce(&Url) -> Result<Url, AuthBrowserError> + Send + 'static) {
        lock(&self.steps).push_back(Box::new(step));
    }

    /// Every page opened so far, oldest first.
    pub fn opened(&self) -> Vec<Url> {
        lock(&self.opened).clone()
    }
}

#[async_trait]
impl AuthBrowser for ScriptedAuthBrowser {
    async fn redirect_uri(&self) -> Result<Url, AuthBrowserError> {
        Ok(self.redirect.clone())
    }

    async fn authenticate(&self, url: Url) -> Result<Url, AuthBrowserError> {
        lock(&self.opened).push(url.clone());
        let step = lock(&self.steps).pop_front();
        // An unscripted page is a browser the person closed.
        step.map_or(Err(AuthBrowserError::Cancelled), |run| run(&url))
    }
}
