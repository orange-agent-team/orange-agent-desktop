use super::*;
use crate::api::host::EditingAccessView;
use orange_agent_runtime::workspace::patch::{
    PatchError,
    authority::{EditConsentView, EditFileGrant},
};
use std::sync::atomic::{AtomicBool, Ordering};

pub(crate) async fn list_unresolved_edits(
    handle: String,
    run: String,
    before: Option<String>,
    limit: u16,
) -> Result<Vec<String>, BridgeError> {
    crate::actor::call(handle.clone(), move |registry, _| {
        // Deliberately do not use run_context: it restores execution/read
        // grants, while an unresolved effect must remain discoverable even
        // after native access has been released. Only opaque IDs leave here.
        registry
            .current(&handle)?
            .journal
            .agent_unresolved_patch_ids(LOCAL_OWNER, &run, before.as_deref(), limit)
            .map_err(runs::engine_error)
    })
    .await
}

pub(super) struct EditingSession {
    pub workspace: String,
    pub token: String,
    pub grant: EditFileGrant,
    pub available: Arc<AtomicBool>,
}
fn editing_error(error: PatchError) -> BridgeError {
    failure(match error {
        PatchError::RecoveryRequired => "WORKSPACE_RECOVERY_REQUIRED",
        PatchError::Workspace(workspace::WorkspaceError::Revoked) => "EDITING_PERMISSION_REVOKED",
        PatchError::Workspace(workspace::WorkspaceError::Forbidden) => "WORKSPACE_PRIVATE_ROOT",
        PatchError::Workspace(workspace::WorkspaceError::EnvironmentChanged) => {
            "WORKSPACE_IDENTITY_CHANGED"
        }
        PatchError::Journal(orange_agent_runtime::JournalError::Conflict) => {
            "EDITING_PERMISSION_CHANGED"
        }
        _ => "EDITING_PERMISSION_UNAVAILABLE",
    })
}
fn project(host: &Host, workspace: &str, view: EditConsentView) -> EditingAccessView {
    EditingAccessView {
        session_token: host
            .editings
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
    pub(super) async fn authorize_editing(
        &mut self,
        handle: &str,
        workspace: &str,
        request: &str,
        selected: &Path,
    ) -> Result<EditingAccessView, BridgeError> {
        if !orange_protocol::valid_id(request) || !selected.is_absolute() || selected.is_symlink() {
            return Err(failure("INVALID_EDITING_REQUEST"));
        }
        let signals = self.signals.clone();
        {
            let controls = signals.lock().map_err(|_| failure("HOST_INTERNAL"))?;
            if controls.closed_editing_selections.contains(request)
                || controls.closed_editing_selections.len() >= 8192
            {
                return Err(failure("EDITING_SELECTION_CLOSED"));
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
            return Err(failure("EDITING_WORKSPACE_MISMATCH"));
        }
        let grant = host
            .journal
            .authorize_file_edit(LOCAL_OWNER, request, READ_POLICY, selected)
            .map_err(editing_error)?;
        if grant.resource_identity() != read.resource_identity() {
            grant.request_revoke();
            host.journal
                .revoke_file_edit(
                    LOCAL_OWNER,
                    grant.consent_id(),
                    &grant
                        .consent_version()
                        .ok_or_else(|| failure("EDITING_PERMISSION_CHANGED"))?,
                )
                .map_err(editing_error)?;
            return Err(failure("WORKSPACE_IDENTITY_CHANGED"));
        }
        let id = grant.consent_id().to_owned();
        let view = host
            .journal
            .editing_consent(LOCAL_OWNER, &id)
            .map_err(editing_error)?;
        let revoker = host
            .journal
            .editing_revoker(LOCAL_OWNER, &id)
            .map_err(editing_error)?;
        if let Some(previous) = host.editings.get(&id)
            && previous.token != request
        {
            signals
                .lock()
                .map_err(|_| failure("HOST_INTERNAL"))?
                .closed_editing_selections
                .insert(previous.token.clone());
            previous.available.store(false, Ordering::Release);
            previous.grant.request_revoke();
            previous.grant.wait_drained().await;
            close_run_grants(host, &id, &signals).await?;
        }
        let available = Arc::new(AtomicBool::new(true));
        {
            let mut controls = signals.lock().map_err(|_| failure("HOST_INTERNAL"))?;
            if controls.closed_editing_selections.contains(request)
                || controls.closed_editing_selections.len() >= 8192
                || read.is_revoked()
            {
                grant.request_revoke();
                return Err(failure("EDITING_SELECTION_CLOSED"));
            }
            controls.editings.insert(
                id.clone(),
                crate::actor::EditingSignal {
                    workspace: workspace.into(),
                    version: view.version.clone(),
                    token: request.into(),
                    grant: grant.clone(),
                    revoker,
                    available: available.clone(),
                },
            );
        }
        host.editings.insert(
            id,
            EditingSession {
                workspace: workspace.into(),
                token: request.into(),
                grant,
                available,
            },
        );
        Ok(project(host, workspace, view))
    }
    fn list_editing(
        &mut self,
        handle: &str,
        workspace: &str,
    ) -> Result<Vec<EditingAccessView>, BridgeError> {
        let host = self.current(handle)?;
        let read = host
            .journal
            .workspace(LOCAL_OWNER, workspace)
            .map_err(workspace_error)?;
        Ok(host
            .journal
            .editing_consents(LOCAL_OWNER)
            .map_err(editing_error)?
            .into_iter()
            .filter(|c| c.resource_identity == read.resource_identity && c.policy == read.policy)
            .map(|c| project(host, workspace, c))
            .collect())
    }
    async fn suspend_editing(
        &mut self,
        handle: &str,
        id: &str,
        token: &str,
    ) -> Result<(), BridgeError> {
        let signals = self.signals.clone();
        let host = self.current(handle)?;
        if let Some(current) = host.editings.get(id) {
            if current.token != token {
                return Ok(());
            }
            current.available.store(false, Ordering::Release);
            current.grant.request_revoke();
            current.grant.wait_drained().await;
        }
        close_run_grants(host, id, &signals).await?;
        // Only runs bound to this exact consent become durably cancelled.
        let runs: Vec<String> = host.run_grants.keys().cloned().collect();
        for run in runs {
            if host
                .journal
                .agent_edit_requirement(LOCAL_OWNER, &run)
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
        host.editings.remove(id);
        signals
            .lock()
            .map_err(|_| failure("HOST_INTERNAL"))?
            .editings
            .remove(id);
        Ok(())
    }
    pub(super) fn workspace_editing_leases(
        &mut self,
        handle: &str,
        workspace: &str,
    ) -> Result<Vec<EditFileGrant>, BridgeError> {
        let host = self.current(handle)?;
        let mut grants: Vec<_> = host
            .editings
            .values()
            .filter(|e| e.workspace == workspace)
            .map(|e| e.grant.clone())
            .collect();
        let ids = grants
            .iter()
            .map(|e| e.consent_id().to_owned())
            .collect::<std::collections::HashSet<_>>();
        grants.extend(
            host.run_edit_grants
                .values()
                .filter(|e| ids.contains(e.consent_id()))
                .cloned(),
        );
        Ok(grants)
    }
    async fn revoke_editing(
        &mut self,
        handle: &str,
        id: &str,
        version: &str,
    ) -> Result<(), BridgeError> {
        let token = self
            .current(handle)?
            .editings
            .get(id)
            .map(|s| s.token.clone());
        self.current(handle)?
            .journal
            .revoke_file_edit(LOCAL_OWNER, id, version)
            .map_err(editing_error)?;
        if let Some(token) = token {
            self.suspend_editing(handle, id, &token).await?;
        }
        Ok(())
    }
}
pub(crate) async fn authorize_editing_access(
    handle: String,
    workspace: String,
    request: String,
    selected: String,
) -> Result<EditingAccessView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.authorize_editing(&handle, &workspace, &request, Path::new(&selected)))
    })
    .await
}
pub(crate) async fn list_editing_access(
    handle: String,
    workspace: String,
) -> Result<Vec<EditingAccessView>, BridgeError> {
    crate::actor::call(handle.clone(), move |host, _| {
        host.list_editing(&handle, &workspace)
    })
    .await
}
pub(crate) async fn suspend_editing_selection(
    handle: String,
    request: String,
) -> Result<(), BridgeError> {
    let Some(id) = crate::actor::signal_editing_release(&handle, &request)? else {
        return Ok(());
    };
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.suspend_editing(&handle, &id, &request))
    })
    .await
}
pub(crate) async fn revoke_editing_access(
    handle: String,
    id: String,
    version: String,
) -> Result<(), BridgeError> {
    crate::actor::signal_editing_revoke(&handle, &id, &version)?;
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.revoke_editing(&handle, &id, &version))
    })
    .await
}

