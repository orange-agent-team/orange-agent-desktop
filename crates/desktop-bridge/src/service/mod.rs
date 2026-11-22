//! Owned model control runs independently of the SQLite command executor.
mod bundle;
mod io;
mod owner;
mod selection;
pub(crate) use bundle::Bundle;
pub(crate) use owner::{Client, Settings};
pub(crate) use selection::{Profile, Selection};

impl Settings {
    pub(crate) fn prepare(
        host_root: &std::path::Path,
        contents: &std::path::Path,
        ipc: &std::path::Path,
        os: &str,
        runtime: &str,
    ) -> Result<Self, crate::api::host::BridgeError> {
        let bundle = Bundle::open(contents, os, runtime)?;
        let base_ipc = io::directory(ipc)?;
        Self::for_selection(host_root, bundle, &base_ipc, Selection::load(host_root)?)
    }
    pub(crate) async fn check_installed(&self) -> Result<bool, crate::api::host::BridgeError> {
        let path = self.cache.join(format!("{}.gguf", self.bundle.model_sha));
        match std::fs::symlink_metadata(&path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(_) => Err(crate::host::failure("MODEL_STORAGE_UNAVAILABLE")),
            Ok(_) => {
                let cache = orange_model_runtime::cache::ModelCache::new(
                    &self.cache,
                    self.selection.profile.quota(),
                )
                .map_err(cache_error)?;
                cache
                    .import_file(&self.bundle.spec()?, &path)
                    .await
                    .map_err(cache_error)?;
                Ok(true)
            }
        }
    }
}
pub(crate) fn cache_error(
    error: orange_model_runtime::cache::CacheError,
) -> crate::api::host::BridgeError {
    use orange_model_runtime::cache::CacheError;
    crate::host::failure(match error {
        CacheError::LocalFileRequired => "MODEL_PROFILE_IMPORT_ONLY",
        CacheError::Cancelled => "MODEL_IMPORT_CANCELLED",
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
