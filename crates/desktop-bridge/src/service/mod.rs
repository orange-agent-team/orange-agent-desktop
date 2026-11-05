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
        let path = self.cache.join(format!("{}.gguf", self.bundle.model_sha));
        match std::fs::symlink_metadata(&path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(_) => Err(crate::host::failure("MODEL_STORAGE_UNAVAILABLE")),
            Ok(_) => {
                let cache = orange_model_runtime::cache::ModelCache::new(
                    &self.cache,
                    2 * 1024 * 1024 * 1024,
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
        CacheError::Cancelled => "MODEL_IMPORT_CANCELLED",
        CacheError::Quota => "MODEL_CACHE_QUOTA",
        CacheError::LockUnavailable => "MODEL_CACHE_BUSY",
        CacheError::Integrity | CacheError::TooLarge | CacheError::Incomplete => "MODEL_INTEGRITY",
        CacheError::UnsafePath => "MODEL_IMPORT_PATH_DENIED",
        _ => "MODEL_STORAGE_UNAVAILABLE",
    })
}
