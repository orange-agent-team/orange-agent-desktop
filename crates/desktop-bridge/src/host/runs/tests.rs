use super::*;
use crate::api::host as api;
use orange_protocol::model::{ResponseCandidate, ToolCall};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;
use tokio::sync::Notify;

// Explicit transport substitute; filesystem tools and SQLite are real. This
// suite proves ownership/cancellation behavior, not model inference quality.
struct ModelFixture {
    calls: AtomicUsize,
    waiting: bool,
    started: Notify,
}
struct FixtureGateway(Arc<ModelFixture>);
impl ModelGateway for FixtureGateway {
    fn generate<'a>(
        &'a self,
        request: &'a GenerateRequest,
        mut cancel: watch::Receiver<bool>,
    ) -> ModelFuture<'a> {
        Box::pin(async move {
            request.validate().expect("valid request");
            let index = self.0.calls.fetch_add(1, Ordering::SeqCst);
            if self.0.waiting {
                self.0.started.notify_one();
                if !*cancel.borrow() {
                    cancel.changed().await.expect("cancel sender");
                }
                assert!(*cancel.borrow());
                return Err(GatewayFailure);
            }
            if index == 0 {
                Ok(ResponseCandidate {
                    response_id: "fixture-tool".into(),
                    text: String::new(),
                    tool_calls: vec![ToolCall {
                        id: "fixture-read".into(),
                        name: "read_file".into(),
                        arguments: serde_json::json!({"path":"note.txt"}),
                    }],
                    native_usage: None,
                    finish_reason: "tool_calls".into(),
                })
            } else {
                assert_eq!(index, 1, "no replayed model request");
                assert!(
                    request
                        .messages
                        .iter()
                        .any(|m| m.role == Role::Tool && m.content.contains("actual fixture data"))
                );
                Ok(ResponseCandidate {
                    response_id: "fixture-final".into(),
                    text: "fixture final".into(),
                    tool_calls: vec![],
                    native_usage: None,
                    finish_reason: "stop".into(),
                })
            }
        })
    }
}
async fn install(handle: &str, waiting: bool) -> Arc<ModelFixture> {
    let fixture = Arc::new(ModelFixture {
        calls: AtomicUsize::new(0),
        waiting,
        started: Notify::new(),
    });
    let model = fixture.clone();
    let handle = handle.to_owned();
    crate::actor::call(handle.clone(), move |host, _| {
        host.current(&handle)?.model = Some(ModelConnection {
            view: ModelConnectionView {
                model_id: "test-only-model".into(),
                display_name: "explicit fixture".into(),
                context_tokens: 4096,
                verification: "test-substitute".into(),
            },
            gateway: Box::new(FixtureGateway(model)),
        });
        Ok(())
    })
    .await
    .expect("install test transport");
    fixture
}
async fn step(handle: &str, run: &AgentRunView) -> Result<AgentRunView, BridgeError> {
    api::advance_run(handle.into(), run.run_id.clone(), run.revision.clone()).await
}
async fn waiting_run(
    handle: &str,
    workspace: &str,
    id: &str,
) -> tokio::task::JoinHandle<Result<AgentRunView, BridgeError>> {
    let fixture = install(handle, true).await;
    let run = api::start_run(
        handle.into(),
        workspace.into(),
        id.into(),
        "Wait for cancellation".into(),
    )
    .await
    .unwrap_or_else(|error| panic!("start waiting run {id}: {error}"));
    let handle = handle.to_owned();
    let pending = tokio::spawn(async move { step(&handle, &run).await });
    tokio::time::timeout(Duration::from_secs(3), fixture.started.notified())
        .await
        .expect("model started without blocking caller runtime");
    pending
}
async fn bounded<T>(future: impl std::future::Future<Output = T>) -> T {
    tokio::time::timeout(Duration::from_secs(3), future)
        .await
        .expect("control operation must not wait behind blocked model")
}

