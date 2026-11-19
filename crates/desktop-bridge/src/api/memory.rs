//! Human management commands. Actor/policy/origin always come from native Host.
use super::host::BridgeError;
#[derive(Debug, Clone)]
pub struct MemoryScopeView {
    pub scope_id: String,
    pub owner: String,
    pub shared: bool,
    pub revision: String,
    pub enabled: bool,
    pub access: String,
    pub can_administer: bool,
    pub session_token: Option<String>,
    pub session_write: bool,
}
#[derive(Debug, Clone)]
pub struct MemoryAccessView {
    pub scope_id: String,
    pub revision: String,
    pub session_token: String,
    pub write: bool,
}
#[derive(Debug, Clone)]
pub struct MemoryScopePage {
    pub scopes: Vec<MemoryScopeView>,
    pub next_cursor: Option<String>,
}
#[derive(Debug, Clone)]
pub struct MemoryMemberView {
    pub principal: String,
    pub access: String,
}
#[derive(Debug, Clone)]
pub struct MemoryMemberPage {
    pub scope_id: String,
    pub revision: String,
    pub members: Vec<MemoryMemberView>,
    pub next_cursor: Option<String>,
}
#[derive(Debug, Clone)]
pub struct MemorySources {
    pub workspace_ids: Vec<String>,
    pub memory_tokens: Vec<String>,
}
#[derive(Debug, Clone)]
pub struct MemorySelection {
    pub scope_id: String,
    pub session_token: String,
    pub sources: MemorySources,
}
#[derive(Debug, Clone)]
pub struct MemorySummary {
    pub entry_id: String,
    pub version: String,
    pub title: String,
    pub enabled: bool,
    pub origin: String,
    pub content_bytes: String,
}
#[derive(Debug, Clone)]
pub struct MemoryPage {
    pub scope_id: String,
    pub entries: Vec<MemorySummary>,
    pub next_cursor: Option<String>,
    pub omitted_unavailable: bool,
    pub scan_limited: bool,
}
#[derive(Debug, Clone)]
pub struct MemoryEntry {
    pub scope_id: String,
    pub entry_id: String,
    pub version: String,
    pub title: String,
    pub content: String,
    pub enabled: bool,
    pub origin: String,
    pub source_actor: String,
    pub source_run: String,
    pub total_bytes: String,
    pub start_byte: String,
    pub next_byte: Option<String>,
}
#[derive(Debug, Clone)]
pub struct MemoryEdit {
    pub request_id: String,
    pub entry_id: String,
    pub expected_version: Option<String>,
    pub delete: bool,
    pub title: Option<String>,
    pub content: Option<String>,
    pub enabled: Option<bool>,
}
#[derive(Debug, Clone)]
pub struct MemoryReview {
    pub draft_id: String,
    pub scope_id: String,
    pub entry_id: String,
    pub expected_version: Option<String>,
    pub approval_digest: String,
    pub source_run: String,
    pub title: Option<String>,
    pub content: Option<String>,
    pub enabled: Option<bool>,
    pub delete: bool,
    pub expires_at: String,
    pub prior: Option<MemoryEntry>,
}
#[derive(Debug, Clone)]
pub struct MemoryOutcome {
    pub draft_id: String,
    pub scope_id: String,
    pub entry_id: String,
    pub digest: String,
    pub state: String,
    pub result_version: Option<String>,
}

