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
    tool: &'static str,
    arguments: serde_json::Value,
    expected_result: &'static str,
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
                        name: self.0.tool.into(),
                        arguments: self.0.arguments.clone(),
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
                        .any(|m| m.role == Role::Tool && m.content.contains(self.0.expected_result))
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
    install_tool(
        handle,
        waiting,
        "read_file",
        serde_json::json!({"path":"note.txt"}),
        "actual fixture data",
    )
    .await
}
async fn install_tool(
    handle: &str,
    waiting: bool,
    tool: &'static str,
    arguments: serde_json::Value,
    expected_result: &'static str,
) -> Arc<ModelFixture> {
    let fixture = Arc::new(ModelFixture {
        calls: AtomicUsize::new(0),
        waiting,
        started: Notify::new(),
        tool,
        arguments,
        expected_result,
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
    let old_token = grant.session_token.clone().expect("session scope token");
    let suspended =
        api::suspend_workspace_access(h.clone(), grant.workspace_id.clone(), old_token.clone())
            .await
            .expect("stop OS session access");
    assert!(
        suspended.permission_active
            && !suspended.session_access
            && suspended.session_token.is_none()
    );
    assert_eq!(
        api::inspect_run(h.clone(), "run-1".into())
            .await
            .expect_err("suspended content denied")
            .code,
        "WORKSPACE_SESSION_ACCESS_REQUIRED"
    );
    let restored = api::restore_workspace_access(h.clone(), grant.workspace_id.clone())
        .await
        .expect("fixture owner revalidates OS access");
    assert_ne!(restored.session_token, Some(old_token.clone()));
    assert_eq!(
        api::suspend_workspace_access(h.clone(), grant.workspace_id.clone(), old_token)
            .await
            .expect_err("old scope cannot suspend newer access")
            .code,
        "WORKSPACE_SESSION_CHANGED"
    );
    assert_eq!(
        api::inspect_run(h.clone(), "run-1".into())
            .await
            .expect("authorized completed history")
            .final_text,
        completed.final_text
    );
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

    // The newly imported Runtime must not expose cached search results after
    // a source is removed or its full version changes. Keep one owner of the
    // process-global actor; these are real Bridge/SQLite/filesystem transitions.
    for (id, name, arguments, expected, change_footer) in [
        (
            "filename-delete",
            "search_files",
            serde_json::json!({"path":".","glob":"note.txt"}),
            "note.txt",
            false,
        ),
        (
            "text-delete",
            "search_text",
            serde_json::json!({"path":".","query":"actual"}),
            "actual fixture data",
            false,
        ),
        (
            "text-version",
            "search_text",
            serde_json::json!({"path":".","query":"actual"}),
            "actual fixture data",
            true,
        ),
    ] {
        fs::write(&source, "actual fixture data\nfooter-a").expect("search fixture");
        let model = install_tool(h, false, name, arguments, expected).await;
        let started = api::start_run(
            h.clone(),
            grant.workspace_id.clone(),
            id.into(),
            "Search the owned fixture".into(),
        )
        .await
        .expect("start search");
        let pending = step(h, &started).await.expect("committed search intent");
        assert_eq!(pending.pending.len(), 1);
        assert_eq!(pending.pending[0].tool_name, name);
        assert_eq!(
            step(h, &pending)
                .await
                .expect_err("search needs approval")
                .code,
            "TOOL_APPROVAL_REQUIRED"
        );
        let preview = &pending.pending[0];
        let approved = api::approve_tool(
            h.clone(),
            pending.run_id.clone(),
            preview.operation_id.clone(),
            preview.argument_digest.clone(),
        )
        .await
        .expect("approve exact search");
        let searched = step(h, &approved).await.expect("actual filesystem search");
        let completed = step(h, &searched).await.expect("complete search run");
        assert_eq!(completed.phase, "completed");
        assert_eq!(
            api::inspect_run(h.clone(), completed.run_id.clone())
                .await
                .expect("current source")
                .final_text
                .as_deref(),
            Some("fixture final")
        );
        if change_footer {
            // Same length, same matching line/excerpt, different full-file SHA.
            fs::write(&source, "actual fixture data\nfooter-b").expect("change hidden footer");
        } else {
            fs::remove_file(&source).expect("delete exact fixture");
        }
        assert_eq!(
            api::inspect_run(h.clone(), completed.run_id.clone())
                .await
                .expect_err("cached search content unavailable")
                .code,
            "RUN_SOURCE_UNAVAILABLE"
        );
        assert_eq!(
            step(h, &completed)
                .await
                .expect_err("no reuse of stale search context")
                .code,
            "RUN_SOURCE_UNAVAILABLE"
        );
        let redacted = api::cancel_run(h.clone(), completed.run_id.clone())
            .await
            .expect("stop without restoring deleted data");
        assert_eq!(redacted.phase, "completed");
        assert!(redacted.final_text.is_none());
        assert_eq!(
            model.calls.load(Ordering::SeqCst),
            2,
            "no replayed model effect"
        );
    }
    fs::write(&source, "actual fixture data").expect("restore own fixture for later cases");

    let lost = temporary.path().join("lost-authorization-reply");
    fs::create_dir(&lost).expect("lost reply fixture");
    // The caller deliberately discards the returned workspace identity/token.
    api::authorize_workspace(
        h.clone(),
        "lost-selection".into(),
        lost.display().to_string(),
    )
    .await
    .expect("committed authorization");
    api::suspend_workspace_selection(h.clone(), "lost-selection".into())
        .await
        .expect("cleanup using pre-dispatch ID only");
    let replacement = api::authorize_workspace(
        h.clone(),
        "replacement-selection".into(),
        lost.display().to_string(),
    )
    .await
    .expect("fresh OS selection");
    api::suspend_workspace_selection(h.clone(), "lost-selection".into())
        .await
        .expect("obsolete cleanup is idempotent");
    assert!(
        api::list_workspaces(h.clone(), false)
            .await
            .expect("metadata")
            .iter()
            .any(|w| w.workspace_id == replacement.workspace_id && w.session_access)
    );
    assert_eq!(
        api::authorize_workspace(
            h.clone(),
            "lost-selection".into(),
            lost.display().to_string()
        )
        .await
        .expect_err("closed selection cannot be replayed")
        .code,
        "WORKSPACE_SELECTION_CLOSED"
    );
    api::suspend_workspace_selection(h.clone(), "replacement-selection".into())
        .await
        .expect("stop replacement");
    assert!(
        api::list_workspaces(h.clone(), false)
            .await
            .expect("metadata")
            .iter()
            .any(|w| w.workspace_id == replacement.workspace_id
                && w.permission_active
                && !w.session_access)
    );

    let pending = waiting_run(h, &grant.workspace_id, "run-cancel").await;
    let queued_path = temporary.path().join("queued-selection");
    fs::create_dir(&queued_path).expect("queued fixture");
    let authorize_handle = h.clone();
    let path = queued_path.display().to_string();
    let late_authorization = tokio::spawn(async move {
        api::authorize_workspace(authorize_handle, "queued-selection".into(), path).await
    });
    tokio::task::yield_now().await;
    bounded(api::suspend_workspace_selection(
        h.clone(),
        "queued-selection".into(),
    ))
    .await
    .expect("close selection even while owner awaits another model");
    let read_handle = h.clone();
    let queued = tokio::spawn(async move { api::list_runs(read_handle, None, None, 100).await });
    let cancelled = bounded(api::cancel_run(h.clone(), "run-cancel".into()))
        .await
        .expect("fixture operation succeeds");
    assert_eq!(cancelled.phase, "cancelled");
    assert_eq!(
        bounded(late_authorization)
            .await
            .expect("queued authorization task")
            .expect_err("queued selection already closed")
            .code,
        "WORKSPACE_SELECTION_CLOSED"
    );
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
            .expect("fixture operation succeeds")
            .iter()
            .find(|row| row.workspace_id == grant.workspace_id)
            .expect("original workspace remains registered")
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

    let suspension_workspace = temporary.path().join("suspension-workspace");
    fs::create_dir(&suspension_workspace).expect("new scope fixture");
    let scope = api::authorize_workspace(
        h.clone(),
        "scope-consent".into(),
        suspension_workspace.display().to_string(),
    )
    .await
    .expect("scope consent");
    let pending = waiting_run(h, &scope.workspace_id, "run-suspend").await;
    let suspended = bounded(api::suspend_workspace_access(
        h.clone(),
        scope.workspace_id.clone(),
        scope.session_token.expect("scope token"),
    ))
    .await
    .expect("bounded scope suspension");
    assert!(suspended.permission_active && !suspended.session_access);
    let stopped = bounded(pending)
        .await
        .expect("step task")
        .expect("cancelled step");
    assert_eq!(stopped.phase, "cancelled");
    assert!(stopped.pending.is_empty() && stopped.final_text.is_none());
    assert_eq!(
        api::restore_workspace_access(h.clone(), scope.workspace_id)
            .await
            .expect_err("unknown invocation remains quarantined")
            .code,
        "WORKSPACE_RECOVERY_REQUIRED"
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

struct QuestionGateway(Arc<AtomicUsize>);
impl ModelGateway for QuestionGateway {
    fn generate<'a>(
        &'a self,
        request: &'a GenerateRequest,
        _: watch::Receiver<bool>,
    ) -> ModelFuture<'a> {
        Box::pin(async move {
            request.validate().expect("valid interactive request");
            let index = self.0.fetch_add(1, Ordering::SeqCst);
            let (name, arguments) = match index {
                0 => (
                    "ask_user",
                    serde_json::json!({"questions":[{"prompt":"Which file?","choices":["note.txt","other.txt"]}]}),
                ),
                1 => {
                    assert!(
                        request
                            .messages
                            .iter()
                            .any(|m| m.role == Role::Tool && m.content.contains("note.txt"))
                    );
                    ("read_file", serde_json::json!({"path":"note.txt"}))
                }
                2 => {
                    assert!(
                        request
                            .messages
                            .iter()
                            .any(|m| m.role == Role::Tool
                                && m.content.contains("actual fixture data"))
                    );
                    (
                        "ask_user",
                        serde_json::json!({"questions":[{"prompt":"Use the content just read?"}]}),
                    )
                }
                _ => panic!("question waiting or answer must not dispatch a model"),
            };
            Ok(ResponseCandidate {
                response_id: format!("question-response-{index}"),
                text: String::new(),
                tool_calls: vec![ToolCall {
                    id: format!("question-call-{index}"),
                    name: name.into(),
                    arguments,
                }],
                native_usage: None,
                finish_reason: "tool_calls".into(),
            })
        })
    }
}
fn install_question_gateway(registry: &mut HostRegistry, handle: &str, calls: Arc<AtomicUsize>) {
    registry
        .current(handle)
        .expect("question fixture operation succeeds")
        .model = Some(ModelConnection {
        view: ModelConnectionView {
            model_id: "question-model-fixture".into(),
            display_name: "Explicit question transport fixture".into(),
            context_tokens: 4096,
            verification: "test-substitute".into(),
        },
        gateway: Box::new(QuestionGateway(calls)),
    });
}
#[tokio::test]
async fn questions_restore_reply_independently_then_revalidate_source() {
    let root = tempfile::tempdir().expect("question fixture operation succeeds");
    let private = root.path().join("private");
    let workspace = root.path().join("workspace");
    fs::create_dir(&workspace).expect("question fixture operation succeeds");
    fs::write(workspace.join("note.txt"), "actual fixture data")
        .expect("question fixture operation succeeds");
    let mut registry = HostRegistry::default();
    let h = registry
        .initialize(&private)
        .expect("question fixture operation succeeds")
        .handle;
    let grant = registry
        .authorize_workspace(&h, "question-consent", &workspace)
        .expect("question fixture operation succeeds");
    let calls = Arc::new(AtomicUsize::new(0));
    install_question_gateway(&mut registry, &h, calls.clone());
    let start = registry
        .start_run(
            &h,
            &grant.workspace_id,
            "question-run",
            "Ask before reading",
            true,
        )
        .await
        .expect("question fixture operation succeeds");
    assert_eq!(
        registry
            .start_run(
                &h,
                &grant.workspace_id,
                "question-run",
                "Ask before reading",
                false
            )
            .await
            .expect_err("invalid question authority must be rejected")
            .code,
        "RUN_CONFLICT"
    );
    let view = registry
        .advance_run(&h, &start.run_id, &start.revision)
        .await
        .expect("question fixture operation succeeds");
    assert_eq!(view.phase, "awaiting_user");
    assert!(view.pending.is_empty());
    let question = view
        .user_question
        .expect("question fixture operation succeeds");
    assert_eq!(
        question.questions[0]
            .choices
            .as_ref()
            .expect("question fixture operation succeeds")
            .len(),
        2
    );
    assert_eq!(
        registry
            .approve_tool(
                &h,
                &start.run_id,
                &question.question_id,
                &question.argument_digest
            )
            .await
            .expect_err("invalid question authority must be rejected")
            .code,
        "TOOL_PREVIEW_CHANGED"
    );
    assert!(
        registry
            .answer_question(
                &h,
                &start.run_id,
                &question.question_id,
                &"0".repeat(64),
                vec!["note.txt".into()]
            )
            .await
            .is_err()
    );
    assert!(
        registry
            .answer_question(
                &h,
                &start.run_id,
                &question.question_id,
                &question.argument_digest,
                vec![]
            )
            .await
            .is_err()
    );
    registry
        .close(&h)
        .expect("question fixture operation succeeds");
    // Fresh registry models a fresh process, without reviving old cancellation signals.
    let mut registry = HostRegistry::default();
    let h = registry
        .initialize(&private)
        .expect("question fixture operation succeeds")
        .handle;
    assert_eq!(
        registry
            .inspect_run(&h, &start.run_id)
            .await
            .expect_err("invalid question authority must be rejected")
            .code,
        "WORKSPACE_SESSION_ACCESS_REQUIRED"
    );
    registry
        .restore_workspace(&h, &grant.workspace_id)
        .expect("question fixture operation succeeds");
    let restored = registry
        .inspect_run(&h, &start.run_id)
        .await
        .expect("question fixture operation succeeds");
    assert_eq!(
        restored
            .user_question
            .as_ref()
            .expect("question fixture operation succeeds")
            .question_id,
        question.question_id
    );
    let answered = registry
        .answer_question(
            &h,
            &start.run_id,
            &question.question_id,
            &question.argument_digest,
            vec!["note.txt".into()],
        )
        .await
        .expect("question fixture operation succeeds");
    assert_eq!(answered.phase, "ready");
    assert!(answered.pending.is_empty() && answered.user_question.is_none());
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert_eq!(
        registry
            .answer_question(
                &h,
                &start.run_id,
                &question.question_id,
                &question.argument_digest,
                vec!["note.txt".into()]
            )
            .await
            .expect("question fixture operation succeeds")
            .revision,
        answered.revision
    );
    assert_eq!(
        registry
            .answer_question(
                &h,
                &start.run_id,
                &question.question_id,
                &question.argument_digest,
                vec!["other.txt".into()]
            )
            .await
            .expect_err("invalid question authority must be rejected")
            .code,
        "RUN_CONFLICT"
    );
    install_question_gateway(&mut registry, &h, calls.clone());
    let tool = registry
        .advance_run(&h, &start.run_id, &answered.revision)
        .await
        .expect("question fixture operation succeeds");
    assert_eq!(tool.pending.len(), 1);
    assert_eq!(
        registry
            .advance_run(&h, &start.run_id, &tool.revision)
            .await
            .expect_err("invalid question authority must be rejected")
            .code,
        "TOOL_APPROVAL_REQUIRED"
    );
    let pending = &tool.pending[0];
    let approved = registry
        .approve_tool(
            &h,
            &start.run_id,
            &pending.operation_id,
            &pending.argument_digest,
        )
        .await
        .expect("question fixture operation succeeds");
    let read = registry
        .advance_run(&h, &start.run_id, &approved.revision)
        .await
        .expect("question fixture operation succeeds");
    let second = registry
        .advance_run(&h, &start.run_id, &read.revision)
        .await
        .expect("question fixture operation succeeds");
    let next = second
        .user_question
        .expect("question fixture operation succeeds");
    assert_ne!(next.question_id, question.question_id);
    fs::remove_file(workspace.join("note.txt")).expect("question fixture operation succeeds");
    assert_eq!(
        registry
            .inspect_run(&h, &start.run_id)
            .await
            .expect_err("invalid question authority must be rejected")
            .code,
        "RUN_SOURCE_UNAVAILABLE"
    );
    assert_eq!(
        registry
            .answer_question(
                &h,
                &start.run_id,
                &next.question_id,
                &next.argument_digest,
                vec!["yes".into()]
            )
            .await
            .expect_err("invalid question authority must be rejected")
            .code,
        "RUN_SOURCE_UNAVAILABLE"
    );
    assert_eq!(calls.load(Ordering::SeqCst), 3);
    let stopped = registry
        .cancel_run(&h, &start.run_id)
        .expect("question fixture operation succeeds");
    assert_eq!(stopped.phase, "cancelled");
    assert!(stopped.user_question.is_none());
}

#[tokio::test]
async fn suspended_workspace_closes_waiting_question() {
    let root = tempfile::tempdir().expect("question fixture operation succeeds");
    let workspace = root.path().join("workspace");
    fs::create_dir(&workspace).expect("question fixture operation succeeds");
    let mut registry = HostRegistry::default();
    let h = registry
        .initialize(&root.path().join("private"))
        .expect("question fixture operation succeeds")
        .handle;
    let grant = registry
        .authorize_workspace(&h, "suspend-question", &workspace)
        .expect("question fixture operation succeeds");
    let calls = Arc::new(AtomicUsize::new(0));
    install_question_gateway(&mut registry, &h, calls.clone());
    let start = registry
        .start_run(&h, &grant.workspace_id, "suspend-run", "Ask", true)
        .await
        .expect("question fixture operation succeeds");
    let waiting = registry
        .advance_run(&h, &start.run_id, &start.revision)
        .await
        .expect("question fixture operation succeeds");
    assert!(waiting.user_question.is_some());
    registry
        .suspend_workspace(
            &h,
            &grant.workspace_id,
            grant
                .session_token
                .as_deref()
                .expect("active test scope has a token"),
        )
        .expect("question fixture operation succeeds");
    registry
        .restore_workspace(&h, &grant.workspace_id)
        .expect("question fixture operation succeeds");
    let stopped = registry
        .inspect_run(&h, &start.run_id)
        .await
        .expect("question fixture operation succeeds");
    assert_eq!(stopped.phase, "cancelled");
    assert!(stopped.user_question.is_none());
    let q = waiting
        .user_question
        .expect("question fixture operation succeeds");
    assert!(
        registry
            .answer_question(
                &h,
                &start.run_id,
                &q.question_id,
                &q.argument_digest,
                vec!["note.txt".into()]
            )
            .await
            .is_err()
    );
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn protected_unicode_aliases_never_reach_desktop_approval() {
    for (index, tool, args) in [
        (
            0,
            "read_file",
            serde_json::json!({"path":".Kube/proof.txt"}),
        ),
        (1, "list_directory", serde_json::json!({"path":".Kube"})),
        (
            2,
            "search_files",
            serde_json::json!({"path":".Kube","glob":"*"}),
        ),
        (
            3,
            "search_text",
            serde_json::json!({"path":".Kube","query":"fixture"}),
        ),
    ] {
        let root = tempfile::tempdir().expect("owned fixture");
        let workspace = root.path().join("workspace");
        fs::create_dir(&workspace).expect("workspace");
        fs::create_dir(workspace.join(".kube")).expect("protected fixture");
        fs::write(workspace.join(".kube/proof.txt"), "owned private fixture").expect("fixture");
        let mut registry = HostRegistry::default();
        let h = registry
            .initialize(&root.path().join("private"))
            .expect("host")
            .handle;
        let grant = registry
            .authorize_workspace(&h, "unicode-consent", &workspace)
            .expect("explicit fixture consent");
        let model = Arc::new(ModelFixture {
            calls: AtomicUsize::new(0),
            waiting: false,
            started: Notify::new(),
            tool,
            arguments: args,
            expected_result: "must never read protected content",
        });
        registry.current(&h).expect("host").model = Some(ModelConnection {
            view: ModelConnectionView {
                model_id: "unicode-fixture".into(),
                display_name: "explicit fixture".into(),
                context_tokens: 4096,
                verification: "test-substitute".into(),
            },
            gateway: Box::new(FixtureGateway(model.clone())),
        });
        let run = registry
            .start_run(
                &h,
                &grant.workspace_id,
                &format!("alias-{index}"),
                "Reject protected aliases",
                false,
            )
            .await
            .expect("run");
        assert!(
            registry
                .advance_run(&h, &run.run_id, &run.revision)
                .await
                .is_err()
        );
        let view = registry
            .inspect_run(&h, &run.run_id)
            .await
            .expect("recovery metadata");
        assert_eq!(view.phase, "recovery_required");
        assert!(view.pending.is_empty() && view.final_text.is_none());
        assert_eq!(model.calls.load(Ordering::SeqCst), 1);
    }
}
