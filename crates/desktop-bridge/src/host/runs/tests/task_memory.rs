use super::*;
use crate::api::memory;

/// The gateway here proposes a write. Actual scope selection, approval, effect
/// and readback go through the public desktop API and the private SQLite store.
pub(super) async fn exercise(handle: &str, base: &Path) {
    let h = handle.to_owned();
    let path = base.join("task-memory-space");
    fs::create_dir(&path).expect("workspace");
    let workspace = api::authorize_workspace(
        h.clone(),
        "memory-task-space".into(),
        path.display().to_string(),
    )
    .await
    .expect("workspace selection");
    let scope = memory::create_scope(h.clone(), "task-personal".into(), false)
        .await
        .expect("scope");
    let access = memory::authorize_scope(
        h.clone(),
        scope.scope_id.clone(),
        scope.revision,
        "memory-task-parent".into(),
        true,
    )
    .await
    .expect("parent");
    let sources = || memory::MemorySources {
        workspace_ids: vec![],
        memory_tokens: vec![],
    };
    let select = |write| memory::TaskMemorySelection {
        scopes: vec![memory::TaskMemoryScope {
            scope_id: scope.scope_id.clone(),
            session_token: access.session_token.clone(),
            write,
        }],
        sources: sources(),
        creation: None,
        editing: None,
    };
    let args = serde_json::json!({"scope_id":"task-personal","mutation":"put","payload":{"title":"Preference","content":"Jasmine","enabled":true}});
    install_tool(&h, false, "memory_write", args, "approved").await;
    let id = "task-memory-writer".to_owned();
    let run = memory::start_memory_run(
        h.clone(),
        workspace.workspace_id.clone(),
        id.clone(),
        "Remember my preference after review".into(),
        select(true),
        false,
    )
    .await
    .expect("memory run");
    let pending = step(&h, &run).await.expect("proposal");
    let op = &pending.pending[0];
    assert!(step(&h, &pending).await.is_err());
    assert!(
        api::approve_tool(
            h.clone(),
            id.clone(),
            op.operation_id.clone(),
            op.argument_digest.clone()
        )
        .await
        .is_err()
    );
    let preview = memory::preview_run_memory(h.clone(), id.clone(), op.operation_id.clone())
        .await
        .expect("durable preview");
    let review: serde_json::Value = serde_json::from_str(&preview.review_json).expect("review");
    assert_eq!(review["payload"]["content"], "Jasmine");
    let entry = review["entry_id"].as_str().expect("entry").to_owned();
    assert!(
        memory::approve_run_memory(
            h.clone(),
            id.clone(),
            op.operation_id.clone(),
            op.argument_digest.clone()
        )
        .await
        .is_err()
    );
    let approved = memory::approve_run_memory(
        h.clone(),
        id.clone(),
        op.operation_id.clone(),
        preview.approval_digest,
    )
    .await
    .expect("exact approval");
    let applied = step(&h, &approved).await.expect("write");
    let done = step(&h, &applied).await.expect("model received outcome");
    assert_eq!(done.phase, "completed");
    let again = step(&h, &done)
        .await
        .expect("completed task can be inspected again");
    assert_eq!(again.final_text, done.final_text);
    assert_eq!(again.invocations, done.invocations);
    let selected = memory::MemorySelection {
        scope_id: scope.scope_id.clone(),
        session_token: access.session_token.clone(),
        sources: sources(),
    };
    let value = memory::read_entry(h.clone(), selected, entry, Some("1".into()), 0, 4096, false)
        .await
        .expect("real SQLite fact");
    assert_eq!(value.content, "Jasmine");
    assert_eq!(value.origin, "model_inference");
    assert!(
        memory::restore_run_memory(h.clone(), id.clone(), select(false))
            .await
            .is_err(),
        "immutable run mode"
    );
    let row = workspace.workspace_id;
    install_tool(&h,false,"memory_write",serde_json::json!({"scope_id":"task-personal","mutation":"put","payload":{"title":"Lost reply","content":"Only once","enabled":true}}),"approved").await;
    let uncertain_id = "uncertain-memory-run".to_owned();
    let started = memory::start_memory_run(
        h.clone(),
        row,
        uncertain_id.clone(),
        "Propose one fact".into(),
        select(true),
        false,
    )
    .await
    .expect("start uncertain fixture");
    let view = step(&h, &started).await.expect("propose");
    let op = view.pending[0].operation_id.clone();
    let preview = memory::preview_run_memory(h.clone(), uncertain_id.clone(), op.clone())
        .await
        .expect("preview");
    let approved = memory::approve_run_memory(
        h.clone(),
        uncertain_id.clone(),
        op.clone(),
        preview.approval_digest,
    )
    .await
    .expect("approve");
    let connection =
        rusqlite::Connection::open(base.join("private/host.sqlite")).expect("owned host database");
    connection.execute_batch("CREATE TRIGGER lose_task_receipt BEFORE UPDATE ON operations WHEN NEW.state='succeeded' AND NEW.tool_version='memory_write.v1' BEGIN SELECT RAISE(ABORT,'owned receipt fault');END;").expect("inject");
    assert!(step(&h, &approved).await.is_err());
    connection
        .execute_batch("DROP TRIGGER lose_task_receipt")
        .expect("remove");
    let found = memory::uncertain_task_writes(h.clone(), uncertain_id.clone(), None, 10)
        .await
        .expect("discover");
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].operation_id, op);
    assert_eq!(found[0].outcome.state, "approved");
    assert!(
        memory::reconcile_task_write(
            h.clone(),
            uncertain_id.clone(),
            op.clone(),
            found[0].outcome.digest.clone(),
            false,
            false
        )
        .await
        .is_err()
    );
    memory::suspend_access(h.clone(), access.session_token)
        .await
        .expect("revoke parent");
    memory::reconcile_task_write(
        h.clone(),
        uncertain_id.clone(),
        op,
        found[0].outcome.digest.clone(),
        true,
        false,
    )
    .await
    .expect("stop by receipt after withdrawal");
    assert!(
        memory::uncertain_task_writes(h.clone(), uncertain_id, None, 10)
            .await
            .expect("resolved")
            .is_empty()
    );
    assert!(
        api::inspect_run(h, id).await.is_err(),
        "no cached final text"
    );
}
