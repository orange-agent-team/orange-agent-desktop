use super::*;
use crate::api::host::{ExportAccessView, ExportFileView, ExportOutcomeView, ExportReviewView};
use orange_agent_runtime::workspace::patch::review::dispatch::recovery::retention::{
    PreparedRetentionExport, RetentionExportChoice, RetentionExportDestination,
    RetentionExportOutcome,
};

pub(in crate::host) struct ExportSession {
    pub(in crate::host) view: ExportAccessView,
    pub(in crate::host) destination: Arc<RetentionExportDestination>,
    pub(in crate::host) available: Arc<AtomicBool>,
    pub(in crate::host) prepared: Option<PreparedRetentionExport>,
}
fn outcome(value: RetentionExportOutcome) -> ExportOutcomeView {
    ExportOutcomeView {
        export_id: value.export_id,
        review_digest: value.review_digest,
        state: value.state,
    }
}
fn export_error(value: PatchError) -> BridgeError {
    failure(match value {
        PatchError::Workspace(workspace::WorkspaceError::Revoked) => "EXPORT_SELECTION_CLOSED",
        PatchError::Workspace(workspace::WorkspaceError::Forbidden) => "EXPORT_ACCESS_DENIED",
        PatchError::Workspace(workspace::WorkspaceError::EnvironmentChanged) => {
            "EXPORT_DIRECTORY_CHANGED"
        }
        PatchError::Journal(orange_agent_runtime::JournalError::Conflict) => "EXPORT_CONFLICT",
        PatchError::Journal(orange_agent_runtime::JournalError::ApprovalRequired) => {
            "EXPORT_PREVIEW_CHANGED"
        }
        PatchError::VersionChanged => "EXPORT_FILES_CHANGED",
        PatchError::Invalid | PatchError::Limit => "INVALID_EXPORT_REQUEST",
        _ => "EXPORT_RESULT_UNCONFIRMED",
    })
}
fn foreign_token(c: &crate::actor::Signals, t: &str) -> bool {
    c.closed_selections.contains(t)
        || c.closed_creation_selections.contains(t)
        || c.closed_editing_selections.contains(t)
        || c.closed_imports.contains(t)
        || c.imports.contains_key(t)
        || c.workspaces.values().any(|s| s.session_token == t)
        || c.creations.values().any(|s| s.token == t)
        || c.editings.values().any(|s| s.token == t)
        || c.export_checks.contains_key(t)
        || c.export_retirements.contains_key(t)
        || c.export_restorations.contains_key(t)
        || c.retentions.contains_key(t)
        || c.recovery_inspections.contains_key(t)
        || c.recovery_writes.contains_key(t)
}
impl HostRegistry {
    fn export_destination(
        &mut self,
        handle: &str,
        reader: &str,
        token: &str,
        path: &Path,
    ) -> Result<ExportAccessView, BridgeError> {
        if !orange_protocol::valid_id(token) || !path.is_absolute() || path.is_symlink() {
            return Err(failure("INVALID_EXPORT_REQUEST"));
        }
        let signals = self.signals.clone();
        let host = self.current(handle)?;
        let source = host
            .retentions
            .get(reader)
            .filter(|s| s.available.load(Ordering::Acquire))
            .ok_or_else(|| failure("RETENTION_SELECTION_CLOSED"))?;
        {
            let c = signals.lock().map_err(|_| failure("HOST_INTERNAL"))?;
            if foreign_token(&c, token) {
                return Err(failure("EXPORT_SELECTION_CONFLICT"));
            }
            if c.closed_recovery_selections.contains(token)
                || c.closed_recovery_selections.len() >= 8192
            {
                return Err(failure("EXPORT_SELECTION_CLOSED"));
            }
        }
        let directory = path
            .canonicalize()
            .map_err(|_| failure("EXPORT_DIRECTORY_CHANGED"))?;
        let directory = directory
            .to_str()
            .filter(|s| s.len() <= 4096)
            .ok_or_else(|| failure("INVALID_EXPORT_REQUEST"))?
            .to_owned();
        if let Some(old) = host.exports.get(token) {
            if old.view.read_session_token != reader || old.view.display_directory != directory {
                return Err(failure("EXPORT_SELECTION_CONFLICT"));
            }
            return if old.available.load(Ordering::Acquire) {
                Ok(old.view.clone())
            } else {
                Err(failure("EXPORT_SELECTION_CLOSED"))
            };
        }
        if host.exports.len() >= 32 {
            return Err(failure("EXPORT_SELECTION_LIMIT"));
        }
        let destination = Arc::new(
            host.journal
                .authorize_retention_export_destination(&source.grant, Path::new(&directory))
                .map_err(export_error)?,
        );
        let available = Arc::new(AtomicBool::new(true));
        {
            let mut c = signals.lock().map_err(|_| failure("HOST_INTERNAL"))?;
            if foreign_token(&c, token)
                || c.closed_recovery_selections.contains(token)
                || c.closed_recovery_selections.len() >= 8192
                || !source.available.load(Ordering::Acquire)
                || !c
                    .retentions
                    .get(reader)
                    .is_some_and(|s| s.available.load(Ordering::Acquire))
            {
                destination.request_revoke();
                return Err(failure("EXPORT_SELECTION_CLOSED"));
            }
            c.exports.insert(
                token.into(),
                crate::actor::ExportSignal {
                    workspace: source.view.workspace_id.clone(),
                    reader: reader.into(),
                    grant: destination.clone(),
                    available: available.clone(),
                },
            );
        }
        let view = ExportAccessView {
            session_token: token.into(),
            read_session_token: reader.into(),
            run_id: source.view.run_id.clone(),
            operation_id: source.view.operation_id.clone(),
            workspace_id: source.view.workspace_id.clone(),
            display_directory: directory,
        };
        host.exports.insert(
            token.into(),
            ExportSession {
                view: view.clone(),
                destination,
                available,
                prepared: None,
            },
        );
        Ok(view)
    }
    async fn export_preview(
        &mut self,
        handle: &str,
        token: &str,
        key: &str,
        name: &str,
        choice: &str,
    ) -> Result<ExportReviewView, BridgeError> {
        let host = self.current(handle)?;
        let session = host
            .exports
            .get_mut(token)
            .filter(|s| s.available.load(Ordering::Acquire))
            .ok_or_else(|| failure("EXPORT_SELECTION_CLOSED"))?;
        session.prepared.take();
        let source = host
            .retentions
            .get(&session.view.read_session_token)
            .filter(|s| s.available.load(Ordering::Acquire))
            .ok_or_else(|| failure("RETENTION_SELECTION_CLOSED"))?;
        let selected = match choice {
            "original" => RetentionExportChoice::Original,
            "staged" => RetentionExportChoice::Staged,
            "both" => RetentionExportChoice::Both,
            _ => return Err(failure("INVALID_EXPORT_REQUEST")),
        };
        let prepared = host
            .journal
            .prepare_retention_export(&source.grant, &session.destination, selected, name, key)
            .await
            .map_err(export_error)?;
        let preview = prepared.preview().map_err(export_error)?;
        let view = ExportReviewView {
            session_token: token.into(),
            read_session_token: session.view.read_session_token.clone(),
            run_id: session.view.run_id.clone(),
            operation_id: session.view.operation_id.clone(),
            export_id: preview.export_id.clone(),
            digest: preview.digest.clone(),
            source_path: preview.artifact.path.clone(),
            file_name: preview.file_name.clone(),
            choice: choice.into(),
            entries: preview
                .artifact
                .entries
                .iter()
                .map(|e| ExportFileView {
                    role: e.role.clone(),
                    bytes: e.bytes.clone(),
                    sha256: e.sha256.clone(),
                    matches_reviewed_original: e.matches_reviewed_original,
                    matches_reviewed_result: e.matches_reviewed_result,
                    reviewed_original_inode: e.reviewed_original_inode,
                })
                .collect(),
            artifact_bytes: preview.artifact.artifact_bytes.clone(),
            artifact_sha256: preview.artifact.artifact_sha256.clone(),
            expires_at: preview.expires_at,
        };
        if !source.available.load(Ordering::Acquire) || !session.available.load(Ordering::Acquire) {
            return Err(failure("EXPORT_SELECTION_CLOSED"));
        }
        session.prepared = Some(prepared);
        Ok(view)
    }
    async fn export_approve(
        &mut self,
        handle: &str,
        token: &str,
        id: &str,
        digest: &str,
    ) -> Result<ExportOutcomeView, BridgeError> {
        let host = self.current(handle)?;
        let session = host
            .exports
            .get_mut(token)
            .filter(|s| s.available.load(Ordering::Acquire))
            .ok_or_else(|| failure("EXPORT_SELECTION_CLOSED"))?;
        let prepared = session
            .prepared
            .take()
            .ok_or_else(|| failure("EXPORT_PREVIEW_CHANGED"))?;
        let preview = prepared.preview().map_err(export_error)?;
        if preview.export_id != id || preview.digest != digest {
            return Err(failure("EXPORT_PREVIEW_CHANGED"));
        }
        let source = host
            .retentions
            .get(&session.view.read_session_token)
            .filter(|s| s.available.load(Ordering::Acquire))
            .ok_or_else(|| failure("RETENTION_SELECTION_CLOSED"))?;
        let receipt = host
            .journal
            .approve_retention_export(&source.grant, &session.destination, prepared, digest)
            .await
            .map_err(export_error)?;
        let result = host
            .journal
            .retention_export_outcome(
                LOCAL_OWNER,
                &session.view.run_id,
                &session.view.operation_id,
                &receipt.export_id,
            )
            .map_err(export_error)?
            .ok_or_else(|| failure("EXPORT_RESULT_UNCONFIRMED"))?;
        if !source.available.load(Ordering::Acquire) || !session.available.load(Ordering::Acquire) {
            return Err(failure("EXPORT_SELECTION_CLOSED"));
        }
        Ok(outcome(result))
    }
    pub(super) async fn close_exports(
        &mut self,
        handle: &str,
        reader: Option<&str>,
        token: Option<&str>,
    ) -> Result<(), BridgeError> {
        let signals = self.signals.clone();
        let host = self.current(handle)?;
        let ids: Vec<_> = host
            .exports
            .iter()
            .filter(|(id, s)| {
                reader.is_some_and(|r| s.view.read_session_token == r)
                    || token.is_some_and(|t| id.as_str() == t)
            })
            .map(|(id, _)| id.clone())
            .collect();
        let mut grants = Vec::new();
        {
            let mut c = signals.lock().map_err(|_| failure("HOST_INTERNAL"))?;
            for id in ids {
                if let Some(mut session) = host.exports.remove(&id) {
                    session.available.store(false, Ordering::Release);
                    session.destination.request_revoke();
                    // Both source and destination permits must drop before drain.
                    session.prepared.take();
                    grants.push(session.destination);
                }
                c.closed_recovery_selections.insert(id.clone());
                c.exports.remove(&id);
            }
        }
        for grant in grants {
            grant.wait_drained().await;
        }
        Ok(())
    }
}
pub(crate) async fn authorize_export_destination(
    handle: String,
    reader: String,
    token: String,
    path: String,
) -> Result<ExportAccessView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, _| {
        host.export_destination(&handle, &reader, &token, Path::new(&path))
    })
    .await
}
pub(crate) async fn prepare_export(
    handle: String,
    token: String,
    key: String,
    name: String,
    choice: String,
) -> Result<ExportReviewView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.export_preview(&handle, &token, &key, &name, &choice))
    })
    .await
}
pub(crate) async fn approve_export(
    handle: String,
    token: String,
    id: String,
    digest: String,
) -> Result<ExportOutcomeView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.export_approve(&handle, &token, &id, &digest))
    })
    .await
}
pub(crate) async fn inspect_export_outcome(
    handle: String,
    run: String,
    op: String,
    id: String,
) -> Result<Option<ExportOutcomeView>, BridgeError> {
    crate::actor::call(handle.clone(), move |host, _| {
        host.current(&handle)?
            .journal
            .retention_export_outcome(LOCAL_OWNER, &run, &op, &id)
            .map(|r| r.map(outcome))
            .map_err(export_error)
    })
    .await
}
pub(crate) async fn list_export_outcomes(
    handle: String,
    run: String,
    op: String,
    before: Option<String>,
    limit: u16,
) -> Result<Vec<ExportOutcomeView>, BridgeError> {
    crate::actor::call(handle.clone(), move |host, _| {
        host.current(&handle)?
            .journal
            .retention_export_outcomes(LOCAL_OWNER, &run, &op, before.as_deref(), limit)
            .map(|r| r.into_iter().map(outcome).collect())
            .map_err(export_error)
    })
    .await
}
pub(crate) async fn suspend_export_destination(
    handle: String,
    token: String,
) -> Result<(), BridgeError> {
    crate::actor::signal_export_release(&handle, &token)?;
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.close_exports(&handle, None, Some(&token)))
    })
    .await
}
