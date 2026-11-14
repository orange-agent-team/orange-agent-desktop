use super::*;
use crate::api::host::{
    ExportRetirementAccessView, ExportRetirementInspectionView, ExportRetirementOutcomeView,
    ExportRetirementReviewView,
};
use orange_agent_runtime::workspace::patch::{
    PatchError,
    review::dispatch::recovery::retention::{
        ExportRetirementChoice, ExportRetirementGrant, ExportRetirementOutcome,
        PreparedExportRetirement,
    },
};
use std::sync::atomic::{AtomicBool, Ordering};

pub(super) struct RetirementSession {
    view: ExportRetirementAccessView,
    grant: Arc<ExportRetirementGrant>,
    available: Arc<AtomicBool>,
    prepared: Option<PreparedExportRetirement>,
}
fn error(e: PatchError) -> BridgeError {
    failure(match e {
        PatchError::Workspace(workspace::WorkspaceError::Revoked) => "EXPORT_RETIREMENT_CLOSED",
        PatchError::Workspace(workspace::WorkspaceError::EnvironmentChanged) => {
            "EXPORT_RETIREMENT_DIRECTORY_CHANGED"
        }
        PatchError::Workspace(workspace::WorkspaceError::Forbidden) => "EXPORT_RETIREMENT_DENIED",
        PatchError::Invalid | PatchError::Limit => "INVALID_EXPORT_RETIREMENT",
        PatchError::VersionChanged => "EXPORT_RETIREMENT_FILES_CHANGED",
        _ => "EXPORT_RETIREMENT_UNCONFIRMED",
    })
}
pub(crate) fn export_retirement_foreign(c: &crate::actor::Signals, token: &str) -> bool {
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
        || c.export_restorations.contains_key(token)
}
fn outcome(v: ExportRetirementOutcome) -> ExportRetirementOutcomeView {
    ExportRetirementOutcomeView {
        retirement_id: v.retirement_id,
        export_id: v.export_id,
        review_digest: v.review_digest,
        state: v.state,
    }
}
fn choice(v: ExportRetirementChoice) -> String {
    match v {
        ExportRetirementChoice::Target => "target",
        ExportRetirementChoice::Staged => "staged",
    }
    .into()
}
impl HostRegistry {
    fn retirement_authorize(
        &mut self,
        handle: &str,
        reader: &str,
        token: &str,
        path: &Path,
    ) -> Result<ExportRetirementAccessView, BridgeError> {
        if !orange_protocol::valid_id(token) || !path.is_absolute() || path.is_symlink() {
            return Err(failure("INVALID_EXPORT_RETIREMENT"));
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
            if export_retirement_foreign(&c, token) {
                return Err(failure("EXPORT_RETIREMENT_CONFLICT"));
            }
            if c.closed_recovery_selections.contains(token)
                || c.closed_recovery_selections.len() >= 8192
            {
                return Err(failure("EXPORT_RETIREMENT_CLOSED"));
            }
        }
        let directory = path
            .canonicalize()
            .map_err(|_| failure("EXPORT_RETIREMENT_DIRECTORY_CHANGED"))?;
        let directory = directory
            .to_str()
            .filter(|s| s.len() <= 4096)
            .ok_or_else(|| failure("INVALID_EXPORT_RETIREMENT"))?
            .to_owned();
        if let Some(old) = host.export_retirements.get(token) {
            if old.view.read_session_token != reader || old.view.display_directory != directory {
                return Err(failure("EXPORT_RETIREMENT_CONFLICT"));
            }
            return if old.available.load(Ordering::Acquire) {
                Ok(old.view.clone())
            } else {
                Err(failure("EXPORT_RETIREMENT_CLOSED"))
            };
        }
        if host.export_retirements.len() >= 32 {
            return Err(failure("EXPORT_RETIREMENT_LIMIT"));
        }
        let grant = Arc::new(
            host.journal
                .authorize_export_retirement(&read.grant, Path::new(&directory))
                .map_err(error)?,
        );
        let available = Arc::new(AtomicBool::new(true));
        {
            let mut c = signals.lock().map_err(|_| failure("HOST_INTERNAL"))?;
            if export_retirement_foreign(&c, token)
                || c.closed_recovery_selections.contains(token)
                || c.closed_recovery_selections.len() >= 8192
                || !read.available.load(Ordering::Acquire)
            {
                grant.request_revoke();
                return Err(failure("EXPORT_RETIREMENT_CLOSED"));
            }
            c.export_retirements.insert(
                token.into(),
                crate::actor::ExportRetirementSignal {
                    reader: reader.into(),
                    grant: grant.clone(),
                    available: available.clone(),
                },
            );
        }
        let view = ExportRetirementAccessView {
            session_token: token.into(),
            read_session_token: reader.into(),
            run_id: read.view.run_id.clone(),
            operation_id: read.view.operation_id.clone(),
            export_id: read.view.export_id.clone(),
            display_directory: directory,
        };
        host.export_retirements.insert(
            token.into(),
            RetirementSession {
                view: view.clone(),
                grant,
                available,
                prepared: None,
            },
        );
        Ok(view)
    }
    async fn retirement_prepare(
        &mut self,
        handle: &str,
        token: &str,
        key: &str,
        selection: &str,
    ) -> Result<ExportRetirementReviewView, BridgeError> {
        let selection = match selection {
            "target" => ExportRetirementChoice::Target,
            "staged" => ExportRetirementChoice::Staged,
            _ => return Err(failure("INVALID_EXPORT_RETIREMENT")),
        };
        let host = self.current(handle)?;
        let scope = host
            .export_retirements
            .get_mut(token)
            .filter(|s| s.available.load(Ordering::Acquire))
            .ok_or_else(|| failure("EXPORT_RETIREMENT_CLOSED"))?;
        scope.prepared.take();
        let read = host
            .export_checks
            .get(&scope.view.read_session_token)
            .filter(|s| s.available.load(Ordering::Acquire))
            .ok_or_else(|| failure("EXPORT_INSPECTION_CLOSED"))?;
        let prepared = host
            .journal
            .prepare_export_retirement(&read.grant, &scope.grant, selection, key)
            .await
            .map_err(error)?;
        let v = prepared.preview().map_err(error)?;
        let view = ExportRetirementReviewView {
            session_token: token.into(),
            retirement_id: v.retirement_id.clone(),
            export_id: v.export_id.clone(),
            digest: v.digest.clone(),
            choice: choice(v.choice),
            file_name: v.file_name.clone(),
            observed: export_inspection::observed(&v.observed),
            expires_at: v.expires_at,
        };
        if !scope.available.load(Ordering::Acquire) || !read.available.load(Ordering::Acquire) {
            return Err(failure("EXPORT_RETIREMENT_CLOSED"));
        }
        scope.prepared = Some(prepared);
        Ok(view)
    }
    async fn retirement_approve(
        &mut self,
        handle: &str,
        token: &str,
        id: &str,
        digest: &str,
    ) -> Result<ExportRetirementOutcomeView, BridgeError> {
        let host = self.current(handle)?;
        let scope = host
            .export_retirements
            .get_mut(token)
            .filter(|s| s.available.load(Ordering::Acquire))
            .ok_or_else(|| failure("EXPORT_RETIREMENT_CLOSED"))?;
        let prepared = scope
            .prepared
            .take()
            .ok_or_else(|| failure("EXPORT_RETIREMENT_PREVIEW_CHANGED"))?;
        let v = prepared.preview().map_err(error)?;
        if v.retirement_id != id || v.digest != digest {
            return Err(failure("EXPORT_RETIREMENT_PREVIEW_CHANGED"));
        }
        let read = host
            .export_checks
            .get(&scope.view.read_session_token)
            .filter(|s| s.available.load(Ordering::Acquire))
            .ok_or_else(|| failure("EXPORT_INSPECTION_CLOSED"))?;
        host.journal
            .approve_export_retirement(&read.grant, &scope.grant, prepared, digest)
            .await
            .map_err(error)?;
        let value = host
            .journal
            .export_retirement_outcome(
                LOCAL_OWNER,
                &scope.view.run_id,
                &scope.view.operation_id,
                id,
            )
            .map_err(error)?
            .ok_or_else(|| failure("EXPORT_RETIREMENT_UNCONFIRMED"))?;
        Ok(outcome(value))
    }
    pub(super) async fn close_export_retirements(
        &mut self,
        handle: &str,
        reader: Option<&str>,
        token: Option<&str>,
    ) -> Result<(), BridgeError> {
        let signals = self.signals.clone();
        let host = self.current(handle)?;
        let ids: Vec<_> = host
            .export_retirements
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
                if let Some(mut scope) = host.export_retirements.remove(&id) {
                    scope.available.store(false, Ordering::Release);
                    scope.grant.request_revoke();
                    // Drop cached read/write permits before waiting for either grant.
                    scope.prepared.take();
                    grants.push(scope.grant);
                }
                c.closed_recovery_selections.insert(id.clone());
                c.export_retirements.remove(&id);
            }
        }
        for grant in grants {
            grant.wait_drained().await;
        }
        Ok(())
    }
}
pub(crate) async fn authorize_export_retirement(
    handle: String,
    reader: String,
    token: String,
    directory: String,
) -> Result<ExportRetirementAccessView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, _| {
        host.retirement_authorize(&handle, &reader, &token, Path::new(&directory))
    })
    .await
}
pub(crate) async fn prepare_export_retirement(
    handle: String,
    token: String,
    key: String,
    selection: String,
) -> Result<ExportRetirementReviewView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.retirement_prepare(&handle, &token, &key, &selection))
    })
    .await
}
pub(crate) async fn approve_export_retirement(
    handle: String,
    token: String,
    id: String,
    digest: String,
) -> Result<ExportRetirementOutcomeView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.retirement_approve(&handle, &token, &id, &digest))
    })
    .await
}
pub(crate) async fn suspend_export_retirement(
    handle: String,
    token: String,
) -> Result<(), BridgeError> {
    crate::actor::signal_export_retirement_release(&handle, &token)?;
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.close_export_retirements(&handle, None, Some(&token)))
    })
    .await
}
pub(crate) async fn list_export_retirements(
    handle: String,
    run: String,
    operation: String,
    export: String,
    before: Option<String>,
    limit: u16,
) -> Result<Vec<ExportRetirementOutcomeView>, BridgeError> {
    crate::actor::call(handle.clone(), move |host, _| {
        Ok(host
            .current(&handle)?
            .journal
            .export_retirement_outcomes(
                LOCAL_OWNER,
                &run,
                &operation,
                &export,
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
pub(crate) async fn inspect_export_retirement(
    handle: String,
    reader: String,
    id: String,
) -> Result<ExportRetirementInspectionView, BridgeError> {
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
                .inspect_export_retirement(&read.grant, &id)
                .await
                .map_err(error)?;
            let v = receipt.view().map_err(error)?;
            let view = ExportRetirementInspectionView {
                session_token: reader.clone(),
                retirement_id: v.retirement_id.clone(),
                export_id: read.view.export_id.clone(),
                recorded_state: v.recorded_state.clone(),
                choice: choice(v.choice),
                capsule_bound: v.capsule_bound,
                retained: v.retained.as_ref().map(export_inspection::observed),
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