// One actor test owns the process-global session. Other host tests instantiate
// isolated HostRegistry values and never compete for this session.
#[tokio::test]
async fn actor_approval_cancellation_revocation_close_and_recovery() {
    let temporary = tempfile::tempdir().expect("temporary");
    let private = temporary.path().join("private");
    let workspace = temporary.path().join("workspace");
    fs::create_dir(&workspace).expect("fixture operation succeeds");
    let source = workspace.join("note.txt");
    fs::write(&source, "actual fixture data").expect("fixture operation succeeds");
    let host =
        api::initialize_host(private.display().to_string()).expect("fixture operation succeeds");
    let h = &host.handle;
    let grant = api::authorize_workspace(
        h.clone(),
        "consent-1".into(),
        workspace.display().to_string(),
    )
    .await
    .expect("fixture operation succeeds");
    let start = || {
        api::start_run(
            h.clone(),
            grant.workspace_id.clone(),
            "run-1".into(),
            "Read note.txt".into(),
        )
    };
    assert_eq!(
        start()
            .await
            .expect_err("unsafe or stale operation must be rejected")
            .code,
        "MODEL_NOT_CONFIGURED"
    );
    assert!(
        api::list_runs(h.clone(), None, None, 100)
            .await
            .expect("fixture operation succeeds")
            .runs
            .is_empty()
    );
    let model = install(h, false).await;
    let initial = start().await.expect("fixture operation succeeds");
    assert_eq!(
        start().await.expect("fixture operation succeeds").revision,
        initial.revision
    );
    assert_eq!(
        api::start_run(
            h.clone(),
            grant.workspace_id.clone(),
            "run-1".into(),
            "different prompt".into()
        )
        .await
        .expect_err("unsafe or stale operation must be rejected")
        .code,
        "RUN_CONFLICT"
    );
    let pending = step(h, &initial).await.expect("fixture operation succeeds");
    assert_eq!(pending.pending.len(), 1);
    assert_eq!(
        step(h, &initial)
            .await
            .expect_err("unsafe or stale operation must be rejected")
            .code,
        "RUN_VERSION_CHANGED"
    );
    assert_eq!(
        step(h, &pending)
            .await
            .expect_err("unsafe or stale operation must be rejected")
            .code,
        "TOOL_APPROVAL_REQUIRED"
    );
    let tool = &pending.pending[0];
    assert_eq!(
        api::approve_tool(
            h.clone(),
            pending.run_id.clone(),
            tool.operation_id.clone(),
            "wrong".into()
        )
        .await
        .expect_err("unsafe or stale operation must be rejected")
        .code,
        "TOOL_PREVIEW_CHANGED"
    );
    let approved = api::approve_tool(
        h.clone(),
        pending.run_id.clone(),
        tool.operation_id.clone(),
        tool.argument_digest.clone(),
    )
    .await
    .expect("fixture operation succeeds");
    let executed = step(h, &approved)
        .await
        .expect("fixture operation succeeds");
    let completed = step(h, &executed)
        .await
        .expect("fixture operation succeeds");
    assert_eq!(completed.phase, "completed");
    assert_eq!(completed.final_text.as_deref(), Some("fixture final"));
    assert_eq!(
        step(h, &completed)
            .await
            .expect("fixture operation succeeds")
            .final_text,
        completed.final_text
    );
    assert_eq!(model.calls.load(Ordering::SeqCst), 2);
    fs::remove_file(&source).expect("fixture operation succeeds");
    assert_eq!(
        api::inspect_run(h.clone(), "run-1".into())
            .await
            .expect_err("unsafe or stale operation must be rejected")
            .code,
        "RUN_SOURCE_UNAVAILABLE"
    );
    let cancelled = api::cancel_run(h.clone(), "run-1".into())
        .await
        .expect("fixture operation succeeds");
    assert_eq!(cancelled.phase, "completed", "preserve completed history");
    assert!(cancelled.final_text.is_none());
    fs::write(&source, "actual fixture data").expect("fixture operation succeeds");

    let pending = waiting_run(h, &grant.workspace_id, "run-cancel").await;
    let read_handle = h.clone();
    let queued = tokio::spawn(async move { api::list_runs(read_handle, None, None, 100).await });
    let cancelled = bounded(api::cancel_run(h.clone(), "run-cancel".into()))
        .await
        .expect("fixture operation succeeds");
    assert_eq!(cancelled.phase, "cancelled");
    assert_eq!(
        bounded(pending)
            .await
            .expect("fixture operation succeeds")
            .expect("fixture operation succeeds")
            .phase,
        "cancelled"
    );
    assert!(
        !bounded(queued)
            .await
            .expect("fixture operation succeeds")
            .expect("fixture operation succeeds")
            .runs
            .is_empty()
    );
    assert!(
        api::list_workspaces(h.clone(), false)
            .await
            .expect("fixture operation succeeds")[0]
            .session_access,
        "cancelling one Run must preserve workspace consent"
    );

    // An interrupted dispatched model call remains unknown; cancellation is
    // not proof of a settled invocation. Do not bypass workspace quarantine.
    assert_eq!(
        api::start_run(
            h.clone(),
            grant.workspace_id.clone(),
            "unknown-retry".into(),
            "retry".into()
        )
        .await
        .expect_err("unsafe or stale operation must be rejected")
        .code,
        "WORKSPACE_RECOVERY_REQUIRED"
    );
    let revoke_workspace = temporary.path().join("revoke-workspace");
    fs::create_dir(&revoke_workspace).expect("fixture operation succeeds");
    let revoke_grant = api::authorize_workspace(
        h.clone(),
        "consent-revoke".into(),
        revoke_workspace.display().to_string(),
    )
    .await
    .expect("fixture operation succeeds");
    let pending = waiting_run(h, &revoke_grant.workspace_id, "run-revoke").await;
    let revoked = bounded(api::revoke_workspace(
        h.clone(),
        revoke_grant.workspace_id.clone(),
        revoke_grant.permission_version.clone(),
    ))
    .await
    .expect("fixture operation succeeds");
    assert!(!revoked.permission_active && !revoked.session_access);
    let stopped = bounded(pending)
        .await
        .expect("fixture operation succeeds")
        .expect("fixture operation succeeds");
    assert_eq!(stopped.phase, "cancelled");
    assert!(stopped.final_text.is_none() && stopped.pending.is_empty());
    assert_eq!(
        api::inspect_run(h.clone(), "run-revoke".into())
            .await
            .expect_err("unsafe or stale operation must be rejected")
            .code,
        "WORKSPACE_SESSION_ACCESS_REQUIRED"
    );

    let workspace2 = temporary.path().join("workspace2");
    fs::create_dir(&workspace2).expect("fixture operation succeeds");
    let grant2 = api::authorize_workspace(
        h.clone(),
        "consent-2".into(),
        workspace2.display().to_string(),
    )
    .await
    .expect("fixture operation succeeds");
    let pending = waiting_run(h, &grant2.workspace_id, "run-close").await;
    api::close_host(h.clone()).expect("fixture operation succeeds");
    assert_eq!(
        api::inspect_host(h.clone())
            .expect_err("unsafe or stale operation must be rejected")
            .code,
        "STALE_HOST_HANDLE"
    );
    assert_eq!(
        bounded(pending)
            .await
            .expect("fixture operation succeeds")
            .expect_err("unsafe or stale operation must be rejected")
            .code,
        "STALE_HOST_HANDLE"
    );
    let reopened = bounded(async {
        loop {
            match api::initialize_host(private.display().to_string()) {
                Ok(view) => break view,
                Err(e) if e.code == "HOST_BUSY" => {
                    tokio::time::sleep(Duration::from_millis(10)).await
                }
                Err(e) => panic!("unexpected reopen failure: {e}"),
            }
        }
    })
    .await;
    assert_ne!(reopened.handle, *h);
    assert!(
        api::list_workspaces(reopened.handle.clone(), false)
            .await
            .expect("fixture operation succeeds")
            .iter()
            .all(|g| !g.session_access)
    );
    api::close_host(reopened.handle).expect("fixture operation succeeds");
}
