use super::*;
use crate::api::host::CreationAccessView;
use orange_agent_runtime::workspace::creation::{
    CreateFileError, CreateFileGrant, CreationConsentView,
};
use std::sync::atomic::{AtomicBool, Ordering};

pub(super) struct CreationSession {
    pub workspace: String,
    pub token: String,
    pub grant: CreateFileGrant,
    pub available: Arc<AtomicBool>,
}
fn creation_error(error: CreateFileError) -> BridgeError {
    failure(match error {
        CreateFileError::Unknown => "WORKSPACE_RECOVERY_REQUIRED",
        CreateFileError::Workspace(workspace::WorkspaceError::Revoked) => {
            "CREATION_PERMISSION_REVOKED"
        }
        CreateFileError::Workspace(workspace::WorkspaceError::Forbidden) => {
            "WORKSPACE_PRIVATE_ROOT"
        }
        CreateFileError::Workspace(workspace::WorkspaceError::EnvironmentChanged) => {
            "WORKSPACE_IDENTITY_CHANGED"
        }
        CreateFileError::Journal(orange_agent_runtime::JournalError::Conflict) => {
            "CREATION_PERMISSION_CHANGED"
        }
        _ => "CREATION_PERMISSION_UNAVAILABLE",
    })
}
fn project(host: &Host, workspace: &str, view: CreationConsentView) -> CreationAccessView {
    CreationAccessView {
        session_token: host
            .creations
            .get(&view.consent_id)
            .filter(|s| {
                s.workspace == workspace && s.available.load(Ordering::Acquire) && view.active
            })
            .map(|s| s.token.clone()),
        consent_id: view.consent_id,
        workspace_id: workspace.into(),
        display_path: view.canonical_path,
        permission_version: view.version,
        permission_active: view.active,
    }
}
impl HostRegistry {
    pub(super) async fn authorize_creation(
        &mut self,
        handle: &str,
        workspace: &str,
        request: &str,
        selected: &Path,
    ) -> Result<CreationAccessView, BridgeError> {
        if !orange_protocol::valid_id(request) || !selected.is_absolute() || selected.is_symlink() {
            return Err(failure("INVALID_CREATION_REQUEST"));
        }
        let signals = self.signals.clone();
        {
            let controls = signals.lock().map_err(|_| failure("HOST_INTERNAL"))?;
            if controls.closed_creation_selections.contains(request)
                || controls.closed_creation_selections.len() >= 8192
            {
                return Err(failure("CREATION_SELECTION_CLOSED"));
            }
        }
        let host = self.current(handle)?;
        let read = host
            .grants
            .get(workspace)
            .filter(|g| !g.is_revoked())
            .ok_or_else(|| failure("WORKSPACE_SESSION_ACCESS_REQUIRED"))?
            .clone();
        let owned = host
            .journal
            .workspace(LOCAL_OWNER, workspace)
            .map_err(workspace_error)?;
        if !owned.active
            || selected
                .canonicalize()
                .map_err(|_| failure("WORKSPACE_IDENTITY_CHANGED"))?
                != Path::new(&owned.canonical_path)
        {
            return Err(failure("CREATION_WORKSPACE_MISMATCH"));
        }
        let grant = host
            .journal
            .authorize_file_creation(LOCAL_OWNER, request, READ_POLICY, selected)
            .map_err(creation_error)?;
        if grant.resource_identity() != read.resource_identity() {
            grant.request_revoke();
            host.journal
                .revoke_file_creation(LOCAL_OWNER, grant.consent_id(), &grant.consent_version())
                .map_err(creation_error)?;
            return Err(failure("WORKSPACE_IDENTITY_CHANGED"));
        }
        let id = grant.consent_id().to_owned();
        let view = host
            .journal
            .creation_consent(LOCAL_OWNER, &id)
            .map_err(creation_error)?;
        let revoker = host
            .journal
            .creation_revoker(LOCAL_OWNER, &id)
            .map_err(creation_error)?;
        if let Some(previous) = host.creations.get(&id)
            && previous.token != request
        {
            previous.available.store(false, Ordering::Release);
            previous.grant.request_revoke();
            previous.grant.wait_drained().await;
        }
        let available = Arc::new(AtomicBool::new(true));
        {
            let mut controls = signals.lock().map_err(|_| failure("HOST_INTERNAL"))?;
            if controls.closed_creation_selections.contains(request)
                || controls.closed_creation_selections.len() >= 8192
                || read.is_revoked()
            {
                grant.request_revoke();
                return Err(failure("CREATION_SELECTION_CLOSED"));
            }
            controls.creations.insert(
                id.clone(),
                crate::actor::CreationSignal {
                    workspace: workspace.into(),
                    version: view.version.clone(),
                    token: request.into(),
                    grant: grant.clone(),
                    revoker,
                    available: available.clone(),
                },
            );
        }
        host.creations.insert(
            id,
            CreationSession {
                workspace: workspace.into(),
                token: request.into(),
                grant,
                available,
            },
        );
        Ok(project(host, workspace, view))
    }
    fn list_creation(
        &mut self,
        handle: &str,
        workspace: &str,
    ) -> Result<Vec<CreationAccessView>, BridgeError> {
        let host = self.current(handle)?;
        let read = host
            .journal
            .workspace(LOCAL_OWNER, workspace)
            .map_err(workspace_error)?;
        Ok(host
            .journal
            .creation_consents(LOCAL_OWNER)
            .map_err(creation_error)?
            .into_iter()
            .filter(|c| c.resource_identity == read.resource_identity && c.policy == read.policy)
            .map(|c| project(host, workspace, c))
            .collect())
    }
    async fn suspend_creation(
        &mut self,
        handle: &str,
        id: &str,
        token: &str,
    ) -> Result<(), BridgeError> {
        let signals = self.signals.clone();
        let host = self.current(handle)?;
        if let Some(current) = host.creations.get(id) {
            if current.token != token {
                return Ok(());
            }
            current.available.store(false, Ordering::Release);
            current.grant.request_revoke();
            current.grant.wait_drained().await;
        }
        // Only runs bound to this exact consent become durably cancelled.
        let runs: Vec<String> = host.run_grants.keys().cloned().collect();
        for run in runs {
            if host
                .journal
                .agent_creation_requirement(LOCAL_OWNER, &run)
                .map_err(runs::engine_error)?
                .is_some_and(|r| r.consent_id == id)
            {
                let view = host
                    .journal
                    .agent_view(LOCAL_OWNER, &run)
                    .map_err(runs::engine_error)?;
                if matches!(
                    view.phase,
                    orange_agent_runtime::engine::Phase::Ready
                        | orange_agent_runtime::engine::Phase::ModelPending
                        | orange_agent_runtime::engine::Phase::ToolsPending
                        | orange_agent_runtime::engine::Phase::AwaitingUser
                ) {
                    host.journal
                        .cancel_agent_run(LOCAL_OWNER, &run)
                        .map_err(runs::engine_error)?;
                }
            }
        }
        host.creations.remove(id);
        signals
            .lock()
            .map_err(|_| failure("HOST_INTERNAL"))?
            .creations
            .remove(id);
        Ok(())
    }
    pub(super) fn workspace_creation_leases(
        &mut self,
        handle: &str,
        workspace: &str,
    ) -> Result<Vec<CreateFileGrant>, BridgeError> {
        Ok(self
            .current(handle)?
            .creations
            .values()
            .filter(|c| c.workspace == workspace)
            .map(|c| c.grant.clone())
            .collect())
    }
    async fn revoke_creation(
        &mut self,
        handle: &str,
        id: &str,
        version: &str,
    ) -> Result<(), BridgeError> {
        let token = self
            .current(handle)?
            .creations
            .get(id)
            .map(|s| s.token.clone());
        self.current(handle)?
            .journal
            .revoke_file_creation(LOCAL_OWNER, id, version)
            .map_err(creation_error)?;
        if let Some(token) = token {
            self.suspend_creation(handle, id, &token).await?;
        }
        Ok(())
    }
}
pub(crate) async fn authorize_creation_access(
    handle: String,
    workspace: String,
    request: String,
    selected: String,
) -> Result<CreationAccessView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.authorize_creation(&handle, &workspace, &request, Path::new(&selected)))
    })
    .await
}
pub(crate) async fn list_creation_access(
    handle: String,
    workspace: String,
) -> Result<Vec<CreationAccessView>, BridgeError> {
    crate::actor::call(handle.clone(), move |host, _| {
        host.list_creation(&handle, &workspace)
    })
    .await
}
pub(crate) async fn suspend_creation_selection(
    handle: String,
    request: String,
) -> Result<(), BridgeError> {
    let Some(id) = crate::actor::signal_creation_release(&handle, &request)? else {
        return Ok(());
    };
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.suspend_creation(&handle, &id, &request))
    })
    .await
}
pub(crate) async fn revoke_creation_access(
    handle: String,
    id: String,
    version: String,
) -> Result<(), BridgeError> {
    crate::actor::signal_creation_revoke(&handle, &id, &version)?;
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.revoke_creation(&handle, &id, &version))
    })
    .await
}

pub(super) fn run_creation(host: &Host, run: &str) -> Result<Option<CreateFileGrant>, BridgeError> {
    let Some(required) = host
        .journal
        .agent_creation_requirement(LOCAL_OWNER, run)
        .map_err(runs::engine_error)?
    else {
        return Ok(None);
    };
    let current = host
        .creations
        .get(&required.consent_id)
        .filter(|s| s.available.load(Ordering::Acquire))
        .ok_or_else(|| failure("CREATION_SESSION_ACCESS_REQUIRED"))?;
    if current.grant.consent_version() != required.version
        || current.grant.environment() != required.environment
    {
        return Err(failure("CREATION_PERMISSION_CHANGED"));
    }
    Ok(Some(current.grant.clone()))
}
