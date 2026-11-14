use super::*;

pub(crate) fn signal_editing_release(
    handle: &str,
    token: &str,
) -> Result<Option<String>, BridgeError> {
    if !orange_protocol::valid_id(token) {
        return Err(failure("INVALID_EDITING_REQUEST"));
    }
    let registry = SESSION.lock().map_err(|_| failure("HOST_INTERNAL"))?;
    let session = registry
        .as_ref()
        .filter(|s| s.view.handle == handle && !s.closed.load(Ordering::Acquire))
        .ok_or_else(|| failure("STALE_HOST_HANDLE"))?;
    let mut controls = session
        .signals
        .lock()
        .map_err(|_| failure("HOST_INTERNAL"))?;
    let id = controls
        .editings
        .iter()
        .find(|(_, c)| c.token == token)
        .map(|(id, _)| id.clone());
    if controls.closed_editing_selections.len() < 8192 || id.is_some() {
        controls.closed_editing_selections.insert(token.into());
    }
    if let Some(id) = &id {
        let current = &controls.editings[id];
        current.suspend();
        // Stop only Runs bound to this consent before queued journal work.
        for run in controls
            .runs
            .values()
            .filter(|r| r.editing_id.as_deref() == Some(id.as_str()))
        {
            if let Some(edit) = &run.editing_grant {
                edit.request_revoke();
            }
            run.cancel.send_replace(true);
        }
    }
    Ok(id)
}
pub(crate) fn signal_editing_revoke(
    handle: &str,
    id: &str,
    version: &str,
) -> Result<(), BridgeError> {
    let registry = SESSION.lock().map_err(|_| failure("HOST_INTERNAL"))?;
    let session = registry
        .as_ref()
        .filter(|s| s.view.handle == handle && !s.closed.load(Ordering::Acquire))
        .ok_or_else(|| failure("STALE_HOST_HANDLE"))?;
    let controls = session
        .signals
        .lock()
        .map_err(|_| failure("HOST_INTERNAL"))?;
    if let Some(current) = controls.editings.get(id) {
        if current.version != version {
            return Err(failure("EDITING_PERMISSION_CHANGED"));
        }
        current.suspend();
        current.revoker.request_revoke();
        for run in controls
            .runs
            .values()
            .filter(|r| r.editing_id.as_deref() == Some(id))
        {
            if let Some(edit) = &run.editing_grant {
                edit.request_revoke();
            }
            run.cancel.send_replace(true);
        }
    }
    Ok(())
}
