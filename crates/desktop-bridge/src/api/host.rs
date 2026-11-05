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
pub struct AgentRunView {
    pub run_id: String,
    pub workspace_id: String,
    pub model_id: String,
    pub phase: String,
    pub revision: String,
    pub steps: u32,
    pub invocations: u32,
    pub pending: Vec<ToolApprovalView>,
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
