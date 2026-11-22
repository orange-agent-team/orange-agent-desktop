//! Native Host state is intentionally outside the FRB API namespace.
use crate::api::host::{BridgeError, HostView, RunPage, RunSummary, WorkspaceView};
use orange_agent_runtime::workspaces::WorkspaceStoreError;
use orange_agent_runtime::{Journal, workspace};
use orange_domain::Credits;
use std::{
    fs,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};
use uuid::Uuid;
mod creation;
#[cfg(target_vendor = "apple")]
mod editing;
#[cfg(target_vendor = "apple")]
mod export_inspection;
#[cfg(target_vendor = "apple")]
mod export_restoration;
#[cfg(target_vendor = "apple")]
mod export_retirement;
pub(crate) mod memory;
#[cfg(target_vendor = "apple")]
pub(crate) use export_restoration::*;
#[cfg(target_vendor = "apple")]
pub(crate) use export_retirement::*;
#[cfg(target_vendor = "apple")]
mod recovery;
#[cfg(target_vendor = "apple")]
pub(crate) use export_inspection::{
    authorize_export_inspection, inspect_export_files, suspend_export_inspection,
};
#[cfg(target_vendor = "apple")]
mod retention;
#[cfg(target_vendor = "apple")]
pub(crate) use editing::{approve_editing_tool, preview_editing_tool, start_editing_run};
#[cfg(target_vendor = "apple")]
pub(crate) use editing::{
    authorize_editing_access, list_editing_access, list_unresolved_edits, revoke_editing_access,
    suspend_editing_selection,
};
#[cfg(target_vendor = "apple")]
pub(crate) use recovery::{approve_recovery_decision, prepare_recovery_decision};
#[cfg(target_vendor = "apple")]
pub(crate) use recovery::{
    authorize_recovery_inspection, inspect_recovery, inspect_recovery_outcome,
    suspend_recovery_inspection,
};
#[cfg(target_vendor = "apple")]
pub(crate) use recovery::{authorize_recovery_write_access, suspend_recovery_write_selection};
#[cfg(target_vendor = "apple")]
pub(crate) use retention::{
    approve_export, authorize_export_destination, inspect_export_outcome, list_export_outcomes,
    prepare_export, suspend_export_destination,
};
#[cfg(target_vendor = "apple")]
pub(crate) use retention::{
    approve_retention_archive, authorize_retention_access, inspect_retention,
    prepare_retention_archive, suspend_retention_access,
};
#[cfg(target_vendor = "apple")]
pub(crate) use retention::{inspect_retention_outcome, list_retained_edits};
mod managed;
pub(crate) use creation::{
    authorize_creation_access, list_creation_access, revoke_creation_access,
    suspend_creation_selection,
};
mod llama_memory;
mod runs;
mod skill_packages;
pub(crate) use skill_packages::{
    install_local_package, review_local_package, uninstall_local_package,
};
mod task_memory;
pub(crate) use managed::{
    cancel_model_start, close_model_download, close_model_import, configure_model_service,
    current_model_connection, download_model, import_model, inspect_model_service,
    start_model_service, stop_model_service,
};
pub(crate) use runs::{
    advance_run, answer_user_question, approve_creation_tool, approve_tool, cancel_run,
    connect_local_model, disconnect_local_model, inspect_run, list_local_skills,
    set_local_skill_enabled, start_creation_run, start_interactive_run, start_local_skill_run,
    start_run,
};

