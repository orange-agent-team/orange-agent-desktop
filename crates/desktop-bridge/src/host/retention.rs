//! Content-free retention discovery. These entry points do not call run_context
//! or open a filesystem capability; retained files require a separate selection.
use super::*;
mod exporting;
pub(super) use exporting::ExportSession;
pub(crate) use exporting::{
    approve_export, authorize_export_destination, inspect_export_outcome, list_export_outcomes,
    prepare_export, suspend_export_destination,
};

pub(crate) async fn list_retained_edits(
    handle: String,
    run: String,
    before: Option<String>,
    limit: u16,
) -> Result<Vec<String>, BridgeError> {
    crate::actor::call(handle.clone(), move |registry, _| {
        registry
            .current(&handle)?
            .journal
            .agent_retention_patch_ids(LOCAL_OWNER, &run, before.as_deref(), limit)
            .map_err(runs::engine_error)
    })
    .await
}

pub(crate) async fn inspect_retention_outcome(
    handle: String,
    run: String,
    operation: String,
) -> Result<Option<String>, BridgeError> {
    crate::actor::call(handle.clone(), move |registry, _| {
        registry
            .current(&handle)?
            .journal
            .agent_retention_review_id(LOCAL_OWNER, &run, &operation)
            .map_err(runs::engine_error)
    })
    .await
}

use crate::api::host::{RetentionAccessView, RetentionInspectionView, RetentionReviewView};
use orange_agent_runtime::workspace::patch::{
    PatchError,
    review::dispatch::recovery::retention::{PatchRetentionGrant, PatchRetentionReview},
};
use std::sync::atomic::{AtomicBool, Ordering};

