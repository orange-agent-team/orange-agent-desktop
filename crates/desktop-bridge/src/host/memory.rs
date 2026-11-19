//! Authenticated native memory management; no model-selected actor or policy.
use super::*;
use crate::api::memory as api;
use orange_agent_runtime::{
    engine::{ManagedMemoryReview, MemoryManagementAuthority, MemoryReadSelection},
    memory as store,
};
use std::sync::atomic::{AtomicBool, Ordering};
pub(super) struct MemorySession {
    pub token: String,
    pub revision: String,
    pub write: bool,
    pub grant: store::MemoryGrant,
    pub available: Arc<AtomicBool>,
}
fn memory_error(error: store::MemoryError) -> BridgeError {
    failure(match error {
        store::MemoryError::Denied => "MEMORY_FORBIDDEN",
        store::MemoryError::Conflict => "MEMORY_VERSION_CHANGED",
        store::MemoryError::ApprovalRequired => "MEMORY_APPROVAL_REQUIRED",
        store::MemoryError::SourceRequired => "MEMORY_SOURCE_REQUIRED",
        store::MemoryError::Limit => "MEMORY_LIMIT",
        store::MemoryError::Invalid => "INVALID_MEMORY_REQUEST",
        _ => "MEMORY_STORAGE_UNAVAILABLE",
    })
}
fn access(value: store::MemoryAccess) -> String {
    match value {
        store::MemoryAccess::Read => "read",
        store::MemoryAccess::Write => "write",
        store::MemoryAccess::Revoked => "revoked",
    }
    .into()
}
fn origin(value: store::MemoryOrigin) -> String {
    match value {
        store::MemoryOrigin::UserDeclaration => "user_declaration",
        store::MemoryOrigin::ModelInference => "model_inference",
    }
    .into()
}
fn scope_view(
    host: &Host,
    scope: store::MemoryScope,
    permission: store::MemoryAccess,
) -> api::MemoryScopeView {
    let session = host.memories.get(&scope.scope_id).filter(|s| {
        s.available.load(Ordering::Acquire)
            && !s.grant.is_revoked()
            && s.revision == scope.revision
            && scope.enabled
    });
    api::MemoryScopeView {
        can_administer: scope.owner == LOCAL_OWNER,
        session_token: session.map(|s| s.token.clone()),
        session_write: session.is_some_and(|s| s.write),
        scope_id: scope.scope_id,
        owner: scope.owner,
        shared: scope.shared,
        revision: scope.revision,
        enabled: scope.enabled,
        access: access(permission),
    }
}
fn entry(value: &store::MemoryValue) -> api::MemoryEntry {
    api::MemoryEntry {
        scope_id: value.scope_id.clone(),
        entry_id: value.entry_id.clone(),
        version: value.version.clone(),
        title: value.title.clone(),
        content: value.content.clone(),
        enabled: value.enabled,
        origin: origin(value.origin),
        source_actor: value.source_actor.clone(),
        source_run: value.source_run.clone(),
        total_bytes: value.total_bytes.clone(),
        start_byte: value.start_byte.clone(),
        next_byte: value.next_byte.clone(),
    }
}
fn review(value: ManagedMemoryReview) -> api::MemoryReview {
    let r = value.review;
    api::MemoryReview {
        draft_id: r.draft_id,
        scope_id: r.scope_id,
        entry_id: r.entry_id,
        expected_version: r.expected_version,
        approval_digest: value.approval_digest,
        source_run: r.source_run,
        title: r.payload.as_ref().map(|p| p.title.clone()),
        content: r.payload.as_ref().map(|p| p.content.clone()),
        enabled: r.payload.as_ref().map(|p| p.enabled),
        delete: r.mutation == store::MemoryMutation::Delete,
        expires_at: r.expires_at.to_string(),
        prior: value.prior.as_ref().map(entry),
    }
}
fn outcome(value: store::MemoryDraftOutcome) -> api::MemoryOutcome {
    api::MemoryOutcome {
        draft_id: value.draft_id,
        scope_id: value.scope_id,
        entry_id: value.entry_id,
        digest: value.digest,
        state: value.state,
        result_version: value.result_version,
    }
}
struct Selected {
    grant: store::MemoryGrant,
    workspaces: Vec<workspace::WorkspaceGrant>,
    memories: Vec<store::MemoryGrant>,
}
impl Selected {
    fn authority(&self) -> MemoryManagementAuthority<'_> {
        MemoryManagementAuthority::new(&self.grant)
            .with_source_workspaces(&self.workspaces)
            .with_source_memories(&self.memories)
    }
}
fn selected(host: &Host, selection: &api::MemorySelection) -> Result<Selected, BridgeError> {
    if selection.sources.workspace_ids.len() > 17 || selection.sources.memory_tokens.len() > 23 {
        return Err(failure("INVALID_MEMORY_REQUEST"));
    }
    let session = host
        .memories
        .get(&selection.scope_id)
        .filter(|s| {
            s.token == selection.session_token
                && s.available.load(Ordering::Acquire)
                && !s.grant.is_revoked()
        })
        .ok_or_else(|| failure("MEMORY_SESSION_ACCESS_REQUIRED"))?;
    let mut seen = std::collections::HashSet::new();
    let mut workspaces = Vec::new();
    for id in &selection.sources.workspace_ids {
        if !seen.insert(id) {
            return Err(failure("INVALID_MEMORY_REQUEST"));
        }
        workspaces.push(
            host.grants
                .get(id)
                .filter(|g| !g.is_revoked())
                .ok_or_else(|| failure("MEMORY_SOURCE_REQUIRED"))?
                .clone(),
        );
    }
    let mut seen = std::collections::HashSet::new();
    let mut memories = Vec::new();
    for token in &selection.sources.memory_tokens {
        if !seen.insert(token) {
            return Err(failure("INVALID_MEMORY_REQUEST"));
        }
        memories.push(
            host.memories
                .values()
                .find(|s| {
                    s.token == *token
                        && s.available.load(Ordering::Acquire)
                        && !s.grant.is_revoked()
                })
                .ok_or_else(|| failure("MEMORY_SOURCE_REQUIRED"))?
                .grant
                .clone(),
        );
    }
    Ok(Selected {
        grant: session.grant.clone(),
        workspaces,
        memories,
    })
}
impl HostRegistry {
    fn memory_scopes(
        &mut self,
        handle: &str,
        cursor: Option<&str>,
        limit: u16,
    ) -> Result<api::MemoryScopePage, BridgeError> {
        let host = self.current(handle)?;
        let page = host
            .journal
            .list_memory_scopes(LOCAL_OWNER, cursor, limit)
            .map_err(memory_error)?;
        Ok(api::MemoryScopePage {
            scopes: page
                .scopes
                .into_iter()
                .map(|v| scope_view(host, v.scope, v.access))
                .collect(),
            next_cursor: page.next_cursor,
        })
    }
    async fn memory_authorize(
        &mut self,
        handle: &str,
        scope: &str,
        revision: &str,
        request: &str,
        write: bool,
    ) -> Result<api::MemoryAccessView, BridgeError> {
        if !orange_protocol::valid_id(request) {
            return Err(failure("INVALID_MEMORY_REQUEST"));
        }
        let signals = self.signals.clone();
        {
            let controls = signals.lock().map_err(|_| failure("HOST_INTERNAL"))?;
            if controls.closed_memory_selections.contains(request)
                || controls.closed_memory_selections.len() >= 8192
            {
                return Err(failure("MEMORY_SELECTION_CLOSED"));
            }
            if controls
                .memories
                .iter()
                .any(|(id, s)| s.token == request && id != scope)
            {
                return Err(failure("MEMORY_REQUEST_CONFLICT"));
            }
        }
        let host = self.current(handle)?;
        let snapshot = host
            .journal
            .memory_scope(LOCAL_OWNER, scope)
            .map_err(memory_error)?;
        if snapshot.revision != revision {
            return Err(failure("MEMORY_SCOPE_CHANGED"));
        }
        if let Some(old) = host.memories.get(scope)
            && old.token == request
        {
            if old.write != write
                || old.revision != revision
                || !old.available.load(Ordering::Acquire)
                || old.grant.is_revoked()
            {
                return Err(failure("MEMORY_SELECTION_CLOSED"));
            }
            host.journal
                .memory_capability(&old.grant, LOCAL_OWNER, READ_POLICY)
                .map_err(memory_error)?;
            return Ok(api::MemoryAccessView {
                scope_id: snapshot.scope_id,
                revision: snapshot.revision,
                session_token: old.token.clone(),
                write: old.write,
            });
        }
        let grant = host
            .journal
            .authorize_memory(LOCAL_OWNER, scope, READ_POLICY, write)
            .map_err(memory_error)?;
        let revoker = if snapshot.owner == LOCAL_OWNER {
            Some(
                host.journal
                    .memory_scope_revoker(LOCAL_OWNER, scope, revision)
                    .map_err(memory_error)?,
            )
        } else {
            None
        };
        if let Some(old) = host.memories.remove(scope) {
            old.available.store(false, Ordering::Release);
            old.grant.request_revoke();
            old.grant.wait_drained().await;
            signals
                .lock()
                .map_err(|_| failure("HOST_INTERNAL"))?
                .closed_memory_selections
                .insert(old.token);
        }
        let available = Arc::new(AtomicBool::new(true));
        {
            let mut controls = signals.lock().map_err(|_| failure("HOST_INTERNAL"))?;
            if controls.closed_memory_selections.contains(request)
                || controls.closed_memory_selections.len() >= 8192
            {
                grant.request_revoke();
                return Err(failure("MEMORY_SELECTION_CLOSED"));
            }
            controls.memories.insert(
                scope.into(),
                crate::actor::memory::MemorySignal {
                    token: request.into(),
                    revision: revision.into(),
                    grant: grant.clone(),
                    revoker,
                    available: available.clone(),
                },
            );
        }
        host.memories.insert(
            scope.into(),
            MemorySession {
                token: request.into(),
                revision: revision.into(),
                write,
                grant,
                available,
            },
        );
        Ok(api::MemoryAccessView {
            scope_id: snapshot.scope_id,
            revision: snapshot.revision,
            session_token: request.into(),
            write,
        })
    }
    async fn memory_suspend(
        &mut self,
        handle: &str,
        scope: &str,
        token: &str,
    ) -> Result<(), BridgeError> {
        let signals = self.signals.clone();
        let host = self.current(handle)?;
        if host.memories.get(scope).is_some_and(|s| s.token == token) {
            let session = host
                .memories
                .remove(scope)
                .ok_or_else(|| failure("MEMORY_SESSION_ACCESS_REQUIRED"))?;
            session.available.store(false, Ordering::Release);
            session.grant.request_revoke();
            session.grant.wait_drained().await;
            let mut controls = signals.lock().map_err(|_| failure("HOST_INTERNAL"))?;
            if controls
                .memories
                .get(scope)
                .is_some_and(|s| s.token == token)
            {
                controls.memories.remove(scope);
            }
        }
        Ok(())
    }
    async fn memory_change(
        &mut self,
        handle: &str,
        scope: &str,
        revision: &str,
        change: ScopeChange,
    ) -> Result<api::MemoryScopeView, BridgeError> {
        let host = self.current(handle)?;
        let revoker = host
            .journal
            .memory_scope_revoker(LOCAL_OWNER, scope, revision)
            .map_err(memory_error)?;
        let view = match change {
            ScopeChange::Enable(enabled) => {
                host.journal
                    .set_memory_scope_enabled(LOCAL_OWNER, scope, revision, enabled)
            }
            ScopeChange::Member(principal, access) => {
                host.journal
                    .set_memory_member(LOCAL_OWNER, scope, &principal, access, revision)
            }
        }
        .map_err(memory_error)?;
        let token = host.memories.get(scope).map(|s| s.token.clone());
        if let Some(token) = token {
            self.memory_suspend(handle, scope, &token).await?;
        }
        revoker.request_revoke();
        revoker.wait_drained().await;
        Ok(scope_view(
            self.current(handle)?,
            view,
            store::MemoryAccess::Write,
        ))
    }
}
enum ScopeChange {
    Enable(bool),
    Member(String, store::MemoryAccess),
}
pub(crate) async fn list_scopes(
    handle: String,
    cursor: Option<String>,
    limit: u16,
) -> Result<api::MemoryScopePage, BridgeError> {
    crate::actor::call(handle.clone(), move |host, _| {
        host.memory_scopes(&handle, cursor.as_deref(), limit)
    })
    .await
}
pub(crate) async fn create_scope(
    handle: String,
    scope: String,
    shared: bool,
) -> Result<api::MemoryScopeView, BridgeError> {
    crate::actor::call(handle.clone(), move |registry, _| {
        let host = registry.current(&handle)?;
        let scope = host
            .journal
            .create_memory_scope(LOCAL_OWNER, &scope, shared)
            .map_err(memory_error)?;
        Ok(scope_view(host, scope, store::MemoryAccess::Write))
    })
    .await
}
pub(crate) async fn authorize_scope(
    handle: String,
    scope: String,
    revision: String,
    request: String,
    write: bool,
) -> Result<api::MemoryAccessView, BridgeError> {
    crate::actor::memory::change(&handle, &scope, &revision, Some(&request))?;
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.memory_authorize(&handle, &scope, &revision, &request, write))
    })
    .await
}
pub(crate) async fn suspend_access(handle: String, request: String) -> Result<(), BridgeError> {
    let Some(id) = crate::actor::memory::release(&handle, &request)? else {
        return Ok(());
    };
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.memory_suspend(&handle, &id, &request))
    })
    .await
}
pub(crate) async fn set_scope_enabled(
    handle: String,
    scope: String,
    revision: String,
    enabled: bool,
) -> Result<api::MemoryScopeView, BridgeError> {
    crate::actor::memory::change(&handle, &scope, &revision, None)?;
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.memory_change(&handle, &scope, &revision, ScopeChange::Enable(enabled)))
    })
    .await
}
pub(crate) async fn list_members(
    handle: String,
    scope: String,
    revision: String,
    cursor: Option<String>,
    limit: u16,
) -> Result<api::MemoryMemberPage, BridgeError> {
    crate::actor::call(handle.clone(), move |registry, _| {
        let value = registry
            .current(&handle)?
            .journal
            .list_memory_members(LOCAL_OWNER, &scope, &revision, cursor.as_deref(), limit)
            .map_err(memory_error)?;
        Ok(api::MemoryMemberPage {
            scope_id: value.scope_id,
            revision: value.revision,
            members: value
                .members
                .into_iter()
                .map(|m| api::MemoryMemberView {
                    principal: m.principal,
                    access: access(m.access),
                })
                .collect(),
            next_cursor: value.next_cursor,
        })
    })
    .await
}
pub(crate) async fn set_member(
    handle: String,
    scope: String,
    revision: String,
    principal: String,
    permission: String,
) -> Result<api::MemoryScopeView, BridgeError> {
    if !orange_protocol::valid_id(&principal) || principal == LOCAL_OWNER {
        return Err(failure("INVALID_MEMORY_REQUEST"));
    }
    let access = match permission.as_str() {
        "read" => store::MemoryAccess::Read,
        "write" => store::MemoryAccess::Write,
        "revoked" => store::MemoryAccess::Revoked,
        _ => return Err(failure("INVALID_MEMORY_REQUEST")),
    };
    crate::actor::memory::change(&handle, &scope, &revision, None)?;
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.memory_change(
            &handle,
            &scope,
            &revision,
            ScopeChange::Member(principal, access),
        ))
    })
    .await
}
pub(crate) async fn list_entries(
    handle: String,
    selection: api::MemorySelection,
    cursor: Option<String>,
    limit: u16,
    disabled: bool,
) -> Result<api::MemoryPage, BridgeError> {
    let delivery = crate::actor::memory::capture(&handle, &selection)?;
    let result = crate::actor::call(handle.clone(), move |registry, rt| {
        let host = registry.current(&handle)?;
        let selected = selected(host, &selection)?;
        let page = rt
            .block_on(host.journal.list_memory_verified(
                selected.authority(),
                cursor.as_deref(),
                limit,
                disabled,
            ))
            .map_err(runs::engine_error)?;
        let value = page.view(&host.journal).map_err(runs::engine_error)?;
        Ok(api::MemoryPage {
            scope_id: value.scope_id.clone(),
            entries: value
                .entries
                .iter()
                .map(|v| api::MemorySummary {
                    entry_id: v.entry_id.clone(),
                    version: v.version.clone(),
                    title: v.title.clone(),
                    enabled: v.enabled,
                    origin: origin(v.origin),
                    content_bytes: v.content_bytes.clone(),
                })
                .collect(),
            next_cursor: value.next_cursor.clone(),
            omitted_unavailable: value.omitted_unavailable,
            scan_limited: value.scan_limited,
        })
    })
    .await?;
    delivery.check()?;
    Ok(result)
}
pub(crate) async fn read_entry(
    handle: String,
    selection: api::MemorySelection,
    id: String,
    version: Option<String>,
    start: u32,
    max: u32,
    disabled: bool,
) -> Result<api::MemoryEntry, BridgeError> {
    let delivery = crate::actor::memory::capture(&handle, &selection)?;
    let result = crate::actor::call(handle.clone(), move |registry, rt| {
        let host = registry.current(&handle)?;
        let selected = selected(host, &selection)?;
        let receipt = rt
            .block_on(host.journal.read_memory_verified(
                selected.authority(),
                MemoryReadSelection {
                    entry_id: id,
                    expected_version: version,
                    start_byte: start,
                    max_bytes: max,
                    include_disabled: disabled,
                },
            ))
            .map_err(runs::engine_error)?;
        Ok(entry(
            receipt.view(&host.journal).map_err(runs::engine_error)?,
        ))
    })
    .await?;
    delivery.check()?;
    Ok(result)
}
pub(crate) async fn prepare_edit(
    handle: String,
    selection: api::MemorySelection,
    edit: api::MemoryEdit,
) -> Result<api::MemoryReview, BridgeError> {
    let delivery = crate::actor::memory::capture(&handle, &selection)?;
    let result = crate::actor::call(handle.clone(), move |registry, rt| {
        let host = registry.current(&handle)?;
        let selected = selected(host, &selection)?;
        if !orange_protocol::valid_id(&edit.request_id) {
            return Err(failure("INVALID_MEMORY_REQUEST"));
        }
        let source = format!(
            "memory-user-{}",
            orange_protocol::request_digest(
                "desktop-human-memory.v1",
                &(&selection.scope_id, &edit.request_id)
            )
            .map_err(|_| failure("INVALID_MEMORY_REQUEST"))?
        );
        let payload = if edit.delete {
            if edit.title.is_some() || edit.content.is_some() || edit.enabled.is_some() {
                return Err(failure("INVALID_MEMORY_REQUEST"));
            }
            None
        } else {
            Some(store::MemoryPayload {
                title: edit
                    .title
                    .ok_or_else(|| failure("INVALID_MEMORY_REQUEST"))?,
                content: edit
                    .content
                    .ok_or_else(|| failure("INVALID_MEMORY_REQUEST"))?,
                enabled: edit
                    .enabled
                    .ok_or_else(|| failure("INVALID_MEMORY_REQUEST"))?,
            })
        };
        if !host
            .journal
            .memory_capability(&selected.grant, LOCAL_OWNER, READ_POLICY)
            .map_err(memory_error)?
            .write
        {
            return Err(failure("MEMORY_FORBIDDEN"));
        }
        host.journal
            .register_run(LOCAL_OWNER, &source, READ_POLICY)
            .map_err(|_| failure("MEMORY_STORAGE_UNAVAILABLE"))?;
        let request = store::MemoryWriteRequest {
            entry_id: edit.entry_id,
            expected_version: edit.expected_version,
            source_run: source,
            origin: store::MemoryOrigin::UserDeclaration,
            mutation: if edit.delete {
                store::MemoryMutation::Delete
            } else {
                store::MemoryMutation::Put
            },
            payload,
        };
        rt.block_on(host.journal.prepare_user_memory_write(
            selected.authority(),
            &edit.request_id,
            request,
        ))
        .map(review)
        .map_err(runs::engine_error)
    })
    .await?;
    delivery.check()?;
    Ok(result)
}
pub(crate) async fn review_edit(
    handle: String,
    selection: api::MemorySelection,
    draft: String,
) -> Result<api::MemoryReview, BridgeError> {
    let delivery = crate::actor::memory::capture(&handle, &selection)?;
    let result = crate::actor::call(handle.clone(), move |registry, rt| {
        let host = registry.current(&handle)?;
        let selected = selected(host, &selection)?;
        rt.block_on(
            host.journal
                .review_user_memory_write(selected.authority(), &draft),
        )
        .map(review)
        .map_err(runs::engine_error)
    })
    .await?;
    delivery.check()?;
    Ok(result)
}
pub(crate) async fn approve_edit(
    handle: String,
    selection: api::MemorySelection,
    draft: String,
    digest: String,
) -> Result<api::MemoryOutcome, BridgeError> {
    crate::actor::call(handle.clone(), move |registry, rt| {
        let host = registry.current(&handle)?;
        let selected = selected(host, &selection)?;
        rt.block_on(
            host.journal
                .approve_user_memory_write(selected.authority(), &draft, &digest),
        )
        .map(outcome)
        .map_err(runs::engine_error)
    })
    .await
}
pub(crate) async fn inspect_edit(
    handle: String,
    scope: String,
    request: String,
) -> Result<Option<api::MemoryOutcome>, BridgeError> {
    crate::actor::call(handle.clone(), move |registry, _| {
        registry
            .current(&handle)?
            .journal
            .user_memory_write_by_key(LOCAL_OWNER, &scope, &request)
            .map(|v| v.map(outcome))
            .map_err(runs::engine_error)
    })
    .await
}

