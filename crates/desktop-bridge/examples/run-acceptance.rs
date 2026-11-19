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
    #[serde(default)]
    memory: bool,
    #[serde(default)]
    memory_write: bool,
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
    if config.memory_write {
        return accept_memory_write(&config, handle, &grant.workspace_id).await;
    }
    if config.memory {
        return accept_memory(&config, handle, &grant.workspace_id).await;
    }
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
async fn accept_memory(
    config: &Config,
    handle: &str,
    workspace: &str,
) -> Result<(), Box<dyn Error>> {
    use orange_desktop_bridge::api::memory::*;
    let scope = create_scope(handle.into(), "personal".into(), false).await?;
    let empty_sources = || MemorySources {
        workspace_ids: vec![],
        memory_tokens: vec![],
    };
    let parent = authorize_scope(
        handle.into(),
        scope.scope_id.clone(),
        scope.revision.clone(),
        "owned-session".into(),
        true,
    )
    .await?;
    let selection = MemorySelection {
        scope_id: scope.scope_id.clone(),
        session_token: parent.session_token.clone(),
        sources: empty_sources(),
    };
    let draft = prepare_edit(
        handle.into(),
        selection.clone(),
        MemoryEdit {
            request_id: "seed".into(),
            entry_id: "proof".into(),
            expected_version: None,
            delete: false,
            title: Some("Verification code".into()),
            content: Some(config.sentinel.clone()),
            enabled: Some(true),
        },
    )
    .await?;
    approve_edit(
        handle.into(),
        selection,
        draft.draft_id,
        draft.approval_digest,
    )
    .await?;
    let task = |token: String| TaskMemorySelection {
        scopes: vec![TaskMemoryScope {
            scope_id: "personal".into(),
            session_token: token,
            write: false,
        }],
        sources: empty_sources(),
        creation: None,
        editing: None,
    };
    let id = uuid::Uuid::new_v4().to_string();
    let mut view=start_memory_run(handle.into(),workspace.into(),id.clone(),"Read the body of entry proof in the personal memory scope. Reply with the exact verification code stored in its content.".into(),task(parent.session_token),false).await?;
    let mut approvals = 0;
    let mut entry_requested = false;
    for _ in 0..12 {
        if view.phase == "completed" {
            break;
        }
        assert!(
            matches!(view.phase.as_str(), "ready" | "tools_pending"),
            "phase {}",
            view.phase
        );
        for op in view.pending.clone() {
            assert_eq!(op.tool_name, "memory_read");
            let args: serde_json::Value = serde_json::from_str(&op.arguments_json)?;
            assert_eq!(args["scope_id"], "personal");
            match args["mode"].as_str() {
                Some("entry") => {
                    assert_eq!(args["entry_id"], "proof");
                    entry_requested = true;
                }
                Some("list") => {} // Only this owned test scope is visible.
                _ => return Err("Unrecognized memory read mode".into()),
            }
            assert_eq!(
                advance_run(handle.into(), id.clone(), view.revision.clone())
                    .await
                    .expect_err("approval required")
                    .code,
                "TOOL_APPROVAL_REQUIRED"
            );
            view = approve_run_memory(
                handle.into(),
                id.clone(),
                op.operation_id,
                op.argument_digest,
            )
            .await?;
            approvals += 1;
        }
        view = advance_run(handle.into(), id.clone(), view.revision.clone()).await?;
    }
    assert_eq!(view.phase, "completed");
    assert!(
        approvals > 0 && entry_requested,
        "The model must read the actual entry body"
    );
    assert!(
        view.final_text
            .as_deref()
            .is_some_and(|text| text.contains(&config.sentinel))
    );
    close_host(handle.into())?;
    let reopened = open(&config.private_root).await?;
    restore_workspace_access(reopened.handle.clone(), workspace.into()).await?;
    assert!(
        inspect_run(reopened.handle.clone(), id.clone())
            .await
            .is_err()
    );
    let grant = authorize_scope(
        reopened.handle.clone(),
        scope.scope_id,
        scope.revision,
        "restored-read".into(),
        false,
    )
    .await?;
    let restored = restore_run_memory(
        reopened.handle.clone(),
        id.clone(),
        task(grant.session_token.clone()),
    )
    .await?;
    assert_eq!(restored.final_text, view.final_text);
    assert_eq!(restored.invocations, view.invocations);
    suspend_access(reopened.handle.clone(), grant.session_token).await?;
    assert!(inspect_run(reopened.handle.clone(), id).await.is_err());
    close_host(reopened.handle)?;
    println!(
        "{}",
        serde_json::json!({"passed":true,"scope":"Desktop Rust Host, real local CPU inference and explicitly approved memory_read","approved_operations":approvals,"model_invocations":view.invocations,"sentinel_matched":true,"reopen_requires_selection":true,"revocation_denied":true})
    );
    Ok(())
}
async fn accept_memory_write(
    config: &Config,
    h: &str,
    workspace: &str,
) -> Result<(), Box<dyn Error>> {
    use orange_desktop_bridge::api::memory::*;
    let scope = create_scope(h.into(), "personal".into(), false).await?;
    let parent = authorize_scope(
        h.into(),
        scope.scope_id.clone(),
        scope.revision,
        "write-selection".into(),
        true,
    )
    .await?;
    let empty = || MemorySources {
        workspace_ids: vec![],
        memory_tokens: vec![],
    };
    let selection = MemorySelection {
        scope_id: scope.scope_id.clone(),
        session_token: parent.session_token.clone(),
        sources: empty(),
    };
    let task = TaskMemorySelection {
        scopes: vec![TaskMemoryScope {
            scope_id: scope.scope_id,
            session_token: parent.session_token,
            write: true,
        }],
        sources: empty(),
        creation: None,
        editing: None,
    };
    let id = uuid::Uuid::new_v4().to_string();
    let args = serde_json::json!({"scope_id":"personal","mutation":"put","payload":{"title":"Verification code","content":config.sentinel,"enabled":true}});
    let prompt = format!(
        "Create a new enabled memory in my personal scope titled Verification code. Store this exact code as its content: {}. Confirm the save after approval.",
        config.sentinel
    );
    let mut view =
        start_memory_run(h.into(), workspace.into(), id.clone(), prompt, task, false).await?;
    let mut entry = None;
    for _ in 0..8 {
        if view.phase == "completed" {
            break;
        }
        assert!(matches!(view.phase.as_str(), "tools_pending" | "ready"));
        for op in view.pending.clone() {
            assert_eq!(op.tool_name, "memory_write");
            assert!(entry.is_none(), "duplicate effect rejected");
            let preview = preview_run_memory(h.into(), id.clone(), op.operation_id.clone()).await?;
            let review: serde_json::Value = serde_json::from_str(&preview.review_json)?;
            assert_eq!(review["payload"], args["payload"]);
            assert_eq!(review["scope_id"], "personal");
            assert_eq!(review["mutation"], "put");
            assert!(review["expected_version"].is_null());
            assert_eq!(
                advance_run(h.into(), id.clone(), view.revision.clone())
                    .await
                    .expect_err("preapproval")
                    .code,
                "TOOL_APPROVAL_REQUIRED"
            );
            assert!(
                approve_run_memory(
                    h.into(),
                    id.clone(),
                    op.operation_id.clone(),
                    op.argument_digest
                )
                .await
                .is_err()
            );
            entry = Some(
                review["entry_id"]
                    .as_str()
                    .ok_or("missing entry")?
                    .to_owned(),
            );
            view = approve_run_memory(
                h.into(),
                id.clone(),
                op.operation_id,
                preview.approval_digest,
            )
            .await?;
        }
        view = advance_run(h.into(), id.clone(), view.revision.clone()).await?;
    }
    assert_eq!(view.phase, "completed");
    let value = read_entry(
        h.into(),
        selection,
        entry.ok_or("model never proposed a write")?,
        Some("1".into()),
        0,
        4096,
        false,
    )
    .await?;
    assert_eq!(value.content, config.sentinel);
    assert_eq!(value.origin, "model_inference");
    close_host(h.into())?;
    println!(
        "{}",
        serde_json::json!({"passed":true,"scope":"real CPU model proposed and completed explicitly approved task memory write","approved_operations":1,"model_invocations":view.invocations,"actual_memory_version":value.version,"origin":value.origin,"sentinel_matched":true})
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
