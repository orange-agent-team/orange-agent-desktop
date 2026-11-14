use super::*;
use orange_agent_runtime::workspace::patch::review::dispatch::recovery::inspection::PatchInspectionGrant;

pub(crate) struct RecoveryInspectionSignal {
    pub workspace: String,
    pub workspace_version: String,
    pub read: Arc<PatchInspectionGrant>,
    pub available: Arc<AtomicBool>,
}
impl RecoveryInspectionSignal {
    pub(crate) fn suspend(&self) {
        self.available.store(false, Ordering::Release);
        self.read.request_revoke();
    }
}
impl Signals {
    pub(crate) fn stop_recovery_workspace(&mut self, workspace: &str) {
        // Constructors register their epoch before opening a capability, so a
        // concurrent workspace stop also fences a not-yet-published selection.
        if let Some(epoch) = self.recovery_epochs.get_mut(workspace) {
            *epoch = epoch.saturating_add(1);
        }
        for scope in self
            .recovery_inspections
            .values()
            .filter(|s| s.workspace == workspace)
        {
            scope.suspend();
        }
    }
}
pub(crate) fn signal_recovery_inspection_release(
    handle: &str,
    token: &str,
) -> Result<(), BridgeError> {
    if !orange_protocol::valid_id(token) {
        return Err(failure("INVALID_RECOVERY_REQUEST"));
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
    if signals.closed_recovery_selections.len() < 8192
        || signals.recovery_inspections.contains_key(token)
    {
        signals.closed_recovery_selections.insert(token.into());
    }
    if let Some(scope) = signals.recovery_inspections.get(token) {
        scope.suspend();
    }
    Ok(())
}
