//! Native Host state is intentionally outside the FRB API namespace.
use crate::api::host::{BridgeError, HostView, RunPage, RunSummary, WorkspaceView};
use orange_agent_runtime::workspaces::WorkspaceStoreError;
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
    journal: Journal,
    grants: std::collections::HashMap<String, workspace::WorkspaceGrant>,
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
            journal,
            grants: std::collections::HashMap::new(),
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
    fn current(&mut self, handle: &str) -> Result<&mut Host, BridgeError> {
        self.host
            .as_mut()
            .filter(|h| h.view.handle == handle)
            .ok_or_else(|| failure("STALE_HOST_HANDLE"))
    }
    fn authorize_workspace(
        &mut self,
        handle: &str,
        request: &str,
        path: &Path,
    ) -> Result<WorkspaceView, BridgeError> {
        if !path.is_absolute() {
            return Err(failure("INVALID_WORKSPACE_DIRECTORY"));
        }
        let host = self.current(handle)?;
        let view = host
            .journal
            .authorize_workspace(LOCAL_OWNER, request, path, READ_POLICY)
            .map_err(workspace_error)?;
        let grant = host
            .journal
            .open_workspace(LOCAL_OWNER, &view.workspace_id)
            .map_err(workspace_error)?;
        host.grants.insert(view.workspace_id.clone(), grant);
        Ok(project_workspace(host, view))
    }
    fn list_workspaces(
        &mut self,
        handle: &str,
        include_revoked: bool,
    ) -> Result<Vec<WorkspaceView>, BridgeError> {
        let host = self.current(handle)?;
        Ok(host
            .journal
            .workspaces(LOCAL_OWNER, include_revoked)
            .map_err(workspace_error)?
            .into_iter()
            .map(|view| project_workspace(host, view))
            .collect())
    }
    fn restore_workspace(&mut self, handle: &str, id: &str) -> Result<WorkspaceView, BridgeError> {
        let host = self.current(handle)?;
        let grant = host
            .journal
            .open_workspace(LOCAL_OWNER, id)
            .map_err(workspace_error)?;
        host.grants.insert(id.into(), grant);
        Ok(project_workspace(
            host,
            host.journal
                .workspace(LOCAL_OWNER, id)
                .map_err(workspace_error)?,
        ))
    }
    fn revoke_workspace(
        &mut self,
        handle: &str,
        id: &str,
        version: &str,
    ) -> Result<WorkspaceView, BridgeError> {
        let host = self.current(handle)?;
        let view = host
            .journal
            .revoke_workspace(LOCAL_OWNER, id, version)
            .map_err(workspace_error)?;
        host.grants.remove(id);
        Ok(project_workspace(host, view))
    }
    fn list_runs(
        &mut self,
        handle: &str,
        workspace: Option<&str>,
        before: Option<&str>,
        limit: u16,
    ) -> Result<RunPage, BridgeError> {
        let host = self.current(handle)?;
        let page = host
            .journal
            .list_agent_runs(LOCAL_OWNER, workspace, before, limit)
            .map_err(workspace_error)?;
        Ok(RunPage {
            runs: page
                .runs
                .into_iter()
                .map(|r| RunSummary {
                    run_id: r.run_id,
                    workspace_id: r.workspace_id,
                    phase: r.phase,
                    steps: r.steps,
                    invocations: r.invocations,
                    active: r.active,
                })
                .collect(),
            next_cursor: page.next_cursor,
        })
    }
}
// Local application profile only. Never interpreted as a cloud account/team ID.
const LOCAL_OWNER: &str = "desktop-local-profile-v1";
const READ_POLICY: &str = "desktop-read-only-v1";
fn project_workspace(
    host: &Host,
    view: orange_agent_runtime::workspaces::WorkspaceView,
) -> WorkspaceView {
    WorkspaceView {
        session_access: host
            .grants
            .get(&view.workspace_id)
            .is_some_and(|g| !g.is_revoked()),
        workspace_id: view.workspace_id,
        display_path: view.canonical_path,
        permission_version: view.version,
        permission_active: view.active,
    }
}
fn workspace_error(error: WorkspaceStoreError) -> BridgeError {
    let code = match error {
        WorkspaceStoreError::Invalid => "INVALID_WORKSPACE_REQUEST",
        WorkspaceStoreError::NotFound => "WORKSPACE_NOT_FOUND",
        WorkspaceStoreError::Revoked => "WORKSPACE_REVOKED",
        WorkspaceStoreError::Conflict => "WORKSPACE_CONFLICT",
        WorkspaceStoreError::RecoveryRequired => "WORKSPACE_RECOVERY_REQUIRED",
        WorkspaceStoreError::Limit => "WORKSPACE_LIMIT",
        WorkspaceStoreError::Workspace(workspace::WorkspaceError::Forbidden) => {
            "WORKSPACE_PRIVATE_ROOT"
        }
        WorkspaceStoreError::Workspace(workspace::WorkspaceError::EnvironmentChanged) => {
            "WORKSPACE_IDENTITY_CHANGED"
        }
        WorkspaceStoreError::Workspace(
            workspace::WorkspaceError::PersistentIdentityUnavailable,
        ) => "WORKSPACE_IDENTITY_UNAVAILABLE",
        _ => "WORKSPACE_STORAGE_UNAVAILABLE",
    };
    failure(code)
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
pub(crate) fn authorize_workspace(
    handle: String,
    request_id: String,
    selected_directory: String,
) -> Result<WorkspaceView, BridgeError> {
    HOST.lock()
        .map_err(|_| failure("HOST_INTERNAL"))?
        .authorize_workspace(&handle, &request_id, Path::new(&selected_directory))
}
pub(crate) fn list_workspaces(
    handle: String,
    include_revoked: bool,
) -> Result<Vec<WorkspaceView>, BridgeError> {
    HOST.lock()
        .map_err(|_| failure("HOST_INTERNAL"))?
        .list_workspaces(&handle, include_revoked)
}
pub(crate) fn restore_workspace_access(
    handle: String,
    workspace_id: String,
) -> Result<WorkspaceView, BridgeError> {
    HOST.lock()
        .map_err(|_| failure("HOST_INTERNAL"))?
        .restore_workspace(&handle, &workspace_id)
}
pub(crate) fn revoke_workspace(
    handle: String,
    workspace_id: String,
    expected_version: String,
) -> Result<WorkspaceView, BridgeError> {
    HOST.lock()
        .map_err(|_| failure("HOST_INTERNAL"))?
        .revoke_workspace(&handle, &workspace_id, &expected_version)
}
pub(crate) fn list_runs(
    handle: String,
    workspace_id: Option<String>,
    before: Option<String>,
    limit: u16,
) -> Result<RunPage, BridgeError> {
    HOST.lock()
        .map_err(|_| failure("HOST_INTERNAL"))?
        .list_runs(&handle, workspace_id.as_deref(), before.as_deref(), limit)
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
            "ee0e19b3a311cabcd4b58de8201460d19d729873"
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
    #[test]
    fn workspace_consent_survives_but_process_access_must_be_restored() {
        let base = tempfile::tempdir().expect("base");
        let data = base.path().join("data");
        let work = base.path().join("workspace");
        fs::create_dir(&work).expect("work");
        let mut registry = HostRegistry::default();
        let host = registry.initialize(&data).expect("host");
        assert!(
            registry
                .authorize_workspace("forged", "consent", &work)
                .is_err()
        );
        let view = registry
            .authorize_workspace(&host.handle, "consent", &work)
            .expect("explicit test consent");
        assert!(view.permission_active && view.session_access);
        assert_eq!(
            registry
                .authorize_workspace(&host.handle, "consent", &work)
                .expect("duplicate")
                .workspace_id,
            view.workspace_id
        );
        assert!(
            registry
                .authorize_workspace(&host.handle, "private", &data)
                .is_err()
        );
        assert!(
            registry
                .list_runs(&host.handle, Some(&view.workspace_id), None, 100)
                .expect("empty history")
                .runs
                .is_empty()
        );
        registry.close(&host.handle).expect("close");
        let next = registry.initialize(&data).expect("new host");
        let saved = registry
            .list_workspaces(&next.handle, false)
            .expect("saved");
        assert_eq!(saved.len(), 1);
        assert!(saved[0].permission_active);
        assert!(!saved[0].session_access);
        assert!(
            registry
                .restore_workspace(&host.handle, &view.workspace_id)
                .is_err()
        );
        assert!(
            registry
                .restore_workspace(&next.handle, &view.workspace_id)
                .expect("OS permission revalidated by caller fixture")
                .session_access
        );
        assert!(
            registry
                .revoke_workspace(&next.handle, &view.workspace_id, "9")
                .is_err()
        );
        let revoked = registry
            .revoke_workspace(&next.handle, &view.workspace_id, &view.permission_version)
            .expect("revoke");
        assert!(!revoked.permission_active && !revoked.session_access);
        assert_eq!(
            registry
                .restore_workspace(&next.handle, &view.workspace_id)
                .expect_err("no restore")
                .code,
            "WORKSPACE_REVOKED"
        );
        assert_eq!(
            registry
                .authorize_workspace(&next.handle, "consent", &work)
                .expect_err("old consent")
                .code,
            "WORKSPACE_REVOKED"
        );
        let fresh = registry
            .authorize_workspace(&next.handle, "new-consent", &work)
            .expect("new explicit consent");
        assert_ne!(fresh.workspace_id, view.workspace_id);
        assert_eq!(
            registry
                .list_workspaces(&next.handle, true)
                .expect("history")
                .len(),
            2
        );
    }
}
