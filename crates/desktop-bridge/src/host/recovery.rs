use super::*;
use crate::api::host::{
    RecoveryFileStatusView, RecoveryInspectionAccessView, RecoveryInspectionView,
};
use orange_agent_runtime::workspace::patch::{
    PatchError,
    review::dispatch::recovery::{
        PublicationStage,
        inspection::{PatchInspectionGrant, RecoveryFileObservation},
    },
};
use std::sync::atomic::{AtomicBool, Ordering};

pub(super) struct InspectionSession {
    view: RecoveryInspectionAccessView,
    read: Arc<PatchInspectionGrant>,
    available: Arc<AtomicBool>,
}
fn error(value: PatchError) -> BridgeError {
    failure(match value {
        PatchError::Workspace(workspace::WorkspaceError::Revoked) => "RECOVERY_SELECTION_CLOSED",
        PatchError::Workspace(workspace::WorkspaceError::Forbidden) => "RECOVERY_ACCESS_DENIED",
        PatchError::Workspace(workspace::WorkspaceError::EnvironmentChanged) => {
            "RECOVERY_WORKSPACE_CHANGED"
        }
        PatchError::VersionChanged => "RECOVERY_FILES_CHANGED",
        PatchError::RecoveryRequired => "RECOVERY_RECHECK_REQUIRED",
        PatchError::Invalid | PatchError::Limit => "INVALID_RECOVERY_REQUEST",
        _ => "RECOVERY_STORAGE_UNAVAILABLE",
    })
}
fn other_selection_kind(controls: &crate::actor::Signals, token: &str) -> bool {
    controls.closed_selections.contains(token)
        || controls.closed_creation_selections.contains(token)
        || controls.closed_editing_selections.contains(token)
        || controls.closed_imports.contains(token)
        || controls.imports.contains_key(token)
        || controls
            .workspaces
            .values()
            .any(|s| s.session_token == token)
        || controls.creations.values().any(|s| s.token == token)
        || controls.editings.values().any(|s| s.token == token)
}
fn file(value: &RecoveryFileObservation) -> RecoveryFileStatusView {
    let mut view = RecoveryFileStatusView {
        kind: "missing".into(),
        refusal: None,
        bytes: None,
        sha256: None,
        security_sha256: None,
        reviewed_original_inode: false,
        matches_original_content: false,
        matches_result_content: false,
    };
    match value {
        RecoveryFileObservation::Missing => {}
        RecoveryFileObservation::Refused { reason } => {
            view.kind = "refused".into();
            view.refusal = Some(reason.clone());
        }
        RecoveryFileObservation::Regular {
            bytes,
            sha256,
            security_sha256,
            reviewed_original_inode,
            matches_original_content,
            matches_result_content,
            ..
        } => {
            view.kind = "regular".into();
            view.bytes = Some(bytes.clone());
            view.sha256 = Some(sha256.clone());
            view.security_sha256 = Some(security_sha256.clone());
            view.reviewed_original_inode = *reviewed_original_inode;
            view.matches_original_content = *matches_original_content;
            view.matches_result_content = *matches_result_content;
        }
    }
    view
}
impl HostRegistry {
    async fn authorize_inspection(
        &mut self,
        handle: &str,
        run: &str,
        operation: &str,
        token: &str,
        version: &str,
        selected: &Path,
    ) -> Result<RecoveryInspectionAccessView, BridgeError> {
        if !orange_protocol::valid_id(token) || !selected.is_absolute() || selected.is_symlink() {
            return Err(failure("INVALID_RECOVERY_REQUEST"));
        }
        let signals = self.signals.clone();
        let host = self.current(handle)?;
        let workspace = host
            .journal
            .agent_workspace_id(LOCAL_OWNER, run)
            .map_err(runs::engine_error)?
            .ok_or_else(|| failure("RUN_WORKSPACE_REQUIRED"))?;
        let stored = host
            .journal
            .workspace(LOCAL_OWNER, &workspace)
            .map_err(workspace_error)?;
        if stored.version != version {
            return Err(failure("WORKSPACE_CONFLICT"));
        }
        let epoch = {
            let mut controls = signals.lock().map_err(|_| failure("HOST_INTERNAL"))?;
            if other_selection_kind(&controls, token) {
                return Err(failure("RECOVERY_SELECTION_CONFLICT"));
            }
            if controls.closed_recovery_selections.contains(token)
                || controls.closed_recovery_selections.len() >= 8192
            {
                return Err(failure("RECOVERY_SELECTION_CLOSED"));
            }
            let epoch = *controls
                .recovery_epochs
                .entry(workspace.clone())
                .or_insert(0);
            if epoch == u64::MAX {
                return Err(failure("RECOVERY_SELECTION_CLOSED"));
            }
            epoch
        };
        let directory = selected
            .canonicalize()
            .map_err(|_| failure("RECOVERY_WORKSPACE_CHANGED"))?;
        let directory = directory
            .to_str()
            .filter(|s| s.len() <= 4096)
            .ok_or_else(|| failure("INVALID_RECOVERY_REQUEST"))?
            .to_owned();
        if let Some(old) = host.recovery_inspections.get(token) {
            if old.view.run_id != run
                || old.view.operation_id != operation
                || old.view.display_directory != directory
            {
                return Err(failure("RECOVERY_SELECTION_CONFLICT"));
            }
            return if old.available.load(Ordering::Acquire) {
                Ok(old.view.clone())
            } else {
                Err(failure("RECOVERY_SELECTION_CLOSED"))
            };
        }
        if host.recovery_inspections.len() >= 32 {
            return Err(failure("RECOVERY_SELECTION_LIMIT"));
        }
        let read = Arc::new(
            host.journal
                .authorize_patch_inspection(LOCAL_OWNER, run, operation, Path::new(&directory))
                .map_err(error)?,
        );
        let available = Arc::new(AtomicBool::new(true));
        {
            let mut controls = signals.lock().map_err(|_| failure("HOST_INTERNAL"))?;
            if controls.closed_recovery_selections.contains(token)
                || controls.closed_recovery_selections.len() >= 8192
                || controls.recovery_epochs.get(&workspace) != Some(&epoch)
                || other_selection_kind(&controls, token)
            {
                read.request_revoke();
                return Err(failure("RECOVERY_SELECTION_CLOSED"));
            }
            controls.recovery_inspections.insert(
                token.into(),
                crate::actor::RecoveryInspectionSignal {
                    workspace: workspace.clone(),
                    workspace_version: stored.version,
                    read: read.clone(),
                    available: available.clone(),
                },
            );
        }
        let view = RecoveryInspectionAccessView {
            session_token: token.into(),
            run_id: run.into(),
            operation_id: operation.into(),
            workspace_id: workspace,
            display_directory: directory,
        };
        host.recovery_inspections.insert(
            token.into(),
            InspectionSession {
                view: view.clone(),
                read,
                available,
            },
        );
        Ok(view)
    }
    async fn inspect_selected_recovery(
        &mut self,
        handle: &str,
        token: &str,
    ) -> Result<RecoveryInspectionView, BridgeError> {
        let host = self.current(handle)?;
        let scope = host
            .recovery_inspections
            .get(token)
            .filter(|s| s.available.load(Ordering::Acquire))
            .ok_or_else(|| failure("RECOVERY_SELECTION_CLOSED"))?;
        let receipt = host
            .journal
            .inspect_selected_patch(&scope.read)
            .await
            .map_err(error)?;
        let snapshot = receipt.snapshot().map_err(error)?;
        if snapshot.journal.plan.operation_id != scope.view.operation_id {
            return Err(failure("RECOVERY_CONTEXT_CHANGED"));
        }
        let stage = snapshot.journal.last_durable_stage.map(|s| {
            match s {
                PublicationStage::StageIntent => "stage_intent",
                PublicationStage::Staged => "staged",
                PublicationStage::CaptureIntent => "capture_intent",
                PublicationStage::Captured => "captured",
                PublicationStage::PublishIntent => "publish_intent",
                PublicationStage::Published => "published",
                PublicationStage::Confirmed => "confirmed",
            }
            .into()
        });
        let view = RecoveryInspectionView {
            run_id: scope.view.run_id.clone(),
            operation_id: scope.view.operation_id.clone(),
            path: snapshot.journal.plan.path.clone(),
            execution_state: snapshot.journal.execution_state.clone(),
            last_durable_stage: stage,
            target: file(&snapshot.target),
            staged: file(&snapshot.staged),
            original: file(&snapshot.original),
        };
        // Never expose protected staging names, raw contents, or an already
        // revoked snapshot through the Flutter projection.
        receipt.snapshot().map_err(error)?;
        if !scope.available.load(Ordering::Acquire) {
            return Err(failure("RECOVERY_SELECTION_CLOSED"));
        }
        Ok(view)
    }
    async fn suspend_inspection(&mut self, handle: &str, token: &str) -> Result<(), BridgeError> {
        let signals = self.signals.clone();
        let host = self.current(handle)?;
        if let Some(scope) = host.recovery_inspections.get(token) {
            scope.available.store(false, Ordering::Release);
            scope.read.request_revoke();
            scope.read.wait_drained().await;
        }
        host.recovery_inspections.remove(token);
        signals
            .lock()
            .map_err(|_| failure("HOST_INTERNAL"))?
            .recovery_inspections
            .remove(token);
        Ok(())
    }
    pub(super) fn workspace_recovery_leases(
        &mut self,
        handle: &str,
        workspace: &str,
    ) -> Result<Vec<Arc<PatchInspectionGrant>>, BridgeError> {
        let signals = self.signals.clone();
        let host = self.current(handle)?;
        let ids: Vec<_> = host
            .recovery_inspections
            .iter()
            .filter(|(_, s)| s.view.workspace_id == workspace)
            .map(|(id, _)| id.clone())
            .collect();
        let mut leases = Vec::new();
        let mut controls = signals.lock().map_err(|_| failure("HOST_INTERNAL"))?;
        for id in ids {
            if let Some(scope) = host.recovery_inspections.remove(&id) {
                scope.available.store(false, Ordering::Release);
                scope.read.request_revoke();
                leases.push(scope.read);
            }
            controls.closed_recovery_selections.insert(id.clone());
            controls.recovery_inspections.remove(&id);
        }
        Ok(leases)
    }
}
pub(crate) async fn authorize_recovery_inspection(
    handle: String,
    run: String,
    operation: String,
    token: String,
    version: String,
    directory: String,
) -> Result<RecoveryInspectionAccessView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.authorize_inspection(
            &handle,
            &run,
            &operation,
            &token,
            &version,
            Path::new(&directory),
        ))
    })
    .await
}
pub(crate) async fn inspect_recovery(
    handle: String,
    token: String,
) -> Result<RecoveryInspectionView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.inspect_selected_recovery(&handle, &token))
    })
    .await
}
pub(crate) async fn suspend_recovery_inspection(
    handle: String,
    token: String,
) -> Result<(), BridgeError> {
    crate::actor::signal_recovery_inspection_release(&handle, &token)?;
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.suspend_inspection(&handle, &token))
    })
    .await
}
