use super::*;
use orange_agent_runtime::memory::{MemoryGrant, MemoryScopeRevoker};
pub(crate) struct MemorySignal {
    pub token: String,
    pub revision: String,
    pub grant: MemoryGrant,
    pub revoker: Option<MemoryScopeRevoker>,
    pub available: Arc<AtomicBool>,
}
impl MemorySignal {
    pub fn suspend(&self) {
        self.available.store(false, Ordering::Release);
        self.grant.request_revoke();
    }
}
pub(crate) fn release(handle: &str, token: &str) -> Result<Option<String>, BridgeError> {
    if !orange_protocol::valid_id(token) {
        return Err(failure("INVALID_MEMORY_REQUEST"));
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
        .memories
        .iter()
        .find(|(_, s)| s.token == token)
        .map(|(id, _)| id.clone());
    if controls.closed_memory_selections.len() < 8192 || id.is_some() {
        controls.closed_memory_selections.insert(token.into());
    }
    if let Some(id) = &id {
        controls.memories[id].suspend();
    }
    Ok(id)
}
pub(crate) fn change(
    handle: &str,
    scope: &str,
    revision: &str,
    new_token: Option<&str>,
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
    if let Some(current) = controls.memories.get(scope) {
        if current.revision != revision {
            return Err(failure("MEMORY_SCOPE_CHANGED"));
        }
        if new_token == Some(current.token.as_str()) {
            return Ok(());
        }
        if new_token.is_none() && current.revoker.is_none() {
            return Err(failure("MEMORY_FORBIDDEN"));
        }
        current.suspend();
        // The selected session wakes this Host's in-flight work immediately.
        // Scope-wide withdrawal happens after the owner mutation succeeds in
        // Journal; a rejected quota/CAS request must not poison a live revision.
    }
    Ok(())
}

/// A delivery fence for explicitly selected session access. It contains flags
/// only, so a pending response cannot prevent resource drain on close.
pub(crate) struct ReplyGuard {
    closed: Arc<AtomicBool>,
    memories: Vec<MemoryGrant>,
    workspaces: Vec<WorkspaceGrant>,
}
impl ReplyGuard {
    pub fn check(&self) -> Result<(), BridgeError> {
        if self.closed.load(Ordering::Acquire)
            || self.memories.iter().any(|g| g.is_revoked())
            || self.workspaces.iter().any(|g| g.is_revoked())
        {
            return Err(failure("MEMORY_SESSION_ACCESS_REQUIRED"));
        }
        Ok(())
    }
}
pub(crate) fn capture(
    handle: &str,
    selection: &crate::api::memory::MemorySelection,
) -> Result<ReplyGuard, BridgeError> {
    if selection.sources.workspace_ids.len() > 17 || selection.sources.memory_tokens.len() > 23 {
        return Err(failure("INVALID_MEMORY_REQUEST"));
    }
    let registry = SESSION.lock().map_err(|_| failure("HOST_INTERNAL"))?;
    let session = registry
        .as_ref()
        .filter(|s| s.view.handle == handle && !s.closed.load(Ordering::Acquire))
        .ok_or_else(|| failure("STALE_HOST_HANDLE"))?;
    let signals = session
        .signals
        .lock()
        .map_err(|_| failure("HOST_INTERNAL"))?;
    let primary = signals
        .memories
        .get(&selection.scope_id)
        .filter(|s| s.token == selection.session_token && s.available.load(Ordering::Acquire))
        .ok_or_else(|| failure("MEMORY_SESSION_ACCESS_REQUIRED"))?;
    let mut memories = vec![primary.grant.clone()];
    for token in &selection.sources.memory_tokens {
        memories.push(
            signals
                .memories
                .values()
                .find(|s| s.token == *token && s.available.load(Ordering::Acquire))
                .ok_or_else(|| failure("MEMORY_SOURCE_REQUIRED"))?
                .grant
                .clone(),
        );
    }
    let mut workspaces = vec![];
    for id in &selection.sources.workspace_ids {
        workspaces.push(
            signals
                .workspaces
                .get(id)
                .ok_or_else(|| failure("MEMORY_SOURCE_REQUIRED"))?
                .grant
                .clone(),
        );
    }
    let guard = ReplyGuard {
        closed: session.closed.clone(),
        memories,
        workspaces,
    };
    guard.check()?;
    Ok(guard)
}
