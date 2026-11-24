//! The handle a shell holds for the whole app.

use alloc::sync::Arc;
use std::path::PathBuf;

use crate::ports::auth_browser::AuthBrowser;
use crate::ports::matrix::Matrix;
use crate::ports::secret_store::SecretStore;
use crate::session::Session;
use crate::session::keeping::Keeping;

/// What the core needs from the shell to start.
pub struct CoreConfig {
    /// The directory the Matrix store lives under.
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
    session: Session,
}

impl Core {
    /// Starts over `matrix` and returns once the stored session, if any, is restored.
    #[cfg_attr(not(test), expect(dead_code, reason = "used from Task 12"))]
    pub(crate) async fn start_with(config: CoreConfig, matrix: Arc<dyn Matrix>) -> Arc<Self> {
        let keeping = Arc::new(Keeping::new(config.platform, config.device_name, matrix));
        keeping.restore().await;
        Arc::new(Self {
            session: Session::new(keeping),
        })
    }

    #[must_use]
    pub const fn session(&self) -> &Session {
        &self.session
    }
}
