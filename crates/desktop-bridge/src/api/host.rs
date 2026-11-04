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
pub fn authorize_workspace(
    handle: String,
    request_id: String,
    selected_directory: String,
) -> Result<WorkspaceView, BridgeError> {
    crate::host::authorize_workspace(handle, request_id, selected_directory)
}
pub fn list_workspaces(
    handle: String,
    include_revoked: bool,
) -> Result<Vec<WorkspaceView>, BridgeError> {
    crate::host::list_workspaces(handle, include_revoked)
}
/// Restore only after the platform has revalidated its OS permission/bookmark.
pub fn restore_workspace_access(
    handle: String,
    workspace_id: String,
) -> Result<WorkspaceView, BridgeError> {
    crate::host::restore_workspace_access(handle, workspace_id)
}
pub fn revoke_workspace(
    handle: String,
    workspace_id: String,
    expected_version: String,
) -> Result<WorkspaceView, BridgeError> {
    crate::host::revoke_workspace(handle, workspace_id, expected_version)
}
pub fn list_runs(
    handle: String,
    workspace_id: Option<String>,
    before: Option<String>,
    limit: u16,
) -> Result<RunPage, BridgeError> {
    crate::host::list_runs(handle, workspace_id, before, limit)
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
