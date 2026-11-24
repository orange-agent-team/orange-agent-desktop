use super::host::BridgeError;

/// Transient binding to one current OS workspace selection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KnowledgeSelection {
    pub workspace_id: String,
    pub session_token: String,
    pub collection_id: String,
}
#[derive(Debug, Clone)]
pub struct KnowledgeHit {
    pub hit_id: String,
    pub path: String,
    pub source_sha256: String,
    pub start_byte: String,
    pub end_byte: String,
}
#[derive(Debug, Clone)]
pub struct KnowledgePage {
    pub hits: Vec<KnowledgeHit>,
    pub truncated: bool,
    pub unavailable_sources: u32,
}
#[derive(Debug, Clone)]
pub struct KnowledgePassage {
    pub citation: KnowledgeHit,
    pub start_byte: String,
    pub end_byte: String,
    pub text: String,
}
pub async fn open_knowledge_collection(
    handle: String,
    selection: KnowledgeSelection,
    relative_files: Vec<String>,
) -> Result<(), BridgeError> {
    crate::host::knowledge::open(handle, selection, relative_files, None).await
}
pub async fn search_selected_knowledge(
    handle: String,
    selection: KnowledgeSelection,
    query: String,
    path: Option<String>,
    limit: u32,
) -> Result<KnowledgePage, BridgeError> {
    crate::host::knowledge::search(handle, selection, query, path, limit).await
}
pub async fn read_knowledge_citation(
    handle: String,
    selection: KnowledgeSelection,
    hit_id: String,
    expected_sha256: String,
    start_byte: Option<u32>,
    end_byte: Option<u32>,
) -> Result<KnowledgePassage, BridgeError> {
    crate::host::knowledge::read(
        handle,
        selection,
        hit_id,
        expected_sha256,
        start_byte,
        end_byte,
    )
    .await
}
pub async fn close_knowledge_collection(
    handle: String,
    selection: KnowledgeSelection,
) -> Result<(), BridgeError> {
    crate::host::knowledge::close(handle, selection).await
}

/// Save or reopen the exact file selection under a stable private name.
pub async fn open_saved_knowledge_collection(
    handle: String,
    selection: KnowledgeSelection,
    relative_files: Vec<String>,
    name: String,
) -> Result<(), BridgeError> {
    crate::host::knowledge::open(handle, selection, relative_files, Some(name)).await
}
pub async fn list_saved_knowledge_collections(
    handle: String,
    workspace_id: String,
    session_token: String,
) -> Result<Vec<String>, BridgeError> {
    crate::host::knowledge::saved_names(handle, workspace_id, session_token).await
}
pub async fn retire_saved_knowledge_collection(
    handle: String,
    workspace_id: String,
    session_token: String,
    name: String,
) -> Result<(), BridgeError> {
    crate::host::knowledge::retire(handle, workspace_id, session_token, name).await
}

/// Retry only collection retirements already recorded by durable user consent.
pub async fn reconcile_saved_knowledge_cleanup(handle: String) -> Result<(), BridgeError> {
    crate::host::knowledge::reconcile(handle).await
}

pub async fn saved_knowledge_cleanup_pending(handle: String) -> Result<bool, BridgeError> {
    crate::host::knowledge::cleanup_pending(handle).await
}
