use super::*;
use crate::api::host::{
    ExportRestorationAccessView, ExportRestorationInspectionView, ExportRestorationOutcomeView,
    ExportRestorationReviewView,
};
use orange_agent_runtime::workspace::patch::{
    PatchError,
    review::dispatch::recovery::retention::{
        ExportRestorationGrant, ExportRestorationOutcome, PreparedExportRestoration,
    },
};
use std::sync::atomic::{AtomicBool, Ordering};

pub(super) struct RestorationSession {
    view: ExportRestorationAccessView,
    grant: Arc<ExportRestorationGrant>,
    available: Arc<AtomicBool>,
    prepared: Option<PreparedExportRestoration>,
}
fn error(e: PatchError) -> BridgeError {
    failure(match e {
        PatchError::Workspace(workspace::WorkspaceError::Revoked) => "EXPORT_RESTORATION_CLOSED",
        PatchError::Workspace(workspace::WorkspaceError::EnvironmentChanged) => {
            "EXPORT_RESTORATION_DIRECTORY_CHANGED"
        }
        PatchError::Workspace(workspace::WorkspaceError::Forbidden) => "EXPORT_RESTORATION_DENIED",
        PatchError::Invalid | PatchError::Limit => "INVALID_EXPORT_RESTORATION",
        PatchError::VersionChanged => "EXPORT_RESTORATION_FILES_CHANGED",
        _ => "EXPORT_RESTORATION_UNCONFIRMED",
    })
}
pub(crate) fn export_restoration_foreign(c: &crate::actor::Signals, token: &str) -> bool {
    c.closed_selections.contains(token)
        || c.closed_creation_selections.contains(token)
        || c.closed_editing_selections.contains(token)
        || c.closed_imports.contains(token)
        || c.imports.contains_key(token)
        || c.workspaces.values().any(|s| s.session_token == token)
        || c.creations.values().any(|s| s.token == token)
        || c.editings.values().any(|s| s.token == token)
        || c.retentions.contains_key(token)
        || c.exports.contains_key(token)
        || c.recovery_inspections.contains_key(token)
        || c.recovery_writes.contains_key(token)
        || c.export_checks.contains_key(token)
        || c.export_retirements.contains_key(token)
}
fn outcome(v: ExportRestorationOutcome) -> ExportRestorationOutcomeView {
    ExportRestorationOutcomeView {
        restoration_id: v.restoration_id,
        retirement_id: v.retirement_id,
        file_name: v.file_name,
        export_id: v.export_id,
        review_digest: v.review_digest,
        state: v.state,
    }
}
impl HostRegistry {
    fn restoration_authorize(
        &mut self,
        handle: &str,
        reader: &str,
        token: &str,
        path: &Path,
    ) -> Result<ExportRestorationAccessView, BridgeError> {
        if !orange_protocol::valid_id(token) || !path.is_absolute() || path.is_symlink() {
            return Err(failure("INVALID_EXPORT_RESTORATION"));
        }
        let signals = self.signals.clone();
        let host = self.current(handle)?;
        let read = host
            .export_checks
            .get(reader)
            .filter(|s| s.available.load(Ordering::Acquire))
            .ok_or_else(|| failure("EXPORT_INSPECTION_CLOSED"))?;
        {
            let c = signals.lock().map_err(|_| failure("HOST_INTERNAL"))?;
            if export_restoration_foreign(&c, token) {
                return Err(failure("EXPORT_RESTORATION_CONFLICT"));
            }
            if c.closed_recovery_selections.contains(token)
                || c.closed_recovery_selections.len() >= 8192
            {
                return Err(failure("EXPORT_RESTORATION_CLOSED"));
            }
        }
        let directory = path
            .canonicalize()
            .map_err(|_| failure("EXPORT_RESTORATION_DIRECTORY_CHANGED"))?;
        let directory = directory
            .to_str()
            .filter(|s| s.len() <= 4096)
            .ok_or_else(|| failure("INVALID_EXPORT_RESTORATION"))?
            .to_owned();
        if let Some(old) = host.export_restorations.get(token) {
            if old.view.read_session_token != reader || old.view.display_directory != directory {
                return Err(failure("EXPORT_RESTORATION_CONFLICT"));
            }
            return if old.available.load(Ordering::Acquire) {
                Ok(old.view.clone())
            } else {
                Err(failure("EXPORT_RESTORATION_CLOSED"))
            };
        }
        if host.export_restorations.len() >= 32 {
            return Err(failure("EXPORT_RESTORATION_LIMIT"));
        }
        let grant = Arc::new(
            host.journal
                .authorize_export_restoration(&read.grant, Path::new(&directory))
                .map_err(error)?,
        );
        let available = Arc::new(AtomicBool::new(true));
        {
            let mut c = signals.lock().map_err(|_| failure("HOST_INTERNAL"))?;
            if export_restoration_foreign(&c, token)
                || c.closed_recovery_selections.contains(token)
                || c.closed_recovery_selections.len() >= 8192
                || !read.available.load(Ordering::Acquire)
            {
                grant.request_revoke();
                return Err(failure("EXPORT_RESTORATION_CLOSED"));
            }
            c.export_restorations.insert(
                token.into(),
                crate::actor::ExportRestorationSignal {
                    reader: reader.into(),
                    grant: grant.clone(),
                    available: available.clone(),
                },
            );
        }
        let view = ExportRestorationAccessView {
            session_token: token.into(),
            read_session_token: reader.into(),
            run_id: read.view.run_id.clone(),
            operation_id: read.view.operation_id.clone(),
            export_id: read.view.export_id.clone(),
            display_directory: directory,
        };
        host.export_restorations.insert(
            token.into(),
            RestorationSession {
                view: view.clone(),
                grant,
                available,
                prepared: None,
            },
        );
        Ok(view)
    }
    async fn restoration_prepare(
        &mut self,
        handle: &str,
        token: &str,
        key: &str,
        retirement_id: &str,
        file_name: &str,
    ) -> Result<ExportRestorationReviewView, BridgeError> {
        let host = self.current(handle)?;
        let scope = host
            .export_restorations
            .get_mut(token)
            .filter(|s| s.available.load(Ordering::Acquire))
            .ok_or_else(|| failure("EXPORT_RESTORATION_CLOSED"))?;
        scope.prepared.take();
        let read = host
            .export_checks
            .get(&scope.view.read_session_token)
            .filter(|s| s.available.load(Ordering::Acquire))
            .ok_or_else(|| failure("EXPORT_INSPECTION_CLOSED"))?;
        let prepared = host
            .journal
            .prepare_export_restoration(&read.grant, &scope.grant, retirement_id, file_name, key)
            .await
            .map_err(error)?;
        let v = prepared.preview().map_err(error)?;
        let view = ExportRestorationReviewView {
            session_token: token.into(),
            restoration_id: v.restoration_id.clone(),
            retirement_id: v.retirement_id.clone(),
            export_id: v.export_id.clone(),
            digest: v.digest.clone(),
            file_name: v.file_name.clone(),
            source: export_inspection::observed(&v.source),
            expires_at: v.expires_at,
        };
        if !scope.available.load(Ordering::Acquire) || !read.available.load(Ordering::Acquire) {
            return Err(failure("EXPORT_RESTORATION_CLOSED"));
        }
        scope.prepared = Some(prepared);
        Ok(view)
    }
    async fn restoration_approve(
        &mut self,
        handle: &str,
        token: &str,
        id: &str,
        digest: &str,
    ) -> Result<ExportRestorationOutcomeView, BridgeError> {
        let host = self.current(handle)?;
        let scope = host
            .export_restorations
            .get_mut(token)
            .filter(|s| s.available.load(Ordering::Acquire))
            .ok_or_else(|| failure("EXPORT_RESTORATION_CLOSED"))?;
        let prepared = scope
            .prepared
            .take()
            .ok_or_else(|| failure("EXPORT_RESTORATION_PREVIEW_CHANGED"))?;
        let v = prepared.preview().map_err(error)?;
        if v.restoration_id != id || v.digest != digest {
            return Err(failure("EXPORT_RESTORATION_PREVIEW_CHANGED"));
        }
        let read = host
            .export_checks
            .get(&scope.view.read_session_token)
            .filter(|s| s.available.load(Ordering::Acquire))
            .ok_or_else(|| failure("EXPORT_INSPECTION_CLOSED"))?;
        host.journal
            .approve_export_restoration(&read.grant, &scope.grant, prepared, digest)
            .await
            .map_err(error)?;
        let value = host
            .journal
            .export_restoration_outcome(
                LOCAL_OWNER,
                &scope.view.run_id,
                &scope.view.operation_id,
                id,
            )
            .map_err(error)?
            .ok_or_else(|| failure("EXPORT_RESTORATION_UNCONFIRMED"))?;
        Ok(outcome(value))
    }
    pub(super) async fn close_export_restorations(
        &mut self,
        handle: &str,
        reader: Option<&str>,
        token: Option<&str>,
    ) -> Result<(), BridgeError> {
        let signals = self.signals.clone();
        let host = self.current(handle)?;
        let ids: Vec<_> = host
            .export_restorations
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
                if let Some(mut scope) = host.export_restorations.remove(&id) {
                    scope.available.store(false, Ordering::Release);
                    scope.grant.request_revoke();
                    // Drop cached read/write permits before waiting for either grant.
                    scope.prepared.take();
                    grants.push(scope.grant);
                }
                c.closed_recovery_selections.insert(id.clone());
                c.export_restorations.remove(&id);
            }
        }
        for grant in grants {
            grant.wait_drained().await;
        }
        Ok(())
    }
}
pub(crate) async fn authorize_export_restoration(
    handle: String,
    reader: String,
    token: String,
    directory: String,
) -> Result<ExportRestorationAccessView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, _| {
        host.restoration_authorize(&handle, &reader, &token, Path::new(&directory))
    })
    .await
}
pub(crate) async fn prepare_export_restoration(
    handle: String,
    token: String,
    key: String,
    retirement_id: String,
    file_name: String,
) -> Result<ExportRestorationReviewView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.restoration_prepare(&handle, &token, &key, &retirement_id, &file_name))
    })
    .await
}
pub(crate) async fn approve_export_restoration(
    handle: String,
    token: String,
    id: String,
    digest: String,
) -> Result<ExportRestorationOutcomeView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.restoration_approve(&handle, &token, &id, &digest))
    })
    .await
}
pub(crate) async fn suspend_export_restoration(
    handle: String,
    token: String,
) -> Result<(), BridgeError> {
    crate::actor::signal_export_restoration_release(&handle, &token)?;
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.close_export_restorations(&handle, None, Some(&token)))
    })
    .await
}
pub(crate) async fn list_export_restorations(
    handle: String,
    run: String,
    operation: String,
    retirement_id: String,
    before: Option<String>,
    limit: u16,
) -> Result<Vec<ExportRestorationOutcomeView>, BridgeError> {
    crate::actor::call(handle.clone(), move |host, _| {
        Ok(host
            .current(&handle)?
            .journal
            .export_restoration_outcomes(
                LOCAL_OWNER,
                &run,
                &operation,
                &retirement_id,
                before.as_deref(),
                limit,
            )
            .map_err(error)?
            .into_iter()
            .map(outcome)
            .collect())
    })
    .await
}
pub(crate) async fn inspect_export_restoration(
    handle: String,
    reader: String,
    id: String,
) -> Result<ExportRestorationInspectionView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(async {
            let host = host.current(&handle)?;
            let read = host
                .export_checks
                .get(&reader)
                .filter(|s| s.available.load(Ordering::Acquire))
                .ok_or_else(|| failure("EXPORT_INSPECTION_CLOSED"))?;
            let receipt = host
                .journal
                .inspect_export_restoration(&read.grant, &id)
                .await
                .map_err(error)?;
            let v = receipt.view().map_err(error)?;
            let view = ExportRestorationInspectionView {
                session_token: reader.clone(),
                restoration_id: v.restoration_id.clone(),
                retirement_id: v.retirement_id.clone(),
                export_id: read.view.export_id.clone(),
                recorded_state: v.recorded_state.clone(),
                file_name: v.file_name.clone(),
                target: export_inspection::observed(&v.target),
                staged: export_inspection::observed(&v.staged),
            };
            receipt.view().map_err(error)?;
            if !read.available.load(Ordering::Acquire) {
                return Err(failure("EXPORT_INSPECTION_CLOSED"));
            }
            Ok(view)
        })
    })
    .await
}
