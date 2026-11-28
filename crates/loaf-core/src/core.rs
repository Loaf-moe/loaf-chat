//! The handle a shell holds for the whole app.

use alloc::sync::Arc;
use std::io;
use std::path::PathBuf;

use tokio::fs::create_dir_all;

use crate::ports::auth_browser::AuthBrowser;
use crate::ports::secret_store::SecretStore;
use crate::session::Session;

/// What the core needs from the shell to start.
pub struct CoreConfig {
    /// The directory the Matrix store lives under, in `data_dir/matrix`.
    pub data_dir: PathBuf,
    /// Shown to the user's other sessions; the shell builds it.
    pub device_name: String,
    pub platform: Platform,
}

/// The platform ports the shell supplies.
pub struct Platform {
    pub secrets: Arc<dyn SecretStore>,
    pub auth_browser: Arc<dyn AuthBrowser>,
}

/// The core of the app; a shell starts one and keeps it.
pub struct Core {
    /// Signing in, the session's state and signing out.
    session: Arc<Session>,
}

/// The core couldn't start.
#[derive(Debug, thiserror::Error)]
pub enum StartError {
    #[error("couldn't create the data directory: {0}")]
    DataDir(#[source] io::Error),
}

impl Core {
    /// Starts the core and returns once the stored session, if any, is restored.
    ///
    /// # Errors
    ///
    /// [`StartError::DataDir`] when `data_dir` can't be created.
    pub async fn start(config: CoreConfig) -> Result<Arc<Self>, StartError> {
        create_dir_all(&config.data_dir).await.map_err(StartError::DataDir)?;
        let session = Arc::new(Session::new(
            config.platform,
            config.device_name,
            config.data_dir.join("matrix"),
        ));
        session.restore().await;
        Ok(Arc::new(Self { session }))
    }

    #[must_use]
    pub const fn session(&self) -> &Arc<Session> {
        &self.session
    }
}
