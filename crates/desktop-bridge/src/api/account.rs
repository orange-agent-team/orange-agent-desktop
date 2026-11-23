//! Read-only account boundary. The installed application owns the destination.
use super::host::BridgeError;

#[derive(Debug, Clone)]
pub struct PersonalApiEndpoint {
    pub origin: String,
    pub allow_local_development_certificate: bool,
}
#[derive(Debug, Clone)]
pub struct RemoteWalletView {
    pub user_id: String,
    pub owner_id: String,
    pub gift: String,
    pub earned: String,
    pub purchased: String,
    pub reserved_gift: String,
    pub reserved_earned: String,
    pub reserved_purchased: String,
    pub pending_earned: String,
}
#[derive(Debug, Clone)]
pub struct RemoteBudgetView {
    pub root_budget_id: String,
    pub scope_id: String,
    pub limit: String,
    pub spent: String,
    pub reserved: String,
    pub status: String,
}
#[derive(Debug, Clone)]
pub struct RemoteBudgetPage {
    pub user_id: String,
    pub owner_id: String,
    pub data: Vec<RemoteBudgetView>,
    pub next_cursor: Option<String>,
}
pub fn personal_api_endpoint(handle: String) -> Result<PersonalApiEndpoint, BridgeError> {
    crate::host::account::endpoint(&handle)
}
pub async fn read_personal_wallet(
    handle: String,
    credential: String,
    local_certificate_pem: Option<String>,
) -> Result<RemoteWalletView, BridgeError> {
    crate::host::account::wallet(&handle, &credential, local_certificate_pem.as_deref()).await
}
pub async fn read_personal_budgets(
    handle: String,
    credential: String,
    local_certificate_pem: Option<String>,
    after: Option<String>,
    limit: u16,
) -> Result<RemoteBudgetPage, BridgeError> {
    crate::host::account::budgets(
        &handle,
        &credential,
        local_certificate_pem.as_deref(),
        after.as_deref(),
        limit,
    )
    .await
}
