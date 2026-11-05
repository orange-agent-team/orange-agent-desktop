//! Opt-in real-model API acceptance. The driver owns the temporary workspace;
//! approvals here are bounded test-owner decisions, never product auto-approval.
use orange_desktop_bridge::api::host::*;
use orange_model_runtime::cache::{ArtifactSpec, ModelCache};
use serde::Deserialize;
use std::{error::Error, fs, time::Duration};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ImportConfig {
    source: String,
    cache: String,
    url: String,
    sha256: String,
    bytes: u64,
}
async fn import_selected(config: ImportConfig) -> Result<(), Box<dyn Error>> {
    let spec = ArtifactSpec::new(
        &config.url,
        &config.sha256,
        config.bytes,
        &["huggingface.co"],
        b"GGUF",
    )?;
    let cache = ModelCache::new(
        std::path::Path::new(&config.cache),
        config.bytes.checked_mul(2).ok_or("quota overflow")?,
    )?;
    let imported = cache
        .import_file(&spec, std::path::Path::new(&config.source))
        .await?;
    println!(
        "{}",
        serde_json::json!({"imported":true,"cached":imported.is_cached(),"sha256":imported.sha256(),"bytes":imported.bytes().to_string()})
    );
    Ok(())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Config {
    private_root: String,
    service_root: String,
    workspace: String,
    sentinel: String,
}
async fn open(root: &str) -> Result<HostView, BridgeError> {
    for _ in 0..100 {
        match initialize_host(root.into()) {
            Err(e) if e.code == "HOST_BUSY" => tokio::time::sleep(Duration::from_millis(10)).await,
            result => return result,
        }
    }
    initialize_host(root.into())
}
async fn accept(config: Config) -> Result<(), Box<dyn Error>> {
    let host = open(&config.private_root).await?;
    let handle = &host.handle;
    let grant = authorize_workspace(
        handle.clone(),
        "fixture-consent".into(),
        config.workspace.clone(),
    )
    .await?;
    let model = connect_local_model(handle.clone(), config.service_root.clone()).await?;
    assert_eq!(model.verification, "local-development-configuration");
    let run_id = format!("acceptance-{}", uuid::Uuid::new_v4());
    let mut view = start_run(handle.clone(),grant.workspace_id.clone(),run_id.clone(),
        "Use read_file to read the existing workspace file proof.txt with the relative path proof.txt. Do not guess its content. After the tool result is returned, answer with the exact file text.".into()).await?;
    let mut approvals = 0;
    let mut preapproval_rejected = false;
    for _ in 0..16 {
        if view.phase == "completed" {
            break;
        }
        assert!(
            matches!(view.phase.as_str(), "ready" | "tools_pending"),
            "unexpected phase {}",
            view.phase
        );
        if !view.pending.is_empty() {
            let rejected = advance_run(handle.clone(), run_id.clone(), view.revision.clone())
                .await
                .expect_err("explicit approval required");
            assert_eq!(rejected.code, "TOOL_APPROVAL_REQUIRED");
            preapproval_rejected = true;
        }
        for pending in view.pending.clone() {
            let arguments: serde_json::Value = serde_json::from_str(&pending.arguments_json)?;
            match pending.tool_name.as_str() {
                "read_file" => {
                    assert_eq!(arguments["path"], "proof.txt", "approve only our fixture")
                }
                "list_directory" => {
                    assert!(matches!(arguments["path"].as_str(), Some("" | ".") | None))
                }
                _ => panic!("unexpected capability; approval refused"),
            }
            view = approve_tool(
                handle.clone(),
                run_id.clone(),
                pending.operation_id,
                pending.argument_digest,
            )
            .await?;
            approvals += 1;
        }
        view = advance_run(handle.clone(), run_id.clone(), view.revision.clone()).await?;
    }
    assert_eq!(view.phase, "completed");
    assert!(
        view.final_text
            .as_ref()
            .is_some_and(|text| text.contains(&config.sentinel))
    );
    assert!(preapproval_rejected && approvals > 0);
    let version = view.revision.clone();
    close_host(handle.clone())?;
    let reopened = open(&config.private_root).await?;
    let handle = &reopened.handle;
    assert_eq!(
        inspect_run(handle.clone(), run_id.clone())
            .await
            .expect_err("session grant must be restored explicitly")
            .code,
        "WORKSPACE_SESSION_ACCESS_REQUIRED"
    );
    restore_workspace_access(handle.clone(), grant.workspace_id).await?;
    connect_local_model(handle.clone(), config.service_root).await?;
    let recovered = inspect_run(handle.clone(), run_id.clone()).await?;
    assert_eq!(recovered.revision, version);
    assert_eq!(recovered.final_text, view.final_text);
    let again = advance_run(handle.clone(), run_id.clone(), version.clone()).await?;
    assert_eq!(again.revision, version);
    assert_eq!(again.invocations, view.invocations);
    assert_eq!(again.steps, view.steps);
    fs::remove_file(std::path::Path::new(&config.workspace).join("proof.txt"))?;
    assert_eq!(
        inspect_run(handle.clone(), run_id.clone())
            .await
            .expect_err("deleted source must suppress cached text")
            .code,
        "RUN_SOURCE_UNAVAILABLE"
    );
    assert!(
        cancel_run(handle.clone(), run_id)
            .await?
            .final_text
            .is_none()
    );
    close_host(handle.clone())?;
    println!(
        "{}",
        serde_json::json!({"passed":true,"model_invocations":view.invocations,"steps":view.steps,"approved_operations":approvals,"sentinel_matched":true,"preapproval_rejected":true,"reopen_no_replay":true,"deleted_source_denied":true,"scope":"real local CPU model and desktop Rust Host API; not Flutter model UI, App Sandbox model transport, cloud, billing or GPU certification"})
    );
    Ok(())
}
fn main() -> Result<(), Box<dyn Error>> {
    let mut arguments = std::env::args_os().skip(1);
    let first = arguments
        .next()
        .ok_or("private fixture configuration required")?;
    let import = first == "--import";
    let path = if import {
        arguments
            .next()
            .ok_or("private import configuration required")?
    } else {
        first
    };
    if arguments.next().is_some() {
        return Err("unexpected acceptance arguments".into());
    }
    let bytes = fs::read(path)?;
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    if import {
        runtime.block_on(import_selected(serde_json::from_slice(&bytes)?))
    } else {
        runtime.block_on(accept(serde_json::from_slice(&bytes)?))
    }
}
