//! Content-free retention discovery. These entry points do not call run_context
//! or open a filesystem capability; retained files require a separate selection.
use super::*;

pub(crate) async fn list_retained_edits(
    handle: String,
    run: String,
    before: Option<String>,
    limit: u16,
) -> Result<Vec<String>, BridgeError> {
    crate::actor::call(handle.clone(), move |registry, _| {
        registry
            .current(&handle)?
            .journal
            .agent_retention_patch_ids(LOCAL_OWNER, &run, before.as_deref(), limit)
            .map_err(runs::engine_error)
    })
    .await
}

pub(crate) async fn inspect_retention_outcome(
    handle: String,
    run: String,
    operation: String,
) -> Result<Option<String>, BridgeError> {
    crate::actor::call(handle.clone(), move |registry, _| {
        registry
            .current(&handle)?
            .journal
            .agent_retention_review_id(LOCAL_OWNER, &run, &operation)
            .map_err(runs::engine_error)
    })
    .await
}
