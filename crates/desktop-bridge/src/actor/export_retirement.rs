use super::*;
use orange_agent_runtime::workspace::patch::review::dispatch::recovery::retention::ExportRetirementGrant;
pub(crate) struct ExportRetirementSignal {
    pub reader: String,
    pub grant: Arc<ExportRetirementGrant>,
    pub available: Arc<AtomicBool>,
}
impl ExportRetirementSignal {
    pub(crate) fn suspend(&self) {
        self.available.store(false, Ordering::Release);
        self.grant.request_revoke();
    }
}
pub(crate) fn signal_export_retirement_release(
    handle: &str,
    token: &str,
) -> Result<(), BridgeError> {
    if !orange_protocol::valid_id(token) {
        return Err(failure("INVALID_EXPORT_RETIREMENT"));
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
    if crate::host::export_retirement_foreign(&signals, token) {
        return Err(failure("EXPORT_RETIREMENT_CONFLICT"));
    }
    if signals.closed_recovery_selections.len() < 8192
        || signals.export_retirements.contains_key(token)
    {
        signals.closed_recovery_selections.insert(token.into());
    }
    if let Some(scope) = signals.export_retirements.get(token) {
        scope.suspend();
    }
    Ok(())
}
