use super::*;
use crate::api::host::RecoveryWriteAccessView;
use orange_agent_runtime::workspace::patch::review::dispatch::recovery::resolution::{
    PatchRecoveryChoice, PatchRecoveryGrant, PatchResolutionReview,
};

pub(crate) struct WriteSession {
    pub(super) view: RecoveryWriteAccessView,
    pub(super) write: Arc<PatchRecoveryGrant>,
    pub(super) available: Arc<AtomicBool>,
    review: Option<PatchResolutionReview>,
}
impl HostRegistry {
    pub(super) async fn close_recovery_writes(
        &mut self,
        handle: &str,
        reader: Option<&str>,
        token: Option<&str>,
    ) -> Result<(), BridgeError> {
        let signals = self.signals.clone();
        let host = self.current(handle)?;
        let ids: Vec<_> = host
            .recovery_writes
            .iter()
            .filter(|(id, s)| {
                reader.is_some_and(|r| s.view.read_session_token == r)
                    || token.is_some_and(|t| id.as_str() == t)
            })
            .map(|(id, _)| id.clone())
            .collect();
        let mut leases = Vec::new();
        {
            let mut controls = signals.lock().map_err(|_| failure("HOST_INTERNAL"))?;
            for id in ids {
                if let Some(scope) = host.recovery_writes.remove(&id) {
                    scope.available.store(false, Ordering::Release);
                    scope.write.request_revoke();
                    leases.push(scope.write);
                }
                controls.closed_recovery_selections.insert(id.clone());
                controls.recovery_writes.remove(&id);
            }
        }
        for lease in leases {
            lease.wait_drained().await;
        }
        Ok(())
    }
    fn authorize_recovery_write(
        &mut self,
        handle: &str,
        reader: &str,
        token: &str,
        selected: &Path,
    ) -> Result<RecoveryWriteAccessView, BridgeError> {
        if !orange_protocol::valid_id(token) || !selected.is_absolute() || selected.is_symlink() {
            return Err(failure("INVALID_RECOVERY_REQUEST"));
        }
        let signals = self.signals.clone();
        let host = self.current(handle)?;
        let read = host
            .recovery_inspections
            .get(reader)
            .filter(|s| s.available.load(Ordering::Acquire))
            .ok_or_else(|| failure("RECOVERY_SELECTION_CLOSED"))?;
        {
            let controls = signals.lock().map_err(|_| failure("HOST_INTERNAL"))?;
            if other_selection_kind(&controls, token)
                || controls.recovery_inspections.contains_key(token)
            {
                return Err(failure("RECOVERY_SELECTION_CONFLICT"));
            }
            if controls.closed_recovery_selections.contains(token)
                || controls.closed_recovery_selections.len() >= 8192
            {
                return Err(failure("RECOVERY_SELECTION_CLOSED"));
            }
        }
        let directory = selected
            .canonicalize()
            .map_err(|_| failure("RECOVERY_WORKSPACE_CHANGED"))?;
        let directory = directory
            .to_str()
            .filter(|s| s.len() <= 4096)
            .ok_or_else(|| failure("INVALID_RECOVERY_REQUEST"))?
            .to_owned();
        if let Some(old) = host.recovery_writes.get(token) {
            if old.view.read_session_token != reader || old.view.display_directory != directory {
                return Err(failure("RECOVERY_SELECTION_CONFLICT"));
            }
            return if old.available.load(Ordering::Acquire) {
                Ok(old.view.clone())
            } else {
                Err(failure("RECOVERY_SELECTION_CLOSED"))
            };
        }
        if host.recovery_writes.len() >= 32 {
            return Err(failure("RECOVERY_SELECTION_LIMIT"));
        }
        let write = Arc::new(
            host.journal
                .authorize_selected_patch_recovery(&read.read, Path::new(&directory))
                .map_err(error)?,
        );
        let available = Arc::new(AtomicBool::new(true));
        let view = RecoveryWriteAccessView {
            session_token: token.into(),
            read_session_token: reader.into(),
            run_id: read.view.run_id.clone(),
            operation_id: read.view.operation_id.clone(),
            workspace_id: read.view.workspace_id.clone(),
            display_directory: directory,
        };
        {
            let mut controls = signals.lock().map_err(|_| failure("HOST_INTERNAL"))?;
            if !read.available.load(Ordering::Acquire)
                || controls.closed_recovery_selections.contains(token)
                || controls.closed_recovery_selections.contains(reader)
                || controls.closed_recovery_selections.len() >= 8192
                || other_selection_kind(&controls, token)
                || controls.recovery_inspections.contains_key(token)
            {
                write.request_revoke();
                return Err(failure("RECOVERY_SELECTION_CLOSED"));
            }
            controls.recovery_writes.insert(
                token.into(),
                crate::actor::RecoveryWriteSignal {
                    workspace: view.workspace_id.clone(),
                    reader: reader.into(),
                    write: write.clone(),
                    available: available.clone(),
                },
            );
        }
        host.recovery_writes.insert(
            token.into(),
            WriteSession {
                view: view.clone(),
                write,
                available,
                review: None,
            },
        );
        Ok(view)
    }
}
fn choice(value: &str) -> Result<PatchRecoveryChoice, BridgeError> {
    match value {
        "keep_current_target" => Ok(PatchRecoveryChoice::KeepCurrentTarget),
        "restore_original_to_missing_target" => {
            Ok(PatchRecoveryChoice::RestoreOriginalToMissingTarget)
        }
        "publish_staged_to_missing_target" => Ok(PatchRecoveryChoice::PublishStagedToMissingTarget),
        _ => Err(failure("INVALID_RECOVERY_CHOICE")),
    }
}
impl HostRegistry {
    async fn prepare_recovery(
        &mut self,
        handle: &str,
        reader: &str,
        writer: &str,
        request: &str,
        selection: &str,
    ) -> Result<crate::api::host::RecoveryDecisionView, BridgeError> {
        let selected = choice(selection)?;
        let host = self.current(handle)?;
        let read = host
            .recovery_inspections
            .get(reader)
            .filter(|s| s.available.load(Ordering::Acquire))
            .ok_or_else(|| failure("RECOVERY_SELECTION_CLOSED"))?;
        let write = host
            .recovery_writes
            .get_mut(writer)
            .filter(|s| s.available.load(Ordering::Acquire) && s.view.read_session_token == reader)
            .ok_or_else(|| failure("RECOVERY_SELECTION_CLOSED"))?;
        write.review = None;
        let review = host
            .journal
            .prepare_selected_patch_resolution(&read.read, &write.write, request, selected)
            .await
            .map_err(error)?;
        if !read.available.load(Ordering::Acquire) || !write.available.load(Ordering::Acquire) {
            return Err(failure("RECOVERY_SELECTION_CLOSED"));
        }
        let view = crate::api::host::RecoveryDecisionView {
            read_session_token: reader.into(),
            write_session_token: writer.into(),
            recovery_id: review.recovery_id.clone(),
            digest: review.digest.clone(),
            choice: selection.into(),
            inspection: snapshot_view(
                &read.view.run_id,
                &read.view.operation_id,
                &review.snapshot,
            )?,
        };
        write.review = Some(review);
        Ok(view)
    }
    async fn approve_recovery(
        &mut self,
        handle: &str,
        reader: &str,
        writer: &str,
        recovery: &str,
        digest: &str,
    ) -> Result<crate::api::host::RecoveryOutcomeView, BridgeError> {
        let host = self.current(handle)?;
        let read = host
            .recovery_inspections
            .get(reader)
            .filter(|s| s.available.load(Ordering::Acquire))
            .ok_or_else(|| failure("RECOVERY_SELECTION_CLOSED"))?;
        let write = host
            .recovery_writes
            .get_mut(writer)
            .filter(|s| s.available.load(Ordering::Acquire) && s.view.read_session_token == reader)
            .ok_or_else(|| failure("RECOVERY_SELECTION_CLOSED"))?;
        if !write
            .review
            .as_ref()
            .is_some_and(|r| r.recovery_id == recovery && r.digest == digest)
        {
            return Err(failure("RECOVERY_PREVIEW_CHANGED"));
        }
        let review = write
            .review
            .take()
            .ok_or_else(|| failure("RECOVERY_PREVIEW_CHANGED"))?;
        host.journal
            .approve_selected_patch_resolution(
                &read.read,
                &write.write,
                recovery,
                digest,
                runs::now()? + 60,
            )
            .await
            .map_err(error)?;
        let token = host
            .journal
            .dispatch_selected_patch_resolution(&read.read, &write.write, recovery)
            .await
            .map_err(error)?;
        let result =
            host.journal
                .publish_selected_patch_resolution(&read.read, &write.write, token);
        write.available.store(false, Ordering::Release);
        write.write.request_revoke();
        let result = result.map_err(error)?;
        if result.recovery_id != recovery
            || result.operation_id != read.view.operation_id
            || result.choice != review.choice
        {
            return Err(failure("RECOVERY_OUTCOME_UNCONFIRMED"));
        }
        let outcome = host
            .journal
            .agent_patch_recovery_outcome(LOCAL_OWNER, &read.view.run_id, &read.view.operation_id)
            .map_err(runs::engine_error)?;
        if !outcome
            .decision
            .as_ref()
            .is_some_and(|d| d.recovery_id == recovery && d.choice == review.choice)
        {
            return Err(failure("RECOVERY_OUTCOME_UNCONFIRMED"));
        }
        for other in host
            .recovery_writes
            .values()
            .filter(|w| w.view.operation_id == result.operation_id)
        {
            other.available.store(false, Ordering::Release);
            other.write.request_revoke();
        }
        Ok(outcome_view(outcome))
    }
}
pub(crate) async fn prepare_recovery_decision(
    handle: String,
    reader: String,
    writer: String,
    request: String,
    selection: String,
) -> Result<crate::api::host::RecoveryDecisionView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.prepare_recovery(&handle, &reader, &writer, &request, &selection))
    })
    .await
}
pub(crate) async fn approve_recovery_decision(
    handle: String,
    reader: String,
    writer: String,
    recovery: String,
    digest: String,
) -> Result<crate::api::host::RecoveryOutcomeView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.approve_recovery(&handle, &reader, &writer, &recovery, &digest))
    })
    .await
}
pub(crate) async fn authorize_recovery_write_access(
    handle: String,
    reader: String,
    token: String,
    directory: String,
) -> Result<RecoveryWriteAccessView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, _| {
        host.authorize_recovery_write(&handle, &reader, &token, Path::new(&directory))
    })
    .await
}
pub(crate) async fn suspend_recovery_write_selection(
    handle: String,
    token: String,
) -> Result<(), BridgeError> {
    crate::actor::signal_recovery_write_release(&handle, &token)?;
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.close_recovery_writes(&handle, None, Some(&token)))
    })
    .await
}
