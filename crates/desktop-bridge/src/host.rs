//! Native Host state is intentionally outside the FRB API namespace.
use crate::api::host::{BridgeError, HostView};
use orange_agent_runtime::{Journal, workspace};
use orange_domain::Credits;
use std::{
    fs,
    path::{Path, PathBuf},
    sync::{LazyLock, Mutex},
};
use uuid::Uuid;

fn failure(code: &str) -> BridgeError {
    BridgeError {
        code: code.into(),
        correlation_id: Uuid::new_v4().to_string(),
    }
}
struct Host {
    root: PathBuf,
    view: HostView,
    _journal: Journal,
}
#[derive(Default)]
struct HostRegistry {
    host: Option<Host>,
}
static HOST: LazyLock<Mutex<HostRegistry>> = LazyLock::new(|| Mutex::new(HostRegistry::default()));
impl HostRegistry {
    fn initialize(&mut self, path: &Path) -> Result<HostView, BridgeError> {
        if path.is_symlink() {
            return Err(failure("PRIVATE_STORAGE_REQUIRED"));
        }
        let mut builder = fs::DirBuilder::new();
        builder.recursive(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        builder
            .create(path)
            .map_err(|_| failure("STORAGE_UNAVAILABLE"))?;
        let root = path
            .canonicalize()
            .map_err(|_| failure("STORAGE_UNAVAILABLE"))?;
        if let Some(host) = &self.host {
            if host.root != root {
                return Err(failure("HOST_CONTEXT_CHANGED"));
            }
            return Ok(host.view.clone());
        }
        let journal = Journal::open(&root.join("host.sqlite"))
            .map_err(|_| failure("PRIVATE_STORAGE_OR_HOST_LOCK"))?;
        let lock: serde_json::Value = serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../config/runtime.lock.json"
        )))
        .map_err(|_| failure("RUNTIME_MANIFEST_INVALID"))?;
        let view = HostView {
            handle: format!("host-{}", Uuid::new_v4()),
            contract_version: "desktop-host.v1".into(),
            runtime_version: lock["version"]
                .as_str()
                .ok_or_else(|| failure("RUNTIME_MANIFEST_INVALID"))?
                .into(),
            runtime_source_commit: lock["origin_commit"]
                .as_str()
                .ok_or_else(|| failure("RUNTIME_MANIFEST_INVALID"))?
                .into(),
            available_read_tools: workspace::definitions()
                .into_iter()
                .map(|tool| tool.name)
                .collect(),
        };
        self.host = Some(Host {
            root,
            view: view.clone(),
            _journal: journal,
        });
        Ok(view)
    }
    fn inspect(&self, handle: &str) -> Result<HostView, BridgeError> {
        let host = self
            .host
            .as_ref()
            .filter(|h| h.view.handle == handle)
            .ok_or_else(|| failure("STALE_HOST_HANDLE"))?;
        Ok(host.view.clone())
    }
    fn close(&mut self, handle: &str) -> Result<(), BridgeError> {
        self.inspect(handle)?;
        self.host.take();
        Ok(())
    }
    fn validate_amount(&self, handle: &str, value: &str) -> Result<String, BridgeError> {
        self.inspect(handle)?;
        if value.len() > 19 {
            return Err(failure("INVALID_AMOUNT"));
        }
        value
            .parse::<Credits>()
            .map(|c| c.to_string())
            .map_err(|_| failure("INVALID_AMOUNT"))
    }
}
/// The trusted UI supplies an OS application-data directory, never model input.
/// Opening this Host grants no workspace access and starts no model.
pub(crate) fn initialize_host(application_data_directory: String) -> Result<HostView, BridgeError> {
    let directory = PathBuf::from(application_data_directory);
    if !directory.is_absolute() {
        return Err(failure("INVALID_DATA_DIRECTORY"));
    }
    HOST.lock()
        .map_err(|_| failure("HOST_INTERNAL"))?
        .initialize(&directory)
}
pub(crate) fn inspect_host(handle: String) -> Result<HostView, BridgeError> {
    HOST.lock()
        .map_err(|_| failure("HOST_INTERNAL"))?
        .inspect(&handle)
}
/// Pure canonical amount validation; does not create a budget or transfer money.
pub(crate) fn validate_amount(handle: String, value: String) -> Result<String, BridgeError> {
    HOST.lock()
        .map_err(|_| failure("HOST_INTERNAL"))?
        .validate_amount(&handle, &value)
}
/// Closes this local storage handle. No GPU/Job resource release is asserted.
pub(crate) fn close_host(handle: String) -> Result<(), BridgeError> {
    HOST.lock()
        .map_err(|_| failure("HOST_INTERNAL"))?
        .close(&handle)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn private_journal_handles_and_canonical_amounts_survive_reopen_without_reuse() {
        let temporary = tempfile::tempdir().expect("temp");
        let path = temporary.path().join("private");
        let mut registry = HostRegistry::default();
        let first = registry.initialize(&path).expect("open");
        assert_eq!(
            registry.initialize(&path).expect("same").handle,
            first.handle
        );
        assert!(registry.inspect("another-handle").is_err());
        assert_eq!(
            first.runtime_source_commit,
            "628cd5f3acb340c7349bfc8822f3f167e3020718"
        );
        assert_eq!(
            registry
                .validate_amount(&first.handle, "9007199254740993")
                .expect("integer"),
            "9007199254740993"
        );
        for bad in ["01", "-1", "1.5", "9223372036854775808"] {
            assert!(registry.validate_amount(&first.handle, bad).is_err());
        }
        assert!(
            Journal::open(&path.join("host.sqlite")).is_err(),
            "host lock held"
        );
        registry.close(&first.handle).expect("close");
        assert!(registry.inspect(&first.handle).is_err());
        let second = registry.initialize(&path).expect("reopen");
        assert_ne!(first.handle, second.handle);
        assert!(registry.close(&first.handle).is_err());
    }
    #[cfg(unix)]
    #[test]
    fn public_directory_is_rejected_without_changing_its_permissions() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().expect("temp");
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o755)).expect("permissions");
        let mut registry = HostRegistry::default();
        assert!(registry.initialize(dir.path()).is_err());
        assert_eq!(
            fs::metadata(dir.path())
                .expect("metadata")
                .permissions()
                .mode()
                & 0o777,
            0o755
        );
    }
}