pub async fn list_scopes(
    handle: String,
    cursor: Option<String>,
    limit: u16,
) -> Result<MemoryScopePage, BridgeError> {
    crate::host::memory::list_scopes(handle, cursor, limit).await
}
pub async fn create_scope(
    handle: String,
    scope_id: String,
    shared: bool,
) -> Result<MemoryScopeView, BridgeError> {
    crate::host::memory::create_scope(handle, scope_id, shared).await
}
pub async fn authorize_scope(
    handle: String,
    scope_id: String,
    revision: String,
    request_id: String,
    write: bool,
) -> Result<MemoryAccessView, BridgeError> {
    crate::host::memory::authorize_scope(handle, scope_id, revision, request_id, write).await
}
pub async fn suspend_access(handle: String, request_id: String) -> Result<(), BridgeError> {
    crate::host::memory::suspend_access(handle, request_id).await
}
pub async fn set_scope_enabled(
    handle: String,
    scope_id: String,
    revision: String,
    enabled: bool,
) -> Result<MemoryScopeView, BridgeError> {
    crate::host::memory::set_scope_enabled(handle, scope_id, revision, enabled).await
}
pub async fn list_members(
    handle: String,
    scope_id: String,
    revision: String,
    cursor: Option<String>,
    limit: u16,
) -> Result<MemoryMemberPage, BridgeError> {
    crate::host::memory::list_members(handle, scope_id, revision, cursor, limit).await
}
pub async fn set_member(
    handle: String,
    scope_id: String,
    revision: String,
    principal: String,
    access: String,
) -> Result<MemoryScopeView, BridgeError> {
    crate::host::memory::set_member(handle, scope_id, revision, principal, access).await
}
pub async fn list_entries(
    handle: String,
    selection: MemorySelection,
    cursor: Option<String>,
    limit: u16,
    include_disabled: bool,
) -> Result<MemoryPage, BridgeError> {
    crate::host::memory::list_entries(handle, selection, cursor, limit, include_disabled).await
}
pub async fn read_entry(
    handle: String,
    selection: MemorySelection,
    entry_id: String,
    expected_version: Option<String>,
    start_byte: u32,
    max_bytes: u32,
    include_disabled: bool,
) -> Result<MemoryEntry, BridgeError> {
    crate::host::memory::read_entry(
        handle,
        selection,
        entry_id,
        expected_version,
        start_byte,
        max_bytes,
        include_disabled,
    )
    .await
}
pub async fn prepare_edit(
    handle: String,
    selection: MemorySelection,
    edit: MemoryEdit,
) -> Result<MemoryReview, BridgeError> {
    crate::host::memory::prepare_edit(handle, selection, edit).await
}
pub async fn review_edit(
    handle: String,
    selection: MemorySelection,
    draft_id: String,
) -> Result<MemoryReview, BridgeError> {
    crate::host::memory::review_edit(handle, selection, draft_id).await
}
pub async fn approve_edit(
    handle: String,
    selection: MemorySelection,
    draft_id: String,
    approval_digest: String,
) -> Result<MemoryOutcome, BridgeError> {
    crate::host::memory::approve_edit(handle, selection, draft_id, approval_digest).await
}
pub async fn inspect_edit(
    handle: String,
    scope_id: String,
    request_id: String,
) -> Result<Option<MemoryOutcome>, BridgeError> {
    crate::host::memory::inspect_edit(handle, scope_id, request_id).await
}

/// An explicit task permission bounded by the current selection.
#[derive(Debug, Clone)]
pub struct TaskMemoryScope {
    pub scope_id: String,
    pub session_token: String,
    pub write: bool,
}

#[derive(Debug, Clone)]
pub struct TaskMemorySelection {
    pub creation: Option<super::host::RunPermissionSelection>,
    pub editing: Option<super::host::RunPermissionSelection>,
    pub scopes: Vec<TaskMemoryScope>,
    pub sources: MemorySources,
}

pub async fn start_memory_run(
    handle: String,
    workspace: String,
    request_id: String,
    prompt: String,
    selection: TaskMemorySelection,
    interactive: bool,
) -> Result<super::host::AgentRunView, BridgeError> {
    crate::actor::call(handle.clone(), move |registry, rt| {
        rt.block_on(registry.start_memory_run(
            &handle,
            &workspace,
            &request_id,
            &prompt,
            &selection,
            interactive,
        ))
    })
    .await
}

pub async fn restore_run_memory(
    handle: String,
    run_id: String,
    selection: TaskMemorySelection,
) -> Result<super::host::AgentRunView, BridgeError> {
    crate::actor::call(handle.clone(), move |registry, rt| {
        rt.block_on(registry.restore_run_memory(&handle, &run_id, &selection))
    })
    .await
}

#[derive(Debug, Clone)]
pub struct TaskMemoryReview {
    pub operation_id: String,
    pub argument_digest: String,
    pub approval_digest: String,
    pub review_json: String,
    pub sources_json: String,
}

pub async fn preview_run_memory(
    handle: String,
    run_id: String,
    operation_id: String,
) -> Result<TaskMemoryReview, BridgeError> {
    crate::actor::call(handle.clone(), move |registry, rt| {
        rt.block_on(registry.preview_run_memory(&handle, &run_id, &operation_id))
    })
    .await
}

pub async fn approve_run_memory(
    handle: String,
    run_id: String,
    operation_id: String,
    digest: String,
) -> Result<super::host::AgentRunView, BridgeError> {
    crate::actor::call(handle.clone(), move |registry, rt| {
        rt.block_on(registry.approve_run_memory(&handle, &run_id, &operation_id, &digest))
    })
    .await
}

#[derive(Debug, Clone)]
pub struct TaskMemoryRequirement {
    pub scope_id: String,
    pub revision: String,
    pub write: bool,
}

pub async fn run_memory_requirements(
    handle: String,
    run_id: String,
) -> Result<Vec<TaskMemoryRequirement>, BridgeError> {
    crate::actor::call(handle.clone(), move |registry, _| {
        registry.run_memory_requirements(&handle, &run_id)
    })
    .await
}
