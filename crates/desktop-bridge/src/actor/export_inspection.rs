use super::*;
use orange_agent_runtime::workspace::patch::review::dispatch::recovery::retention::ExportInspectionGrant;

pub(crate) struct ExportInspectionSignal {
    pub grant: Arc<ExportInspectionGrant>,
    pub available: Arc<AtomicBool>,
}
impl ExportInspectionSignal {
    pub(crate) fn suspend(&self) {
        self.available.store(false, Ordering::Release);
        self.grant.request_revoke();
    }
}
pub(crate) fn signal_export_inspection_release(
    handle: &str,
    token: &str,
) -> Result<(), BridgeError> {
    if !orange_protocol::valid_id(token) {
        return Err(failure("INVALID_EXPORT_INSPECTION"));
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
        || signals.exports.contains_key(token)
        || signals.recovery_inspections.contains_key(token)
        || signals.recovery_writes.contains_key(token)
    {
        return Err(failure("EXPORT_INSPECTION_CONFLICT"));
    }
    if signals.closed_recovery_selections.len() < 8192 || signals.export_checks.contains_key(token)
    {
        signals.closed_recovery_selections.insert(token.into());
    }
    if let Some(scope) = signals.export_checks.get(token) {
        scope.suspend();
    }
    Ok(())
}