impl HostRegistry {
    pub(crate) fn pending_user_drafts(
        &mut self,
        handle: &str,
        scope: &str,
        after: Option<&str>,
        limit: u16,
    ) -> Result<Vec<api::MemoryOutcome>, BridgeError> {
        self.current(handle)?
            .journal
            .pending_user_memory_drafts(LOCAL_OWNER, scope, after, limit)
            .map(|rows| rows.into_iter().map(outcome).collect())
            .map_err(runs::engine_error)
    }
    pub(crate) fn discard_user_draft(
        &mut self,
        handle: &str,
        scope: &str,
        id: &str,
        digest: &str,
    ) -> Result<api::MemoryOutcome, BridgeError> {
        self.current(handle)?
            .journal
            .discard_user_memory_draft(LOCAL_OWNER, scope, id, digest)
            .map(outcome)
            .map_err(runs::engine_error)
    }
    pub(crate) fn uncertain_task_writes(
        &mut self,
        handle: &str,
        run: &str,
        after: Option<&str>,
        limit: u16,
    ) -> Result<Vec<api::UncertainMemoryWrite>, BridgeError> {
        let journal = &self.current(handle)?.journal;
        let ids = journal
            .unresolved_memory_operations(LOCAL_OWNER, run, after, limit)
            .map_err(runs::engine_error)?;
        ids.into_iter()
            .map(|id| {
                let receipt = journal
                    .agent_memory_metadata(LOCAL_OWNER, run, &id)
                    .map_err(runs::engine_error)?
                    .ok_or_else(|| failure("RUN_RECOVERY_REQUIRED"))?;
                Ok(api::UncertainMemoryWrite {
                    operation_id: id,
                    outcome: outcome(receipt),
                })
            })
            .collect()
    }
    pub(crate) async fn reconcile_task_write(
        &mut self,
        handle: &str,
        run: &str,
        op: &str,
        digest: &str,
        applied: bool,
        resume: bool,
    ) -> Result<(), BridgeError> {
        use orange_agent_runtime::engine::MemoryRecovery;
        if resume {
            let (_, _, read, _) = self.run_context(handle, run)?;
            let host = self.current(handle)?;
            let task = host
                .task_memory
                .get(run)
                .ok_or_else(|| failure("MEMORY_SESSION_ACCESS_REQUIRED"))?;
            let authority = task.authority(&read);
            let decision = if applied {
                MemoryRecovery::ConfirmAppliedAndContinue(authority)
            } else {
                MemoryRecovery::ConfirmNotAppliedAndContinue(authority)
            };
            host.journal
                .reconcile_agent_memory(LOCAL_OWNER, run, op, digest, decision)
                .await
                .map_err(runs::engine_error)?;
        } else {
            let host = self.current(handle)?;
            let decision = if applied {
                MemoryRecovery::ConfirmAppliedAndStop
            } else {
                MemoryRecovery::ConfirmNotAppliedAndStop
            };
            host.journal
                .reconcile_agent_memory(LOCAL_OWNER, run, op, digest, decision)
                .await
                .map_err(runs::engine_error)?;
            if let Some(task) = host.task_memory.remove(run) {
                task.revoke();
            }
        }
        Ok(())
    }
}

