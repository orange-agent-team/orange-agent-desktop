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

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
