use super::*;
use orange_agent_runtime::workspace::patch::review::dispatch::recovery::retention::PatchRetentionGrant;

pub(crate) struct RetentionSignal {
    pub workspace: String,
    pub workspace_version: String,
    pub grant: Arc<PatchRetentionGrant>,
    pub available: Arc<AtomicBool>,
}
impl RetentionSignal {
    pub(crate) fn suspend(&self) {
        self.available.store(false, Ordering::Release);
        self.grant.request_revoke();
    }
}

pub(crate) fn signal_retention_release(handle: &str, token: &str) -> Result<(), BridgeError> {
    if !orange_protocol::valid_id(token) {
        return Err(failure("INVALID_RETENTION_REQUEST"));
    }
    let registry = SESSION.lock().map_err(|_| failure("HOST_INTERNAL"))?;
    let session = registry
        .as_ref()
        .filter(|s| s.view.handle == handle && !s.closed.load(Ordering::Acquire))
        .ok_or_else(|| failure("STALE_HOST_HANDLE"))?;
    let mut signals = session
        .signals
        .lock()
        .map_err(|_| failure("HOST_INTERNAL"))?;
    if signals.recovery_inspections.contains_key(token)
        || signals.recovery_writes.contains_key(token)
        || signals.exports.contains_key(token)
    {
        return Err(failure("RETENTION_SELECTION_CONFLICT"));
    }
    if signals.closed_recovery_selections.len() < 8192 || signals.retentions.contains_key(token) {
        signals.closed_recovery_selections.insert(token.into());
    }
    let children: Vec<_> = signals
        .exports
        .iter()
        .filter(|(_, s)| s.reader == token)
        .map(|(id, _)| id.clone())
        .collect();
    for id in children {
        signals.closed_recovery_selections.insert(id.clone());
        if let Some(scope) = signals.exports.get(&id) {
            scope.suspend();
        }
    }
    if let Some(scope) = signals.retentions.get(token) {
        scope.suspend();
    }
    Ok(())
}

pub(crate) struct ExportSignal {
    pub workspace: String,
    pub reader: String,
    pub grant: Arc<orange_agent_runtime::workspace::patch::review::dispatch::recovery::retention::RetentionExportDestination>,
    pub available: Arc<AtomicBool>,
}
impl ExportSignal {
    pub(crate) fn suspend(&self) {
        self.available.store(false, Ordering::Release);
        self.grant.request_revoke();
    }
}
pub(crate) fn signal_export_release(handle: &str, token: &str) -> Result<(), BridgeError> {
    if !orange_protocol::valid_id(token) {
        return Err(failure("INVALID_EXPORT_REQUEST"));
    }
    let registry = SESSION.lock().map_err(|_| failure("HOST_INTERNAL"))?;
    let session = registry
        .as_ref()
        .filter(|s| s.view.handle == handle && !s.closed.load(Ordering::Acquire))
        .ok_or_else(|| failure("STALE_HOST_HANDLE"))?;
    let mut signals = session
        .signals
        .lock()
        .map_err(|_| failure("HOST_INTERNAL"))?;
    if signals.retentions.contains_key(token)
        || signals.recovery_inspections.contains_key(token)
        || signals.recovery_writes.contains_key(token)
    {
        return Err(failure("EXPORT_SELECTION_CONFLICT"));
    }
    if signals.closed_recovery_selections.len() < 8192 || signals.exports.contains_key(token) {
        signals.closed_recovery_selections.insert(token.into());
    }
    if let Some(scope) = signals.exports.get(token) {
        scope.suspend();
    }
    Ok(())
}
