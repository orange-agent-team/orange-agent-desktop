use super::*;
use crate::api::host::{ExportInspectionAccessView, ExportInspectionView, ExportObservedFileView};
use orange_agent_runtime::workspace::patch::{
    PatchError,
    review::dispatch::recovery::retention::{ExportFileObservation, ExportInspectionGrant},
};
use std::sync::atomic::{AtomicBool, Ordering};

pub(super) struct InspectionSession {
    pub(super) view: ExportInspectionAccessView,
    pub(super) grant: Arc<ExportInspectionGrant>,
    pub(super) available: Arc<AtomicBool>,
}
fn error(e: PatchError) -> BridgeError {
    failure(match e {
        PatchError::Workspace(workspace::WorkspaceError::Revoked) => "EXPORT_INSPECTION_CLOSED",
        PatchError::Workspace(workspace::WorkspaceError::Forbidden) => "EXPORT_INSPECTION_DENIED",
        PatchError::Workspace(workspace::WorkspaceError::EnvironmentChanged) => {
            "EXPORT_INSPECTION_DIRECTORY_CHANGED"
        }
        PatchError::VersionChanged => "EXPORT_INSPECTION_FILES_CHANGED",
        PatchError::Invalid | PatchError::Limit => "INVALID_EXPORT_INSPECTION",
        _ => "EXPORT_INSPECTION_UNAVAILABLE",
    })
}
fn foreign(c: &crate::actor::Signals, t: &str) -> bool {
    c.closed_selections.contains(t)
        || c.closed_creation_selections.contains(t)
        || c.closed_editing_selections.contains(t)
        || c.closed_imports.contains(t)
        || c.imports.contains_key(t)
        || c.workspaces.values().any(|s| s.session_token == t)
        || c.creations.values().any(|s| s.token == t)
        || c.editings.values().any(|s| s.token == t)
        || c.retentions.contains_key(t)
        || c.exports.contains_key(t)
        || c.export_retirements.contains_key(t)
        || c.export_restorations.contains_key(t)
        || c.recovery_inspections.contains_key(t)
        || c.recovery_writes.contains_key(t)
}
pub(super) fn observed(value: &ExportFileObservation) -> ExportObservedFileView {
    let mut out = ExportObservedFileView {
        kind: "missing".into(),
        reason: None,
        bytes: None,
        sha256: None,
        matches_approved_artifact: false,
        valid_export_document: false,
    };
    match value {
        ExportFileObservation::Missing => {}
        ExportFileObservation::Refused { reason } => {
            out.kind = "refused".into();
            out.reason = Some(reason.clone());
        }
        ExportFileObservation::Regular {
            bytes,
            sha256,
            matches_approved_artifact,
            valid_export_document,
            ..
        } => {
            out.kind = "regular".into();
            out.bytes = Some(bytes.clone());
            out.sha256 = Some(sha256.clone());
            out.matches_approved_artifact = *matches_approved_artifact;
            out.valid_export_document = *valid_export_document;
        }
    }
    out
}
impl HostRegistry {
    fn export_check_authorize(
        &mut self,
        handle: &str,
        request: ExportInspectionAccessView,
    ) -> Result<ExportInspectionAccessView, BridgeError> {
        let token = &request.session_token;
        let path = Path::new(&request.display_directory);
        if !orange_protocol::valid_id(token) || !path.is_absolute() || path.is_symlink() {
            return Err(failure("INVALID_EXPORT_INSPECTION"));
        }
        let signals = self.signals.clone();
        let host = self.current(handle)?;
        {
            let c = signals.lock().map_err(|_| failure("HOST_INTERNAL"))?;
            if foreign(&c, token) {
                return Err(failure("EXPORT_INSPECTION_CONFLICT"));
            }
            if c.closed_recovery_selections.contains(token)
                || c.closed_recovery_selections.len() >= 8192
            {
                return Err(failure("EXPORT_INSPECTION_CLOSED"));
            }
        }
        let directory = path
            .canonicalize()
            .map_err(|_| failure("EXPORT_INSPECTION_DIRECTORY_CHANGED"))?;
        let directory = directory
            .to_str()
            .filter(|s| s.len() <= 4096)
            .ok_or_else(|| failure("INVALID_EXPORT_INSPECTION"))?
            .to_owned();
        if let Some(old) = host.export_checks.get(token) {
            if old.view.run_id != request.run_id
                || old.view.operation_id != request.operation_id
                || old.view.export_id != request.export_id
                || old.view.display_directory != directory
            {
                return Err(failure("EXPORT_INSPECTION_CONFLICT"));
            }
            return if old.available.load(Ordering::Acquire) {
                Ok(old.view.clone())
            } else {
                Err(failure("EXPORT_INSPECTION_CLOSED"))
            };
        }
        if host.export_checks.len() >= 32 {
            return Err(failure("EXPORT_INSPECTION_LIMIT"));
        }
        let grant = Arc::new(
            host.journal
                .authorize_export_inspection(
                    LOCAL_OWNER,
                    &request.run_id,
                    &request.operation_id,
                    &request.export_id,
                    Path::new(&directory),
                )
                .map_err(error)?,
        );
        let available = Arc::new(AtomicBool::new(true));
        {
            let mut c = signals.lock().map_err(|_| failure("HOST_INTERNAL"))?;
            if foreign(&c, token)
                || c.closed_recovery_selections.contains(token)
                || c.closed_recovery_selections.len() >= 8192
            {
                grant.request_revoke();
                return Err(failure("EXPORT_INSPECTION_CLOSED"));
            }
            c.export_checks.insert(
                token.clone(),
                crate::actor::ExportInspectionSignal {
                    grant: grant.clone(),
                    available: available.clone(),
                },
            );
        }
        let view = ExportInspectionAccessView {
            display_directory: directory,
            ..request
        };
        host.export_checks.insert(
            view.session_token.clone(),
            InspectionSession {
                view: view.clone(),
                grant,
                available,
            },
        );
        Ok(view)
    }
    async fn export_check_snapshot(
        &mut self,
        handle: &str,
        token: &str,
    ) -> Result<ExportInspectionView, BridgeError> {
        let host = self.current(handle)?;
        let scope = host
            .export_checks
            .get(token)
            .filter(|s| s.available.load(Ordering::Acquire))
            .ok_or_else(|| failure("EXPORT_INSPECTION_CLOSED"))?;
        let receipt = host
            .journal
            .inspect_export_files(&scope.grant)
            .await
            .map_err(error)?;
        let value = receipt.view().map_err(error)?;
        if value.export_id != scope.view.export_id {
            return Err(failure("EXPORT_INSPECTION_CONFLICT"));
        }
        let view = ExportInspectionView {
            session_token: token.into(),
            run_id: scope.view.run_id.clone(),
            operation_id: scope.view.operation_id.clone(),
            export_id: value.export_id.clone(),
            review_digest: value.review_digest.clone(),
            recorded_state: value.recorded_state.clone(),
            file_name: value.file_name.clone(),
            target: observed(&value.target),
            staged: observed(&value.staged),
        };
        receipt.view().map_err(error)?;
        if !scope.available.load(Ordering::Acquire) {
            return Err(failure("EXPORT_INSPECTION_CLOSED"));
        }
        Ok(view)
    }
    async fn close_export_check(&mut self, handle: &str, token: &str) -> Result<(), BridgeError> {
        self.close_export_restorations(handle, Some(token), None)
            .await?;
        self.close_export_retirements(handle, Some(token), None)
            .await?;
        let signals = self.signals.clone();
        let host = self.current(handle)?;
        if let Some(scope) = host.export_checks.get(token) {
            scope.available.store(false, Ordering::Release);
            scope.grant.request_revoke();
            scope.grant.wait_drained().await;
        }
        host.export_checks.remove(token);
        signals
            .lock()
            .map_err(|_| failure("HOST_INTERNAL"))?
            .export_checks
            .remove(token);
        Ok(())
    }
}
pub(crate) async fn authorize_export_inspection(
    handle: String,
    run: String,
    operation: String,
    id: String,
    token: String,
    directory: String,
) -> Result<ExportInspectionAccessView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, _| {
        host.export_check_authorize(
            &handle,
            ExportInspectionAccessView {
                session_token: token,
                run_id: run,
                operation_id: operation,
                export_id: id,
                display_directory: directory,
            },
        )
    })
    .await
}
pub(crate) async fn inspect_export_files(
    handle: String,
    token: String,
) -> Result<ExportInspectionView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.export_check_snapshot(&handle, &token))
    })
    .await
}
pub(crate) async fn suspend_export_inspection(
    handle: String,
    token: String,
) -> Result<(), BridgeError> {
    crate::actor::signal_export_inspection_release(&handle, &token)?;
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.close_export_check(&handle, &token))
    })
    .await
}
