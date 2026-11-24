//! Owned model control runs independently of the SQLite command executor.
mod bundle;
mod io;
mod owner;
pub(crate) use bundle::Bundle;
pub(crate) use owner::{Client, Settings};

impl Settings {
    pub(crate) fn prepare(
        host_root: &std::path::Path,
        contents: &std::path::Path,
        ipc: &std::path::Path,
        os: &str,
        runtime: &str,
    ) -> Result<Self, crate::api::host::BridgeError> {
        let bundle = Bundle::open(contents, os, runtime)?;
        let root = io::directory(&host_root.join("m"))?;
        let cache = io::directory(&host_root.join("models"))?;
        let ipc = io::directory(ipc)?;
        #[cfg(unix)]
        {
            use std::os::unix::ffi::OsStrExt;
            if ipc.join("engine.sock").as_os_str().as_bytes().len() > 100 {
                return Err(crate::host::failure("MODEL_IPC_PATH_TOO_LONG"));
            }
        }
        Ok(Self {
            bundle,
            root,
            cache,
            ipc,
            startup_seconds: 120,
        })
    }
    pub(crate) async fn check_installed(&self) -> Result<bool, crate::api::host::BridgeError> {
        Ok(self.verified_weight().await?.is_some())
    }
    pub(crate) async fn verified_weight(
        &self,
    ) -> Result<Option<orange_model_runtime::cache::VerifiedArtifact>, crate::api::host::BridgeError>
    {
        use orange_model_runtime::cache::{ArtifactSpec, CacheError, ModelCache};
        let cache = ModelCache::new(&self.cache, 2 * 1024 * 1024 * 1024).map_err(cache_error)?;
        let spec =
            ArtifactSpec::local_only(&self.bundle.model_sha, self.bundle.model_bytes, b"GGUF")
                .map_err(cache_error)?;
        match cache.ensure(&spec).await {
            Ok(weight) => Ok(Some(weight)),
            Err(CacheError::LocalFileRequired) => Ok(None),
            Err(e) => Err(cache_error(e)),
        }
    }
}
pub(crate) fn cache_error(
    error: orange_model_runtime::cache::CacheError,
) -> crate::api::host::BridgeError {
    use orange_model_runtime::cache::CacheError;
    crate::host::failure(match error {
        CacheError::Cancelled => "MODEL_IMPORT_CANCELLED",
        CacheError::RepresentationChanged => "MODEL_DOWNLOAD_REPRESENTATION_CHANGED",
        CacheError::CleanupPending => "MODEL_CACHE_CLEANUP_PENDING",
        CacheError::Redirect => "MODEL_DOWNLOAD_SOURCE_DENIED",
        CacheError::Connection => "MODEL_DOWNLOAD_CONNECTION",
        CacheError::Timeout => "MODEL_DOWNLOAD_TIMEOUT",
        CacheError::Transport => "MODEL_DOWNLOAD_INTERRUPTED",
        CacheError::Http(401 | 403) => "MODEL_DOWNLOAD_ACCESS_DENIED",
        CacheError::Http(429) => "MODEL_DOWNLOAD_RATE_LIMIT",
        CacheError::Http(_) => "MODEL_DOWNLOAD_HTTP_FAILURE",
        CacheError::Protocol => "MODEL_DOWNLOAD_RANGE_INVALID",
        CacheError::Quota => "MODEL_CACHE_QUOTA",
        CacheError::LockUnavailable => "MODEL_CACHE_BUSY",
        CacheError::Integrity | CacheError::TooLarge | CacheError::Incomplete => "MODEL_INTEGRITY",
        CacheError::UnsafePath => "MODEL_IMPORT_PATH_DENIED",
        _ => "MODEL_STORAGE_UNAVAILABLE",
    })
}