pub(super) struct RetentionSession {
    pub(super) view: RetentionAccessView,
    pub(super) grant: Arc<PatchRetentionGrant>,
    pub(super) available: Arc<AtomicBool>,
    review: Option<PatchRetentionReview>,
}
fn error(value: PatchError) -> BridgeError {
    failure(match value {
        PatchError::Workspace(workspace::WorkspaceError::Revoked) => "RETENTION_SELECTION_CLOSED",
        PatchError::Workspace(workspace::WorkspaceError::Forbidden) => "RETENTION_ACCESS_DENIED",
        PatchError::Workspace(workspace::WorkspaceError::EnvironmentChanged) => {
            "RETENTION_WORKSPACE_CHANGED"
        }
        PatchError::VersionChanged => "RETENTION_FILES_CHANGED",
        PatchError::RecoveryRequired => "RETENTION_RECHECK_REQUIRED",
        PatchError::Limit => "RETENTION_LIMIT",
        PatchError::Invalid => "INVALID_RETENTION_REQUEST",
        PatchError::Journal(
            orange_agent_runtime::JournalError::Conflict
            | orange_agent_runtime::JournalError::ApprovalRequired,
        ) => "RETENTION_PREVIEW_CHANGED",
        _ => "RETENTION_STORAGE_UNAVAILABLE",
    })
}
fn conflicts(controls: &crate::actor::Signals, token: &str) -> bool {
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
        || controls.exports.contains_key(token)
        || controls.export_checks.contains_key(token)
        || controls.export_retirements.contains_key(token)
        || controls.recovery_inspections.contains_key(token)
        || controls.recovery_writes.contains_key(token)
}
impl HostRegistry {
    fn authorize_retention(
        &mut self,
        handle: &str,
        run: &str,
        operation: &str,
        token: &str,
        version: &str,
        selected: &Path,
    ) -> Result<RetentionAccessView, BridgeError> {
        if !orange_protocol::valid_id(token) || !selected.is_absolute() || selected.is_symlink() {
            return Err(failure("INVALID_RETENTION_REQUEST"));
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
            if conflicts(&controls, token) {
                return Err(failure("RETENTION_SELECTION_CONFLICT"));
            }
            if controls.closed_recovery_selections.contains(token)
                || controls.closed_recovery_selections.len() >= 8192
            {
                return Err(failure("RETENTION_SELECTION_CLOSED"));
            }
            let epoch = *controls
                .recovery_epochs
                .entry(workspace.clone())
                .or_insert(0);
            if epoch == u64::MAX {
                return Err(failure("RETENTION_SELECTION_CLOSED"));
            }
            epoch
        };
        let directory = selected
            .canonicalize()
            .map_err(|_| failure("RETENTION_WORKSPACE_CHANGED"))?;
        let directory = directory
            .to_str()
            .filter(|s| s.len() <= 4096)
            .ok_or_else(|| failure("INVALID_RETENTION_REQUEST"))?
            .to_owned();
        if let Some(old) = host.retentions.get(token) {
            if old.view.run_id != run
                || old.view.operation_id != operation
                || old.view.display_directory != directory
            {
                return Err(failure("RETENTION_SELECTION_CONFLICT"));
            }
            return if old.available.load(Ordering::Acquire) {
                Ok(old.view.clone())
            } else {
                Err(failure("RETENTION_SELECTION_CLOSED"))
            };
        }
        if host.retentions.len() >= 32 {
            return Err(failure("RETENTION_LIMIT"));
        }
        let grant = Arc::new(
            host.journal
                .authorize_patch_retention(LOCAL_OWNER, run, operation, Path::new(&directory))
                .map_err(error)?,
        );
        let available = Arc::new(AtomicBool::new(true));
        {
            let mut controls = signals.lock().map_err(|_| failure("HOST_INTERNAL"))?;
            if conflicts(&controls, token)
                || controls.closed_recovery_selections.contains(token)
                || controls.closed_recovery_selections.len() >= 8192
                || controls.recovery_epochs.get(&workspace) != Some(&epoch)
            {
                grant.request_revoke();
                return Err(failure("RETENTION_SELECTION_CLOSED"));
            }
            controls.retentions.insert(
                token.into(),
                crate::actor::RetentionSignal {
                    workspace: workspace.clone(),
                    workspace_version: stored.version,
                    grant: grant.clone(),
                    available: available.clone(),
                },
            );
        }
        let view = RetentionAccessView {
            session_token: token.into(),
            run_id: run.into(),
            operation_id: operation.into(),
            workspace_id: workspace,
            display_directory: directory,
        };
        host.retentions.insert(
            token.into(),
            RetentionSession {
                view: view.clone(),
                grant,
                available,
                review: None,
            },
        );
        Ok(view)
    }
    async fn retention_snapshot(
        &mut self,
        handle: &str,
        token: &str,
    ) -> Result<RetentionInspectionView, BridgeError> {
        let host = self.current(handle)?;
        let scope = host
            .retentions
            .get(token)
            .filter(|s| s.available.load(Ordering::Acquire))
            .ok_or_else(|| failure("RETENTION_SELECTION_CLOSED"))?;
        let receipt = host
            .journal
            .inspect_selected_retention(&scope.grant)
            .await
            .map_err(error)?;
        let snapshot = receipt.snapshot().map_err(error)?;
        let usage = host
            .journal
            .selected_retention_usage(&scope.grant)
            .map_err(error)?;
        let archive = host
            .journal
            .patch_retention_archive(LOCAL_OWNER, &scope.view.operation_id)
            .map_err(error)?;
        let archived_review_id = archive.as_ref().map(|a| a.review_id.clone());
        // Compare the immutable archival observation with the same snapshot
        // projected below; do not mix observations from two filesystem reads.
        let changed_since_archival = archive
            .as_ref()
            .map(|a| a.staged != snapshot.staged || a.original != snapshot.original);
        let view = RetentionInspectionView {
            session_token: token.into(),
            run_id: scope.view.run_id.clone(),
            operation_id: scope.view.operation_id.clone(),
            path: snapshot.journal.plan.path.clone(),
            execution_state: snapshot.journal.execution_state.clone(),
            staged: recovery::file(&snapshot.staged),
            original: recovery::file(&snapshot.original),
            resource_active_records: usage.resource_active_records,
            resource_active_reserved_bytes: usage.resource_active_reserved_bytes,
            owner_archive_records: usage.owner_archive_records,
            owner_archive_reserved_bytes: usage.owner_archive_reserved_bytes,
            owner_archive_limit_bytes: usage.owner_archive_limit_bytes,
            owner_archive_record_limit: usage.owner_archive_record_limit,
            archived_review_id,
            changed_since_archival,
        };
        receipt.snapshot().map_err(error)?;
        if !scope.available.load(Ordering::Acquire) {
            return Err(failure("RETENTION_SELECTION_CLOSED"));
        }
        Ok(view)
    }
    async fn retention_preview(
        &mut self,
        handle: &str,
        token: &str,
        key: &str,
    ) -> Result<RetentionReviewView, BridgeError> {
        let host = self.current(handle)?;
        let scope = host
            .retentions
            .get_mut(token)
            .filter(|s| s.available.load(Ordering::Acquire))
            .ok_or_else(|| failure("RETENTION_SELECTION_CLOSED"))?;
        scope.review = None;
        let review = host
            .journal
            .prepare_selected_retention(&scope.grant, key)
            .await
            .map_err(error)?;
        if !scope.available.load(Ordering::Acquire) {
            return Err(failure("RETENTION_SELECTION_CLOSED"));
        }
        let view = RetentionReviewView {
            session_token: token.into(),
            operation_id: review.operation_id.clone(),
            review_id: review.review_id.clone(),
            digest: review.digest.clone(),
            path: review.path.clone(),
            staged: recovery::file(&review.staged),
            original: recovery::file(&review.original),
            archive_reserved_bytes: review.archive_reserved_bytes.clone(),
            expires_at: review.expires_at,
        };
        scope.review = Some(review);
        Ok(view)
    }
    async fn retention_approve(
        &mut self,
        handle: &str,
        token: &str,
        id: &str,
        digest: &str,
    ) -> Result<String, BridgeError> {
        let host = self.current(handle)?;
        let scope = host
            .retentions
            .get_mut(token)
            .filter(|s| s.available.load(Ordering::Acquire))
            .ok_or_else(|| failure("RETENTION_SELECTION_CLOSED"))?;
        let reviewed = scope
            .review
            .take()
            .ok_or_else(|| failure("RETENTION_PREVIEW_CHANGED"))?;
        if reviewed.review_id != id || reviewed.digest != digest {
            return Err(failure("RETENTION_PREVIEW_CHANGED"));
        }
        let archive = host
            .journal
            .approve_selected_retention(&scope.grant, id, digest)
            .await
            .map_err(error)?;
        if !scope.available.load(Ordering::Acquire) {
            return Err(failure("RETENTION_SELECTION_CLOSED"));
        }
        Ok(archive.review_id)
    }
    async fn close_retention(&mut self, handle: &str, token: &str) -> Result<(), BridgeError> {
        self.close_exports(handle, Some(token), None).await?;
        let signals = self.signals.clone();
        let host = self.current(handle)?;
        if let Some(scope) = host.retentions.get(token) {
            scope.available.store(false, Ordering::Release);
            scope.grant.request_revoke();
            scope.grant.wait_drained().await;
        }
        host.retentions.remove(token);
        signals
            .lock()
            .map_err(|_| failure("HOST_INTERNAL"))?
            .retentions
            .remove(token);
        Ok(())
    }
}
pub(crate) async fn authorize_retention_access(
    handle: String,
    run: String,
    operation: String,
    token: String,
    version: String,
    directory: String,
) -> Result<RetentionAccessView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, _| {
        host.authorize_retention(
            &handle,
            &run,
            &operation,
            &token,
            &version,
            Path::new(&directory),
        )
    })
    .await
}
pub(crate) async fn inspect_retention(
    handle: String,
    token: String,
) -> Result<RetentionInspectionView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.retention_snapshot(&handle, &token))
    })
    .await
}
pub(crate) async fn prepare_retention_archive(
    handle: String,
    token: String,
    key: String,
) -> Result<RetentionReviewView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.retention_preview(&handle, &token, &key))
    })
    .await
}
pub(crate) async fn approve_retention_archive(
    handle: String,
    token: String,
    id: String,
    digest: String,
) -> Result<String, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.retention_approve(&handle, &token, &id, &digest))
    })
    .await
}
pub(crate) async fn suspend_retention_access(
    handle: String,
    token: String,
) -> Result<(), BridgeError> {
    crate::actor::signal_retention_release(&handle, &token)?;
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.close_retention(&handle, &token))
    })
    .await
}