pub(super) fn run_editing(
    host: &mut Host,
    run: &str,
    signals: &Arc<Mutex<crate::actor::Signals>>,
) -> Result<Option<EditFileGrant>, BridgeError> {
    let Some(required) = host
        .journal
        .agent_edit_requirement(LOCAL_OWNER, run)
        .map_err(runs::engine_error)?
    else {
        return Ok(None);
    };
    let current = host
        .editings
        .get(&required.consent_id)
        .filter(|s| s.available.load(Ordering::Acquire))
        .ok_or_else(|| failure("EDITING_SESSION_ACCESS_REQUIRED"))?;
    if current.grant.consent_version().as_deref() != Some(required.version.as_str())
        || current.grant.environment() != required.environment
    {
        return Err(failure("EDITING_PERMISSION_CHANGED"));
    }
    let token = current.token.clone();
    let available = current.available.clone();
    if !host.run_edit_grants.contains_key(run) {
        let grant = host
            .journal
            .restore_file_edit(LOCAL_OWNER, &required.consent_id)
            .map_err(editing_error)?;
        let mut controls = signals.lock().map_err(|_| failure("HOST_INTERNAL"))?;
        if !available.load(Ordering::Acquire) || controls.closed_editing_selections.contains(&token)
        {
            grant.request_revoke();
            return Err(failure("EDITING_SELECTION_CLOSED"));
        }
        let signal = controls
            .runs
            .get_mut(run)
            .ok_or_else(|| failure("RUN_CONTEXT_UNAVAILABLE"))?;
        signal.editing_grant = Some(grant.clone());
        host.run_edit_grants.insert(run.into(), grant);
    }
    Ok(host.run_edit_grants.get(run).cloned())
}