pub(crate) fn failure(code: &str) -> BridgeError {
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
    access_tokens: std::collections::HashMap<String, String>,
    creations: std::collections::HashMap<String, creation::CreationSession>,
    memories: std::collections::HashMap<String, memory::MemorySession>,
    #[cfg(target_vendor = "apple")]
    editings: std::collections::HashMap<String, editing::EditingSession>,
    #[cfg(target_vendor = "apple")]
    recovery_inspections: std::collections::HashMap<String, recovery::InspectionSession>,
    #[cfg(target_vendor = "apple")]
    recovery_writes: std::collections::HashMap<String, recovery::WriteSession>,
    #[cfg(target_vendor = "apple")]
    retentions: std::collections::HashMap<String, retention::RetentionSession>,
    #[cfg(target_vendor = "apple")]
    exports: std::collections::HashMap<String, retention::ExportSession>,
    #[cfg(target_vendor = "apple")]
    export_checks: std::collections::HashMap<String, export_inspection::InspectionSession>,
    #[cfg(target_vendor = "apple")]
    export_retirements: std::collections::HashMap<String, export_retirement::RetirementSession>,
    #[cfg(target_vendor = "apple")]
    export_restorations: std::collections::HashMap<String, export_restoration::RestorationSession>,
    #[cfg(target_vendor = "apple")]
    run_edit_grants: std::collections::HashMap<
        String,
        orange_agent_runtime::workspace::patch::authority::EditFileGrant,
    >,
    model: Option<runs::ModelConnection>,
    service: Option<crate::service::Client>,
    task_memory: std::collections::HashMap<String, task_memory::TaskMemory>,
    run_grants: std::collections::HashMap<String, workspace::WorkspaceGrant>,
}
#[derive(Default)]
pub(crate) struct HostRegistry {
    host: Option<Host>,
    pub(crate) signals: Arc<Mutex<crate::actor::Signals>>,
}
impl HostRegistry {
    pub(crate) fn with_signals(signals: Arc<Mutex<crate::actor::Signals>>) -> Self {
        Self {
            host: None,
            signals,
        }
    }
    pub(crate) fn initialize(&mut self, path: &Path) -> Result<HostView, BridgeError> {
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
        let journal = Journal::open(&root.join("host.sqlite")).map_err(|error| {
            failure(match error {
                orange_agent_runtime::JournalError::Busy => "HOST_BUSY",
                _ => "PRIVATE_STORAGE_OR_HOST_LOCK",
            })
        })?;
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
            available_edit_tools: if cfg!(target_vendor = "apple") {
                vec!["apply_patch".into()]
            } else {
                vec![]
            },
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
            access_tokens: std::collections::HashMap::new(),
            creations: std::collections::HashMap::new(),
            memories: std::collections::HashMap::new(),
            #[cfg(target_vendor = "apple")]
            editings: std::collections::HashMap::new(),
            #[cfg(target_vendor = "apple")]
            recovery_inspections: std::collections::HashMap::new(),
            #[cfg(target_vendor = "apple")]
            recovery_writes: std::collections::HashMap::new(),
            #[cfg(target_vendor = "apple")]
            retentions: std::collections::HashMap::new(),
            #[cfg(target_vendor = "apple")]
            exports: std::collections::HashMap::new(),
            #[cfg(target_vendor = "apple")]
            export_checks: std::collections::HashMap::new(),
            #[cfg(target_vendor = "apple")]
            export_retirements: std::collections::HashMap::new(),
            #[cfg(target_vendor = "apple")]
            export_restorations: std::collections::HashMap::new(),
            #[cfg(target_vendor = "apple")]
            run_edit_grants: std::collections::HashMap::new(),
            model: None,
            service: None,
            task_memory: Default::default(),
            run_grants: std::collections::HashMap::new(),
        });
        Ok(view)
    }
    #[cfg(test)]
    fn inspect(&self, handle: &str) -> Result<HostView, BridgeError> {
        let host = self
            .host
            .as_ref()
            .filter(|h| h.view.handle == handle)
            .ok_or_else(|| failure("STALE_HOST_HANDLE"))?;
        Ok(host.view.clone())
    }
    #[cfg(test)]
    fn close(&mut self, handle: &str) -> Result<(), BridgeError> {
        self.inspect(handle)?;
        self.signals
            .lock()
            .map_err(|_| failure("HOST_INTERNAL"))?
            .stop_all();
        self.host.take();
        Ok(())
    }
    #[cfg(test)]
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
        let signals = self.signals.clone();
        let host = self.current(handle)?;
        {
            let controls = signals.lock().map_err(|_| failure("HOST_INTERNAL"))?;
            if controls.closed_selections.contains(request) {
                return Err(failure("WORKSPACE_SELECTION_CLOSED"));
            }
            if controls.closed_selections.len() >= 8192 {
                return Err(failure("WORKSPACE_SELECTION_LIMIT"));
            }
        }
        let view = host
            .journal
            .authorize_workspace(LOCAL_OWNER, request, path, READ_POLICY)
            .map_err(workspace_error)?;
        let grant = host
            .journal
            .open_workspace(LOCAL_OWNER, &view.workspace_id)
            .map_err(workspace_error)?;
        let revoker = host
            .journal
            .workspace_revoker(LOCAL_OWNER, &view.workspace_id)
            .map_err(workspace_error)?;
        let mut controls = signals.lock().map_err(|_| failure("HOST_INTERNAL"))?;
        if controls.closed_selections.contains(request) || controls.closed_selections.len() >= 8192
        {
            grant.request_revoke();
            return Err(failure("WORKSPACE_SELECTION_CLOSED"));
        }
        let session_token = request.to_owned();
        host.grants.insert(view.workspace_id.clone(), grant.clone());
        host.access_tokens
            .insert(view.workspace_id.clone(), session_token.clone());
        controls.workspaces.insert(
            view.workspace_id.clone(),
            crate::actor::WorkspaceSignal {
                version: view.version.clone(),
                session_token,
                revoker,
                grant,
            },
        );
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
        let signals = self.signals.clone();
        let host = self.current(handle)?;
        let grant = host
            .journal
            .open_workspace(LOCAL_OWNER, id)
            .map_err(workspace_error)?;
        host.grants.insert(id.into(), grant.clone());
        let session_token = Uuid::new_v4().to_string();
        host.access_tokens.insert(id.into(), session_token.clone());
        let view = host
            .journal
            .workspace(LOCAL_OWNER, id)
            .map_err(workspace_error)?;
        let revoker = host
            .journal
            .workspace_revoker(LOCAL_OWNER, id)
            .map_err(workspace_error)?;
        signals
            .lock()
            .map_err(|_| failure("HOST_INTERNAL"))?
            .workspaces
            .insert(
                id.into(),
                crate::actor::WorkspaceSignal {
                    version: view.version.clone(),
                    session_token,
                    revoker,
                    grant,
                },
            );
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
        let signals = self.signals.clone();
        let host = self.current(handle)?;
        let view = host
            .journal
            .revoke_workspace(LOCAL_OWNER, id, version)
            .map_err(workspace_error)?;
        host.grants.remove(id);
        host.access_tokens.remove(id);
        signals
            .lock()
            .map_err(|_| failure("HOST_INTERNAL"))?
            .workspaces
            .remove(id);
        Ok(project_workspace(host, view))
    }
    fn suspend_workspace(
        &mut self,
        handle: &str,
        id: &str,
        token: &str,
    ) -> Result<WorkspaceView, BridgeError> {
        use orange_agent_runtime::engine::Phase;
        let signals = self.signals.clone();
        let host = self.current(handle)?;
        let view = host
            .journal
            .workspace(LOCAL_OWNER, id)
            .map_err(workspace_error)?;
        if host
            .access_tokens
            .get(id)
            .is_some_and(|current| current != token)
        {
            return Err(failure("WORKSPACE_SESSION_CHANGED"));
        }
        let runs: Vec<String> = signals
            .lock()
            .map_err(|_| failure("HOST_INTERNAL"))?
            .runs
            .iter()
            .filter(|(_, run)| run.workspace == id)
            .map(|(id, _)| id.clone())
            .collect();
        for run in &runs {
            if let Some(grant) = host.run_grants.get(run) {
                grant.request_revoke();
            }
            let state = host
                .journal
                .agent_view(LOCAL_OWNER, run)
                .map_err(|_| failure("RUN_STORAGE_UNAVAILABLE"))?;
            if matches!(
                state.phase,
                Phase::Ready | Phase::ModelPending | Phase::ToolsPending | Phase::AwaitingUser
            ) {
                host.journal
                    .cancel_agent_run(LOCAL_OWNER, run)
                    .map_err(|_| failure("RUN_STORAGE_UNAVAILABLE"))?;
            }
        }
        for run in &runs {
            host.run_grants.remove(run);
        }
        if let Some(grant) = host.grants.remove(id) {
            grant.request_revoke();
        }
        host.access_tokens.remove(id);
        let mut controls = signals.lock().map_err(|_| failure("HOST_INTERNAL"))?;
        controls.workspaces.remove(id);
        for run in runs {
            controls.runs.remove(&run);
        }
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
        session_token: host
            .grants
            .get(&view.workspace_id)
            .filter(|g| !g.is_revoked())
            .and_then(|_| host.access_tokens.get(&view.workspace_id))
            .cloned(),
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
    crate::actor::initialize(&directory)
}
pub(crate) fn inspect_host(handle: String) -> Result<HostView, BridgeError> {
    crate::actor::inspect(&handle)
}
pub(crate) fn close_host(handle: String) -> Result<(), BridgeError> {
    crate::actor::close(&handle)
}
pub(crate) fn validate_amount(handle: String, value: String) -> Result<String, BridgeError> {
    crate::actor::inspect(&handle)?;
    if value.len() > 19 {
        return Err(failure("INVALID_AMOUNT"));
    }
    value
        .parse::<Credits>()
        .map(|v| v.to_string())
        .map_err(|_| failure("INVALID_AMOUNT"))
}
pub(crate) async fn authorize_workspace(
    handle: String,
    request_id: String,
    selected_directory: String,
) -> Result<WorkspaceView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, _| {
        host.authorize_workspace(&handle, &request_id, Path::new(&selected_directory))
    })
    .await
}
pub(crate) async fn list_workspaces(
    handle: String,
    include_revoked: bool,
) -> Result<Vec<WorkspaceView>, BridgeError> {
    crate::actor::call(handle.clone(), move |host, _| {
        host.list_workspaces(&handle, include_revoked)
    })
    .await
}
pub(crate) async fn restore_workspace_access(
    handle: String,
    workspace_id: String,
) -> Result<WorkspaceView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, _| {
        host.restore_workspace(&handle, &workspace_id)
    })
    .await
}
pub(crate) async fn suspend_workspace_access(
    handle: String,
    workspace_id: String,
    session_token: String,
) -> Result<WorkspaceView, BridgeError> {
    crate::actor::signal_suspend(&handle, &workspace_id, &session_token)?;
    crate::actor::call(handle.clone(), move |host, rt| {
        let creation_leases = host.workspace_creation_leases(&handle, &workspace_id)?;
        #[cfg(target_vendor = "apple")]
        let editing_leases = host.workspace_editing_leases(&handle, &workspace_id)?;
        #[cfg(target_vendor = "apple")]
        let recovery_leases = host.workspace_recovery_leases(&handle, &workspace_id)?;
        let view = host.suspend_workspace(&handle, &workspace_id, &session_token)?;
        rt.block_on(async {
            #[cfg(target_vendor = "apple")]
            for grant in editing_leases {
                grant.wait_drained().await;
            }
            #[cfg(target_vendor = "apple")]
            for grant in recovery_leases {
                grant.wait_drained().await;
            }
            for grant in creation_leases {
                grant.wait_drained().await;
            }
        });
        Ok(view)
    })
    .await
}
pub(crate) async fn suspend_workspace_selection(
    handle: String,
    request_id: String,
) -> Result<(), BridgeError> {
    let Some(workspace) = crate::actor::signal_release_selection(&handle, &request_id)? else {
        return Ok(());
    };
    crate::actor::call(handle.clone(), move |host, rt| {
        let creation_leases = host.workspace_creation_leases(&handle, &workspace)?;
        #[cfg(target_vendor = "apple")]
        let editing_leases = host.workspace_editing_leases(&handle, &workspace)?;
        #[cfg(target_vendor = "apple")]
        let recovery_leases = host.workspace_recovery_leases(&handle, &workspace)?;
        match host.suspend_workspace(&handle, &workspace, &request_id) {
            Ok(_) => {
                rt.block_on(async {
                    #[cfg(target_vendor = "apple")]
                    for grant in editing_leases {
                        grant.wait_drained().await;
                    }
                    #[cfg(target_vendor = "apple")]
                    for grant in recovery_leases {
                        grant.wait_drained().await;
                    }
                    for grant in creation_leases {
                        grant.wait_drained().await;
                    }
                });
                Ok(())
            }
            Err(error) if error.code == "WORKSPACE_SESSION_CHANGED" => Ok(()),
            Err(error) => Err(error),
        }
    })
    .await
}
pub(crate) async fn revoke_workspace(
    handle: String,
    workspace_id: String,
    expected_version: String,
) -> Result<WorkspaceView, BridgeError> {
    crate::actor::signal_revoke(&handle, &workspace_id, &expected_version)?;
    crate::actor::call(handle.clone(), move |host, rt| {
        let creation_leases = host.workspace_creation_leases(&handle, &workspace_id)?;
        #[cfg(target_vendor = "apple")]
        let editing_leases = host.workspace_editing_leases(&handle, &workspace_id)?;
        #[cfg(target_vendor = "apple")]
        let recovery_leases = host.workspace_recovery_leases(&handle, &workspace_id)?;
        let view = host.revoke_workspace(&handle, &workspace_id, &expected_version)?;
        rt.block_on(async {
            #[cfg(target_vendor = "apple")]
            for grant in editing_leases {
                grant.wait_drained().await;
            }
            #[cfg(target_vendor = "apple")]
            for grant in recovery_leases {
                grant.wait_drained().await;
            }
            for grant in creation_leases {
                grant.wait_drained().await;
            }
        });
        Ok(view)
    })
    .await
}
pub(crate) async fn list_runs(
    handle: String,
    workspace_id: Option<String>,
    before: Option<String>,
    limit: u16,
) -> Result<RunPage, BridgeError> {
    crate::actor::call(handle.clone(), move |host, _| {
        host.list_runs(&handle, workspace_id.as_deref(), before.as_deref(), limit)
    })
    .await
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
            "938bc63654127951ae52810ba91f44af4eafecf2"
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
