use super::{BridgeError, LOCAL_OWNER, failure, runs::engine_error};
use crate::api::host::{LocalPackageReview, LocalSkillSelection};
use orange_agent_runtime::skills::SkillPin;

fn revision(value: &str) -> Result<i64, BridgeError> {
    value
        .parse::<i64>()
        .ok()
        .filter(|n| *n >= 0 && n.to_string() == value)
        .ok_or_else(|| failure("INVALID_SKILL_SELECTION"))
}

pub(crate) async fn review_local_package(
    handle: String,
    manifest: String,
) -> Result<LocalPackageReview, BridgeError> {
    crate::actor::call(handle.clone(), move |host, _| {
        let review = host
            .current(&handle)?
            .journal
            .review_skill_package(LOCAL_OWNER, manifest.as_bytes())
            .map_err(engine_error)?;
        Ok(LocalPackageReview {
            skill_id: review.pin.id,
            version: review.pin.version,
            digest: review.pin.digest,
            scenario: review.template.scenario,
            display_name: review.template.name,
            instruction: review.template.instruction,
            tools: review.template.tools,
            installed: review.installed,
            installation_revision: review.installation_revision.to_string(),
            activation_revision: review.activation_revision.to_string(),
        })
    })
    .await
}
pub(crate) async fn install_local_package(
    handle: String,
    manifest: String,
    digest: String,
    installation_revision: String,
) -> Result<String, BridgeError> {
    let expected = revision(&installation_revision)?;
    crate::actor::call(handle.clone(), move |host, _| {
        Ok(host
            .current(&handle)?
            .journal
            .install_skill_package(LOCAL_OWNER, manifest.as_bytes(), &digest, expected)
            .map_err(engine_error)?
            .to_string())
    })
    .await
}
pub(crate) async fn uninstall_local_package(
    handle: String,
    selection: LocalSkillSelection,
    installation_revision: String,
) -> Result<String, BridgeError> {
    let expected = revision(&installation_revision)?;
    let activation = revision(&selection.activation_revision)?;
    let pin = SkillPin {
        id: selection.skill_id,
        version: selection.version,
        digest: selection.digest,
    };
    crate::actor::call(handle.clone(), move |host, _| {
        Ok(host
            .current(&handle)?
            .journal
            .uninstall_skill_package(LOCAL_OWNER, &pin, expected, activation)
            .map_err(engine_error)?
            .to_string())
    })
    .await
}