pub(crate) async fn start_editing_run(
    handle: String,
    workspace: String,
    request: String,
    prompt: String,
    editing: crate::api::host::RunPermissionSelection,
    creation: Option<crate::api::host::RunPermissionSelection>,
    interactive: bool,
) -> Result<crate::api::host::AgentRunView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(
            host.start_run_mode(
                &handle,
                &workspace,
                &request,
                &prompt,
                interactive,
                runs::WriteSelection {
                    memory: None,
                    creation: creation
                        .as_ref()
                        .map(|s| (s.consent_id.as_str(), s.permission_version.as_str())),
                    editing: Some((&editing.consent_id, &editing.permission_version)),
                },
            ),
        )
    })
    .await
}
impl HostRegistry {
    async fn editing_preview(
        &mut self,
        handle: &str,
        run: &str,
        operation: &str,
    ) -> Result<crate::api::host::EditPreviewView, BridgeError> {
        let (_, _, read, _) = self.run_context(handle, run)?;
        let signals = self.signals.clone();
        let host = self.current(handle)?;
        let edit = run_editing(host, run, &signals)?
            .ok_or_else(|| failure("EDITING_SESSION_ACCESS_REQUIRED"))?;
        let create = super::creation::run_creation(host, run)?;
        let memory = host.task_memory.get(run).cloned().unwrap_or_default();
        let mut authority = memory.authority(&read).with_editing(&edit);
        if let Some(create) = &create {
            authority = authority.with_creation(create);
        }
        let review = host
            .journal
            .agent_patch_preview_authorized(LOCAL_OWNER, run, operation, authority)
            .await
            .map_err(runs::engine_error)?;
        let p = review.preview;
        Ok(crate::api::host::EditPreviewView {
            run_id: run.into(),
            operation_id: review.operation_id,
            preview_digest: review.preview_digest,
            argument_digest: p.argument_digest,
            path: p.path,
            diff: p.diff,
            original_sha256: p.original_sha256,
            result_sha256: p.result_sha256,
            original_bytes: p.original_bytes,
            result_bytes: p.result_bytes,
            added_lines: p.added_lines,
            removed_lines: p.removed_lines,
        })
    }
    async fn editing_approve(
        &mut self,
        handle: &str,
        run: &str,
        operation: &str,
        digest: &str,
    ) -> Result<crate::api::host::AgentRunView, BridgeError> {
        let (_, config, read, _) = self.run_context(handle, run)?;
        let signals = self.signals.clone();
        let host = self.current(handle)?;
        let edit = run_editing(host, run, &signals)?
            .ok_or_else(|| failure("EDITING_SESSION_ACCESS_REQUIRED"))?;
        let create = super::creation::run_creation(host, run)?;
        let memory = host.task_memory.get(run).cloned().unwrap_or_default();
        let mut authority = memory.authority(&read).with_editing(&edit);
        if let Some(create) = &create {
            authority = authority.with_creation(create);
        }
        host.journal
            .approve_agent_editing_authorized(
                LOCAL_OWNER,
                run,
                orange_agent_runtime::engine::EditingApproval {
                    operation_id: operation,
                    preview_digest: digest,
                    expires_at: (runs::now()? + 60).min(config.deadline_unix),
                },
                authority,
            )
            .await
            .map_err(runs::engine_error)?;
        self.inspect_run(handle, run).await
    }
}
pub(crate) async fn preview_editing_tool(
    handle: String,
    run: String,
    operation: String,
) -> Result<crate::api::host::EditPreviewView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.editing_preview(&handle, &run, &operation))
    })
    .await
}
pub(crate) async fn approve_editing_tool(
    handle: String,
    run: String,
    operation: String,
    digest: String,
) -> Result<crate::api::host::AgentRunView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.editing_approve(&handle, &run, &operation, &digest))
    })
    .await
}