fn removal_review(receipt: store::OwnerRemovalReview) -> api::RemovalReview {
    let t = receipt.target;
    api::RemovalReview {
        target: api::RemovalTarget {
            scope_id: t.scope_id,
            scope_revision: t.scope_revision,
            entry_id: t.entry_id,
            entry_version: t.entry_version,
        },
        request_id: receipt.request_id,
        expires_at: receipt.expires_at.to_string(),
        digest: receipt.approval_digest,
        applied: receipt.applied,
    }
}
impl HostRegistry {
    pub(crate) fn owner_inventory(
        &mut self,
        h: &str,
        scope: &str,
        revision: &str,
        after: Option<&str>,
        limit: u16,
    ) -> Result<Vec<api::OwnerEntry>, BridgeError> {
        self.current(h)?
            .journal
            .owner_memory_inventory(LOCAL_OWNER, scope, revision, after, limit)
            .map(|rows| {
                rows.into_iter()
                    .map(|e| api::OwnerEntry {
                        entry_id: e.entry_id,
                        version: e.version,
                        enabled: e.enabled,
                    })
                    .collect()
            })
            .map_err(memory_error)
    }
    pub(crate) fn prepare_removal(
        &mut self,
        h: &str,
        key: &str,
        target: api::RemovalTarget,
    ) -> Result<api::RemovalReview, BridgeError> {
        let t = store::OwnerRemovalTarget {
            scope_id: target.scope_id,
            scope_revision: target.scope_revision,
            entry_id: target.entry_id,
            entry_version: target.entry_version,
        };
        self.current(h)?
            .journal
            .prepare_owner_removal(LOCAL_OWNER, key, t)
            .map(removal_review)
            .map_err(memory_error)
    }
    pub(crate) fn inspect_removal(
        &mut self,
        h: &str,
        scope: &str,
        key: &str,
    ) -> Result<Option<api::RemovalReview>, BridgeError> {
        self.current(h)?
            .journal
            .inspect_owner_removal(LOCAL_OWNER, scope, key)
            .map(|r| r.map(removal_review))
            .map_err(memory_error)
    }
    pub(crate) async fn approve_removal(
        &mut self,
        h: &str,
        scope: &str,
        key: &str,
        digest: &str,
    ) -> Result<api::RemovalReview, BridgeError> {
        let host = self.current(h)?;
        let receipt = host
            .journal
            .approve_owner_removal(LOCAL_OWNER, scope, key, digest)
            .await
            .map_err(memory_error)?;
        let revoked = host
            .memories
            .get(scope)
            .filter(|s| s.grant.is_revoked())
            .map(|s| s.token.clone());
        if let Some(token) = revoked {
            self.memory_suspend(h, scope, &token).await?;
        }
        Ok(removal_review(receipt))
    }
}
