//! Only reviewed DTOs and commands are exposed to Dart.
use std::fmt;

#[derive(Debug, Clone)]
pub struct BridgeError {
    pub code: String,
    pub correlation_id: String,
}
impl fmt::Display for BridgeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} ({})", self.code, self.correlation_id)
    }
}
impl std::error::Error for BridgeError {}
#[derive(Debug, Clone)]
pub struct HostView {
    pub handle: String,
    pub contract_version: String,
    pub runtime_version: String,
    pub runtime_source_commit: String,
    pub available_read_tools: Vec<String>,
    pub available_edit_tools: Vec<String>,
}
#[derive(Debug, Clone)]
pub struct WorkspaceView {
    pub workspace_id: String,
    pub display_path: String,
    pub permission_version: String,
    pub permission_active: bool,
    pub session_access: bool,
    /// Opaque ownership of the current OS access scope, not durable consent.
    pub session_token: Option<String>,
}
#[derive(Debug, Clone)]
pub struct RunSummary {
    pub run_id: String,
    pub workspace_id: Option<String>,
    pub phase: String,
    pub steps: u32,
    pub invocations: u32,
    pub active: bool,
}
#[derive(Debug, Clone)]
pub struct RunPage {
    pub runs: Vec<RunSummary>,
    pub next_cursor: Option<String>,
}
#[derive(Debug, Clone)]
pub struct ModelConnectionView {
    pub model_id: String,
    pub display_name: String,
    pub context_tokens: u32,
    pub verification: String,
}
#[derive(Debug, Clone)]
pub struct ModelServiceView {
    pub phase: String,
    pub model_name: String,
    pub model_bytes: String,
    pub installed: bool,
    pub instance_id: Option<String>,
    pub failure: Option<String>,
}
/// Paths and OS version come from the trusted native application environment.
pub async fn configure_model_service(
    handle: String,
    contents_directory: String,
    ipc_directory: String,
    os_version: String,
) -> Result<ModelServiceView, BridgeError> {
    crate::host::configure_model_service(handle, contents_directory, ipc_directory, os_version)
        .await
}
pub async fn inspect_model_service(handle: String) -> Result<ModelServiceView, BridgeError> {
    crate::host::inspect_model_service(handle).await
}
pub async fn current_model_connection(handle: String) -> Result<ModelConnectionView, BridgeError> {
    crate::host::current_model_connection(handle).await
}
pub async fn cancel_model_start(
    handle: String,
    request_id: String,
) -> Result<ModelServiceView, BridgeError> {
    crate::host::cancel_model_start(handle, request_id).await
}
/// Operation ID is known before file selection is released, including lost replies.
pub async fn import_model(
    handle: String,
    operation_id: String,
    selected_file: String,
) -> Result<ModelServiceView, BridgeError> {
    crate::host::import_model(handle, operation_id, selected_file).await
}
/// Stops further file reads and drains the owned import before native scope release.
pub async fn close_model_import(handle: String, operation_id: String) -> Result<(), BridgeError> {
    crate::host::close_model_import(handle, operation_id).await
}
pub async fn start_model_service(
    handle: String,
    request_id: String,
) -> Result<ModelServiceView, BridgeError> {
    crate::host::start_model_service(handle, request_id).await
}
pub async fn stop_model_service(
    handle: String,
    instance_id: String,
) -> Result<ModelServiceView, BridgeError> {
    crate::host::stop_model_service(handle, instance_id).await
}
#[derive(Debug, Clone)]
pub struct ToolApprovalView {
    pub operation_id: String,
    pub tool_name: String,
    pub arguments_json: String,
    pub argument_digest: String,
}
#[derive(Debug, Clone)]
pub struct UserQuestionView {
    pub prompt: String,
    pub choices: Option<Vec<String>>,
}
#[derive(Debug, Clone)]
pub struct UserQuestionGroupView {
    pub question_id: String,
    pub argument_digest: String,
    pub questions: Vec<UserQuestionView>,
}
#[derive(Debug, Clone)]
pub struct AgentRunView {
    /// Immutable Run capability; never inferred from a pending tool name.
    pub creation_consent_id: Option<String>,
    pub editing_consent_id: Option<String>,
    pub run_id: String,
    pub workspace_id: String,
    pub model_id: String,
    pub phase: String,
    pub revision: String,
    pub steps: u32,
    pub invocations: u32,
    pub pending: Vec<ToolApprovalView>,
    pub user_question: Option<UserQuestionGroupView>,
    pub final_text: Option<String>,
    pub failure: Option<String>,
}
/// Trusted application model manager supplies a service directory inside private
/// Host storage. The model cannot configure its own endpoint.
pub async fn connect_local_model(
    handle: String,
    selected_directory: String,
) -> Result<ModelConnectionView, BridgeError> {
    crate::host::connect_local_model(handle, selected_directory).await
}
pub async fn disconnect_local_model(handle: String) -> Result<(), BridgeError> {
    crate::host::disconnect_local_model(handle).await
}
pub async fn start_run(
    handle: String,
    workspace_id: String,
    request_id: String,
    prompt: String,
) -> Result<AgentRunView, BridgeError> {
    crate::host::start_run(handle, workspace_id, request_id, prompt).await
}
/// Explicit question-capable UI entry point; legacy start_run remains noninteractive.
pub async fn start_interactive_run(
    handle: String,
    workspace_id: String,
    request_id: String,
    prompt: String,
) -> Result<AgentRunView, BridgeError> {
    crate::host::start_interactive_run(handle, workspace_id, request_id, prompt).await
}
/// A reply supplies context only. It never approves or executes a filesystem tool.
pub async fn answer_user_question(
    handle: String,
    run_id: String,
    question_id: String,
    expected_digest: String,
    answers: Vec<String>,
) -> Result<AgentRunView, BridgeError> {
    crate::host::answer_user_question(handle, run_id, question_id, expected_digest, answers).await
}
pub async fn inspect_run(handle: String, run_id: String) -> Result<AgentRunView, BridgeError> {
    crate::host::inspect_run(handle, run_id).await
}
pub async fn approve_tool(
    handle: String,
    run_id: String,
    operation_id: String,
    expected_digest: String,
) -> Result<AgentRunView, BridgeError> {
    crate::host::approve_tool(handle, run_id, operation_id, expected_digest).await
}
pub async fn advance_run(
    handle: String,
    run_id: String,
    expected_revision: String,
) -> Result<AgentRunView, BridgeError> {
    crate::host::advance_run(handle, run_id, expected_revision).await
}
pub async fn cancel_run(handle: String, run_id: String) -> Result<AgentRunView, BridgeError> {
    crate::host::cancel_run(handle, run_id).await
}
/// The trusted UI supplies an OS application-data directory, never model input.
pub fn initialize_host(application_data_directory: String) -> Result<HostView, BridgeError> {
    crate::host::initialize_host(application_data_directory)
}
pub fn inspect_host(handle: String) -> Result<HostView, BridgeError> {
    crate::host::inspect_host(handle)
}
/// Validation only; does not transfer money or reserve a budget.
pub fn validate_amount(handle: String, value: String) -> Result<String, BridgeError> {
    crate::host::validate_amount(handle, value)
}
/// Closing a local handle does not assert any GPU or Job resource release.
pub fn close_host(handle: String) -> Result<(), BridgeError> {
    crate::host::close_host(handle)
}
/// Called only after the trusted platform UI obtains explicit directory consent.
pub async fn authorize_workspace(
    handle: String,
    request_id: String,
    selected_directory: String,
) -> Result<WorkspaceView, BridgeError> {
    crate::host::authorize_workspace(handle, request_id, selected_directory).await
}
pub async fn list_workspaces(
    handle: String,
    include_revoked: bool,
) -> Result<Vec<WorkspaceView>, BridgeError> {
    crate::host::list_workspaces(handle, include_revoked).await
}
/// Restore only after the platform has revalidated its OS permission/bookmark.
pub async fn restore_workspace_access(
    handle: String,
    workspace_id: String,
) -> Result<WorkspaceView, BridgeError> {
    crate::host::restore_workspace_access(handle, workspace_id).await
}
/// Stop process access before releasing the corresponding native OS scope.
/// Durable user consent remains; a later OS selection creates a fresh token.
pub async fn suspend_workspace_access(
    handle: String,
    workspace_id: String,
    session_token: String,
) -> Result<WorkspaceView, BridgeError> {
    crate::host::suspend_workspace_access(handle, workspace_id, session_token).await
}
/// Revoke process access by the trusted native selection/request ID, including
/// when its authorization reply was lost or the request is still queued.
pub async fn suspend_workspace_selection(
    handle: String,
    request_id: String,
) -> Result<(), BridgeError> {
    crate::host::suspend_workspace_selection(handle, request_id).await
}
pub async fn revoke_workspace(
    handle: String,
    workspace_id: String,
    expected_version: String,
) -> Result<WorkspaceView, BridgeError> {
    crate::host::revoke_workspace(handle, workspace_id, expected_version).await
}
pub async fn list_runs(
    handle: String,
    workspace_id: Option<String>,
    before: Option<String>,
    limit: u16,
) -> Result<RunPage, BridgeError> {
    crate::host::list_runs(handle, workspace_id, before, limit).await
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// Independent create-only consent and its currently held OS selection.
#[derive(Debug, Clone)]
pub struct CreationAccessView {
    pub consent_id: String,
    pub workspace_id: String,
    pub display_path: String,
    pub permission_version: String,
    pub permission_active: bool,
    pub session_token: Option<String>,
}
/// Trusted UI calls only after a separate native write directory selection.
pub async fn authorize_creation_access(
    handle: String,
    workspace_id: String,
    request_id: String,
    selected_directory: String,
) -> Result<CreationAccessView, BridgeError> {
    crate::host::authorize_creation_access(handle, workspace_id, request_id, selected_directory)
        .await
}
pub async fn list_creation_access(
    handle: String,
    workspace_id: String,
) -> Result<Vec<CreationAccessView>, BridgeError> {
    crate::host::list_creation_access(handle, workspace_id).await
}
/// Known before authorization dispatch; lost replies can still close OS access.
pub async fn suspend_creation_selection(
    handle: String,
    request_id: String,
) -> Result<(), BridgeError> {
    crate::host::suspend_creation_selection(handle, request_id).await
}
pub async fn revoke_creation_access(
    handle: String,
    consent_id: String,
    expected_version: String,
) -> Result<(), BridgeError> {
    crate::host::revoke_creation_access(handle, consent_id, expected_version).await
}

/// Explicit immutable Run opt-in; old start_run/start_interactive_run stay readonly.
pub async fn start_creation_run(
    handle: String,
    workspace_id: String,
    request_id: String,
    prompt: String,
    consent_id: String,
    permission_version: String,
    user_questions: bool,
) -> Result<AgentRunView, BridgeError> {
    crate::host::start_creation_run(
        handle,
        workspace_id,
        request_id,
        prompt,
        consent_id,
        permission_version,
        user_questions,
    )
    .await
}
/// Approval of the exact create proposal, separate from workspace consent.
pub async fn approve_creation_tool(
    handle: String,
    run_id: String,
    operation_id: String,
    expected_digest: String,
) -> Result<AgentRunView, BridgeError> {
    crate::host::approve_creation_tool(handle, run_id, operation_id, expected_digest).await
}

#[derive(Debug, Clone)]
pub struct EditingAccessView {
    pub consent_id: String,
    pub workspace_id: String,
    pub display_path: String,
    pub permission_version: String,
    pub permission_active: bool,
    pub session_token: Option<String>,
}
#[derive(Debug, Clone)]
pub struct RunPermissionSelection {
    pub consent_id: String,
    pub permission_version: String,
}
#[derive(Debug, Clone)]
pub struct EditPreviewView {
    pub run_id: String,
    pub operation_id: String,
    pub argument_digest: String,
    pub preview_digest: String,
    pub path: String,
    pub diff: String,
    pub original_sha256: String,
    pub result_sha256: String,
    pub original_bytes: String,
    pub result_bytes: String,
    pub added_lines: u32,
    pub removed_lines: u32,
}
/// Independent OS directory scope and explicit edit consent; never a read upgrade.
pub async fn authorize_editing_access(
    handle: String,
    workspace_id: String,
    request_id: String,
    selected_directory: String,
) -> Result<EditingAccessView, BridgeError> {
    #[cfg(target_vendor = "apple")]
    {
        crate::host::authorize_editing_access(handle, workspace_id, request_id, selected_directory)
            .await
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        let _ = (handle, workspace_id, request_id, selected_directory);
        Err(crate::host::failure("EDITING_UNAVAILABLE_ON_TARGET"))
    }
}
pub async fn list_editing_access(
    handle: String,
    workspace_id: String,
) -> Result<Vec<EditingAccessView>, BridgeError> {
    #[cfg(target_vendor = "apple")]
    {
        crate::host::list_editing_access(handle, workspace_id).await
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        let _ = (handle, workspace_id);
        Err(crate::host::failure("EDITING_UNAVAILABLE_ON_TARGET"))
    }
}
pub async fn suspend_editing_selection(
    handle: String,
    request_id: String,
) -> Result<(), BridgeError> {
    #[cfg(target_vendor = "apple")]
    {
        crate::host::suspend_editing_selection(handle, request_id).await
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        let _ = (handle, request_id);
        Err(crate::host::failure("EDITING_UNAVAILABLE_ON_TARGET"))
    }
}
pub async fn revoke_editing_access(
    handle: String,
    consent_id: String,
    expected_version: String,
) -> Result<(), BridgeError> {
    #[cfg(target_vendor = "apple")]
    {
        crate::host::revoke_editing_access(handle, consent_id, expected_version).await
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        let _ = (handle, consent_id, expected_version);
        Err(crate::host::failure("EDITING_UNAVAILABLE_ON_TARGET"))
    }
}
pub async fn start_editing_run(
    handle: String,
    workspace_id: String,
    request_id: String,
    prompt: String,
    editing: RunPermissionSelection,
    creation: Option<RunPermissionSelection>,
    user_questions: bool,
) -> Result<AgentRunView, BridgeError> {
    #[cfg(target_vendor = "apple")]
    {
        crate::host::start_editing_run(
            handle,
            workspace_id,
            request_id,
            prompt,
            editing,
            creation,
            user_questions,
        )
        .await
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        let _ = (
            handle,
            workspace_id,
            request_id,
            prompt,
            editing,
            creation,
            user_questions,
        );
        Err(crate::host::failure("EDITING_UNAVAILABLE_ON_TARGET"))
    }
}
/// The trusted Runtime, not Dart/model arguments, builds this actual source diff.
pub async fn preview_editing_tool(
    handle: String,
    run_id: String,
    operation_id: String,
) -> Result<EditPreviewView, BridgeError> {
    #[cfg(target_vendor = "apple")]
    {
        crate::host::preview_editing_tool(handle, run_id, operation_id).await
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        let _ = (handle, run_id, operation_id);
        Err(crate::host::failure("EDITING_UNAVAILABLE_ON_TARGET"))
    }
}
pub async fn approve_editing_tool(
    handle: String,
    run_id: String,
    operation_id: String,
    preview_digest: String,
) -> Result<AgentRunView, BridgeError> {
    #[cfg(target_vendor = "apple")]
    {
        crate::host::approve_editing_tool(handle, run_id, operation_id, preview_digest).await
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        let _ = (handle, run_id, operation_id, preview_digest);
        Err(crate::host::failure("EDITING_UNAVAILABLE_ON_TARGET"))
    }
}

/// Metadata-only, bounded recovery discovery. Does not restore OS access,
/// inspect file contents, approve a recovery or replay the original operation.
pub async fn list_unresolved_edits(
    handle: String,
    run_id: String,
    before: Option<String>,
    limit: u16,
) -> Result<Vec<String>, BridgeError> {
    #[cfg(target_vendor = "apple")]
    {
        crate::host::list_unresolved_edits(handle, run_id, before, limit).await
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        let _ = (handle, run_id, before, limit);
        Err(crate::host::failure("EDITING_UNAVAILABLE_ON_TARGET"))
    }
}

/// Owned operation IDs eligible for retained-file management, including
/// archived records. Does not authorize reading, archival, export or deletion.
pub async fn list_retained_edits(
    handle: String,
    run_id: String,
    before: Option<String>,
    limit: u16,
) -> Result<Vec<String>, BridgeError> {
    #[cfg(target_vendor = "apple")]
    {
        crate::host::list_retained_edits(handle, run_id, before, limit).await
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        let _ = (handle, run_id, before, limit);
        Err(crate::host::failure("EDITING_UNAVAILABLE_ON_TARGET"))
    }
}

/// Query the committed archival review ID after a lost reply. None is not
/// approval to retry, and this query never opens files or restores a Run.
pub async fn inspect_retention_outcome(
    handle: String,
    run_id: String,
    operation_id: String,
) -> Result<Option<String>, BridgeError> {
    #[cfg(target_vendor = "apple")]
    {
        crate::host::inspect_retention_outcome(handle, run_id, operation_id).await
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        let _ = (handle, run_id, operation_id);
        Err(crate::host::failure("EDITING_UNAVAILABLE_ON_TARGET"))
    }
}

#[derive(Debug, Clone)]
pub struct RecoveryInspectionAccessView {
    pub session_token: String,
    pub run_id: String,
    pub operation_id: String,
    pub workspace_id: String,
    pub display_directory: String,
}
#[derive(Debug, Clone)]
pub struct RecoveryFileStatusView {
    pub kind: String,
    pub refusal: Option<String>,
    pub bytes: Option<String>,
    pub sha256: Option<String>,
    pub security_sha256: Option<String>,
    pub reviewed_original_inode: bool,
    pub matches_original_content: bool,
    pub matches_result_content: bool,
}
#[derive(Debug, Clone)]
pub struct RecoveryInspectionView {
    pub run_id: String,
    pub operation_id: String,
    pub path: String,
    pub execution_state: String,
    pub last_durable_stage: Option<String>,
    pub target: RecoveryFileStatusView,
    pub staged: RecoveryFileStatusView,
    pub original: RecoveryFileStatusView,
}
#[derive(Debug, Clone)]
pub struct RecoveryOutcomeView {
    pub run_id: String,
    pub operation_id: String,
    pub original_execution_state: String,
    pub recovery_id: Option<String>,
    pub choice: Option<String>,
}
#[derive(Debug, Clone)]
pub struct RecoveryWriteAccessView {
    pub session_token: String,
    pub read_session_token: String,
    pub run_id: String,
    pub operation_id: String,
    pub workspace_id: String,
    pub display_directory: String,
}
#[derive(Debug, Clone)]
pub struct RecoveryDecisionView {
    pub read_session_token: String,
    pub write_session_token: String,
    pub recovery_id: String,
    pub digest: String,
    pub choice: String,
    pub inspection: RecoveryInspectionView,
}
pub async fn prepare_recovery_decision(
    handle: String,
    read_session_token: String,
    write_session_token: String,
    request_id: String,
    choice: String,
) -> Result<RecoveryDecisionView, BridgeError> {
    #[cfg(target_vendor = "apple")]
    {
        crate::host::prepare_recovery_decision(
            handle,
            read_session_token,
            write_session_token,
            request_id,
            choice,
        )
        .await
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        let _ = (
            handle,
            read_session_token,
            write_session_token,
            request_id,
            choice,
        );
        Err(crate::host::failure("EDITING_UNAVAILABLE_ON_TARGET"))
    }
}
pub async fn approve_recovery_decision(
    handle: String,
    read_session_token: String,
    write_session_token: String,
    recovery_id: String,
    expected_digest: String,
) -> Result<RecoveryOutcomeView, BridgeError> {
    #[cfg(target_vendor = "apple")]
    {
        crate::host::approve_recovery_decision(
            handle,
            read_session_token,
            write_session_token,
            recovery_id,
            expected_digest,
        )
        .await
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        let _ = (
            handle,
            read_session_token,
            write_session_token,
            recovery_id,
            expected_digest,
        );
        Err(crate::host::failure("EDITING_UNAVAILABLE_ON_TARGET"))
    }
}
/// Trusted UI only after a separate native recovery-write selection.
pub async fn authorize_recovery_write_access(
    handle: String,
    read_session_token: String,
    request_id: String,
    selected_directory: String,
) -> Result<RecoveryWriteAccessView, BridgeError> {
    #[cfg(target_vendor = "apple")]
    {
        crate::host::authorize_recovery_write_access(
            handle,
            read_session_token,
            request_id,
            selected_directory,
        )
        .await
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        let _ = (handle, read_session_token, request_id, selected_directory);
        Err(crate::host::failure("EDITING_UNAVAILABLE_ON_TARGET"))
    }
}
pub async fn suspend_recovery_write_selection(
    handle: String,
    request_id: String,
) -> Result<(), BridgeError> {
    #[cfg(target_vendor = "apple")]
    {
        crate::host::suspend_recovery_write_selection(handle, request_id).await
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        let _ = (handle, request_id);
        Err(crate::host::failure("EDITING_UNAVAILABLE_ON_TARGET"))
    }
}
/// Metadata-only outcome reconciliation; no files or permission restoration.
pub async fn inspect_recovery_outcome(
    handle: String,
    run_id: String,
    operation_id: String,
) -> Result<RecoveryOutcomeView, BridgeError> {
    #[cfg(target_vendor = "apple")]
    {
        crate::host::inspect_recovery_outcome(handle, run_id, operation_id).await
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        let _ = (handle, run_id, operation_id);
        Err(crate::host::failure("EDITING_UNAVAILABLE_ON_TARGET"))
    }
}
/// Trusted UI only after a separate native recovery-read directory selection.
pub async fn authorize_recovery_inspection(
    handle: String,
    run_id: String,
    operation_id: String,
    request_id: String,
    workspace_version: String,
    selected_directory: String,
) -> Result<RecoveryInspectionAccessView, BridgeError> {
    #[cfg(target_vendor = "apple")]
    {
        crate::host::authorize_recovery_inspection(
            handle,
            run_id,
            operation_id,
            request_id,
            workspace_version,
            selected_directory,
        )
        .await
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        let _ = (
            handle,
            run_id,
            operation_id,
            request_id,
            workspace_version,
            selected_directory,
        );
        Err(crate::host::failure("EDITING_UNAVAILABLE_ON_TARGET"))
    }
}
pub async fn inspect_recovery(
    handle: String,
    session_token: String,
) -> Result<RecoveryInspectionView, BridgeError> {
    #[cfg(target_vendor = "apple")]
    {
        crate::host::inspect_recovery(handle, session_token).await
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        let _ = (handle, session_token);
        Err(crate::host::failure("EDITING_UNAVAILABLE_ON_TARGET"))
    }
}
pub async fn suspend_recovery_inspection(
    handle: String,
    request_id: String,
) -> Result<(), BridgeError> {
    #[cfg(target_vendor = "apple")]
    {
        crate::host::suspend_recovery_inspection(handle, request_id).await
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        let _ = (handle, request_id);
        Err(crate::host::failure("EDITING_UNAVAILABLE_ON_TARGET"))
    }
}

#[derive(Debug, Clone)]
pub struct RetentionAccessView {
    pub session_token: String,
    pub run_id: String,
    pub operation_id: String,
    pub workspace_id: String,
    pub display_directory: String,
}
#[derive(Debug, Clone)]
pub struct RetentionInspectionView {
    pub session_token: String,
    pub run_id: String,
    pub operation_id: String,
    pub path: String,
    pub execution_state: String,
    pub staged: RecoveryFileStatusView,
    pub original: RecoveryFileStatusView,
    pub resource_active_records: i64,
    pub resource_active_reserved_bytes: String,
    pub owner_archive_records: i64,
    pub owner_archive_reserved_bytes: String,
    pub owner_archive_limit_bytes: String,
    pub owner_archive_record_limit: i64,
    pub archived_review_id: Option<String>,
    pub changed_since_archival: Option<bool>,
}
#[derive(Debug, Clone)]
pub struct RetentionReviewView {
    pub session_token: String,
    pub operation_id: String,
    pub review_id: String,
    pub digest: String,
    pub path: String,
    pub staged: RecoveryFileStatusView,
    pub original: RecoveryFileStatusView,
    pub archive_reserved_bytes: String,
    pub expires_at: i64,
}
/// Trusted UI only after a separate native selection for retained-file management.
pub async fn authorize_retention_access(
    handle: String,
    run_id: String,
    operation_id: String,
    request_id: String,
    workspace_version: String,
    selected_directory: String,
) -> Result<RetentionAccessView, BridgeError> {
    #[cfg(target_vendor = "apple")]
    {
        crate::host::authorize_retention_access(
            handle,
            run_id,
            operation_id,
            request_id,
            workspace_version,
            selected_directory,
        )
        .await
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        let _ = (
            handle,
            run_id,
            operation_id,
            request_id,
            workspace_version,
            selected_directory,
        );
        Err(crate::host::failure("EDITING_UNAVAILABLE_ON_TARGET"))
    }
}
pub async fn inspect_retention(
    handle: String,
    session_token: String,
) -> Result<RetentionInspectionView, BridgeError> {
    #[cfg(target_vendor = "apple")]
    {
        crate::host::inspect_retention(handle, session_token).await
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        let _ = (handle, session_token);
        Err(crate::host::failure("EDITING_UNAVAILABLE_ON_TARGET"))
    }
}
pub async fn prepare_retention_archive(
    handle: String,
    session_token: String,
    request_id: String,
) -> Result<RetentionReviewView, BridgeError> {
    #[cfg(target_vendor = "apple")]
    {
        crate::host::prepare_retention_archive(handle, session_token, request_id).await
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        let _ = (handle, session_token, request_id);
        Err(crate::host::failure("EDITING_UNAVAILABLE_ON_TARGET"))
    }
}
/// Explicit exact-preview confirmation; a failed reply must be queried, never blindly retried.
pub async fn approve_retention_archive(
    handle: String,
    session_token: String,
    review_id: String,
    expected_digest: String,
) -> Result<String, BridgeError> {
    #[cfg(target_vendor = "apple")]
    {
        crate::host::approve_retention_archive(handle, session_token, review_id, expected_digest)
            .await
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        let _ = (handle, session_token, review_id, expected_digest);
        Err(crate::host::failure("EDITING_UNAVAILABLE_ON_TARGET"))
    }
}
pub async fn suspend_retention_access(
    handle: String,
    request_id: String,
) -> Result<(), BridgeError> {
    #[cfg(target_vendor = "apple")]
    {
        crate::host::suspend_retention_access(handle, request_id).await
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        let _ = (handle, request_id);
        Err(crate::host::failure("EDITING_UNAVAILABLE_ON_TARGET"))
    }
}