async fn close_run_grants(
    host: &mut Host,
    consent: &str,
    signals: &Arc<Mutex<crate::actor::Signals>>,
) -> Result<(), BridgeError> {
    let ids = host
        .run_edit_grants
        .iter()
        .filter(|(_, g)| g.consent_id() == consent)
        .map(|(id, _)| id.clone())
        .collect::<Vec<_>>();
    let grants = ids
        .iter()
        .filter_map(|id| host.run_edit_grants.get(id))
        .cloned()
        .collect::<Vec<_>>();
    for grant in &grants {
        grant.request_revoke();
    }
    {
        let controls = signals.lock().map_err(|_| failure("HOST_INTERNAL"))?;
        for id in &ids {
            if let Some(run) = controls.runs.get(id) {
                run.cancel.send_replace(true);
            }
        }
    }
    for grant in grants {
        grant.wait_drained().await;
    }
    for id in ids {
        let view = host
            .journal
            .agent_view(LOCAL_OWNER, &id)
            .map_err(runs::engine_error)?;
        if matches!(
            view.phase,
            orange_agent_runtime::engine::Phase::Ready
                | orange_agent_runtime::engine::Phase::ModelPending
                | orange_agent_runtime::engine::Phase::ToolsPending
                | orange_agent_runtime::engine::Phase::AwaitingUser
        ) {
            host.journal
                .cancel_agent_run(LOCAL_OWNER, &id)
                .map_err(runs::engine_error)?;
        }
        host.run_edit_grants.remove(&id);
    }
    Ok(())
}
