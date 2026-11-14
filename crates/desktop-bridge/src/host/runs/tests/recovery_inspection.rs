use super::*;
use sha2::{Digest, Sha256};

pub(super) async fn exercise(h: &str, base: &Path) -> String {
    let root = base.join("recovery-inspection-workspace");
    fs::create_dir(&root).expect("owned workspace");
    let source = root.join("note.txt");
    fs::write(&source, b"old\n").expect("owned source");
    let workspace = api::authorize_workspace(
        h.into(),
        "recovery-read-base".into(),
        root.display().to_string(),
    )
    .await
    .expect("read grant");
    let edit = api::authorize_editing_access(
        h.into(),
        workspace.workspace_id.clone(),
        "recovery-edit-base".into(),
        root.display().to_string(),
    )
    .await
    .expect("explicit edit consent");
    let model = install_tool(h,false,"apply_patch",serde_json::json!({"path":"note.txt","expected_sha256":hex::encode(Sha256::digest(b"old\n")),"patch":"@@ -1 +1 @@\n-old\n+new\n"}),"new").await;
    let run = api::start_editing_run(
        h.into(),
        workspace.workspace_id.clone(),
        "recovery-inspection-run".into(),
        "Edit".into(),
        api::RunPermissionSelection {
            consent_id: edit.consent_id,
            permission_version: edit.permission_version,
        },
        None,
        false,
    )
    .await
    .expect("editing Run");
    let pending = step(h, &run).await.expect("proposal");
    let operation = pending.pending[0].operation_id.clone();
    let preview = api::preview_editing_tool(h.into(), run.run_id.clone(), operation.clone())
        .await
        .expect("actual preview");
    let approved = api::approve_editing_tool(
        h.into(),
        run.run_id.clone(),
        operation.clone(),
        preview.preview_digest,
    )
    .await
    .expect("exact approval");
    // Test-only, externally injected SQLite receipt failure. Runtime never
    // exposes its connection or a fault-injection API to Flutter/model callers.
    let database = rusqlite::Connection::open(base.join("private/host.sqlite"))
        .expect("owned fixture database");
    database.execute_batch("CREATE TRIGGER recovery_inspection_receipt_fault BEFORE INSERT ON patch_version_edges BEGIN SELECT RAISE(ABORT,'owned inspection fixture'); END;").expect("receipt fault");
    let _ = step(h, &approved).await;
    database
        .execute_batch("DROP TRIGGER recovery_inspection_receipt_fault;")
        .expect("remove only owned fault");
    drop(database);
    assert_eq!(fs::read(&source).expect("actual effect"), b"new\n");
    assert_eq!(
        api::list_unresolved_edits(h.into(), run.run_id.clone(), None, 10)
            .await
            .expect("unknown index"),
        vec![operation.clone()]
    );
    assert_eq!(
        api::authorize_recovery_inspection(
            h.into(),
            run.run_id.clone(),
            operation.clone(),
            workspace
                .session_token
                .clone()
                .expect("existing ordinary token"),
            workspace.permission_version.clone(),
            root.display().to_string()
        )
        .await
        .expect_err("ordinary scope is not separate recovery consent")
        .code,
        "RECOVERY_SELECTION_CONFLICT"
    );
    api::suspend_workspace_access(
        h.into(),
        workspace.workspace_id.clone(),
        workspace.session_token.expect("native normal scope"),
    )
    .await
    .expect("release ordinary scope");
    assert!(
        api::inspect_run(h.into(), run.run_id.clone())
            .await
            .is_err()
    );
    api::close_host(h.into()).expect("close unknown Host without replay");
    let reopened = bounded(async {
        loop {
            match api::initialize_host(base.join("private").display().to_string()) {
                Ok(view) => break view,
                Err(e) if e.code == "HOST_BUSY" => {
                    tokio::time::sleep(Duration::from_millis(10)).await
                }
                Err(e) => panic!("unexpected recovery reopen: {e}"),
            }
        }
    })
    .await;
    let h = reopened.handle.as_str();
    let key = h.to_owned();
    crate::actor::call(key, |registry, _| {
        assert!(
            registry
                .signals
                .lock()
                .expect("signals")
                .workspaces
                .is_empty(),
            "reopen must not restore any ordinary scope"
        );
        Ok(())
    })
    .await
    .expect("no restored authority");
    api::suspend_recovery_inspection(h.into(), "late-inspection".into())
        .await
        .expect("close before authorization callback");
    assert_eq!(
        api::authorize_recovery_inspection(
            h.into(),
            run.run_id.clone(),
            operation.clone(),
            "late-inspection".into(),
            workspace.permission_version.clone(),
            root.display().to_string()
        )
        .await
        .expect_err("closed callback")
        .code,
        "RECOVERY_SELECTION_CLOSED"
    );
    assert!(
        api::authorize_recovery_inspection(
            h.into(),
            run.run_id.clone(),
            operation.clone(),
            "wrong-inspection-version".into(),
            "999".into(),
            root.display().to_string()
        )
        .await
        .is_err()
    );
    assert!(
        api::authorize_recovery_inspection(
            h.into(),
            run.run_id.clone(),
            operation.clone(),
            "private-inspection-root".into(),
            workspace.permission_version.clone(),
            base.join("private").display().to_string()
        )
        .await
        .is_err()
    );
    let access = api::authorize_recovery_inspection(
        h.into(),
        run.run_id.clone(),
        operation.clone(),
        "fresh-inspection".into(),
        workspace.permission_version.clone(),
        root.display().to_string(),
    )
    .await
    .expect("independent read consent while ordinary execution stays quarantined");
    let snapshot = api::inspect_recovery(h.into(), access.session_token.clone())
        .await
        .expect("actual file observations");
    assert_eq!(snapshot.path, "note.txt");
    assert_eq!(snapshot.execution_state, "unknown");
    assert_eq!(
        snapshot.target.sha256.as_deref(),
        Some(hex::encode(Sha256::digest(b"new\n")).as_str())
    );
    assert!(snapshot.target.matches_result_content && snapshot.original.matches_original_content);
    assert!(
        api::restore_workspace_access(h.into(), workspace.workspace_id.clone())
            .await
            .is_err(),
        "inspection cannot remove execution quarantine"
    );
    assert!(
        api::inspect_run(h.into(), run.run_id.clone())
            .await
            .is_err(),
        "inspection is not ordinary read restoration"
    );
    let handle = h.to_owned();
    let token = access.session_token.clone();
    let receipt = crate::actor::call(handle.clone(), move |registry, rt| {
        let read = registry
            .signals
            .lock()
            .map_err(|_| failure("HOST_INTERNAL"))?
            .recovery_inspections[&token]
            .read
            .clone();
        rt.block_on(
            registry
                .current(&handle)?
                .journal
                .inspect_selected_patch(&read),
        )
        .map_err(|_| failure("TEST_INSPECTION_FAILED"))
    })
    .await
    .expect("hold actual read lease for drain test");
    let handle = h.to_owned();
    let token = access.session_token.clone();
    let closing =
        tokio::spawn(async move { api::suspend_recovery_inspection(handle, token).await });
    bounded(async {
        while receipt.snapshot().is_ok() {
            tokio::task::yield_now().await;
        }
    })
    .await;
    assert!(
        !closing.is_finished(),
        "native release must await outstanding inspection lease"
    );
    drop(receipt);
    bounded(closing)
        .await
        .expect("closing task")
        .expect("drained read scope");
    assert!(
        api::inspect_recovery(h.into(), access.session_token.clone())
            .await
            .is_err()
    );
    let second = api::authorize_recovery_inspection(
        h.into(),
        run.run_id.clone(),
        operation,
        "second-inspection".into(),
        workspace.permission_version.clone(),
        root.display().to_string(),
    )
    .await
    .expect("fresh read selection");
    // There is no ordinary WorkspaceSignal at this point. Global revocation
    // must still signal and drain this independently authorized read scope.
    api::revoke_workspace(
        h.into(),
        workspace.workspace_id,
        workspace.permission_version,
    )
    .await
    .expect("revoke workspace without ordinary scope");
    assert!(
        api::inspect_recovery(h.into(), second.session_token)
            .await
            .is_err()
    );
    assert_eq!(model.calls.load(Ordering::SeqCst), 1);
    assert_eq!(
        fs::read(source).expect("no recovery write was granted"),
        b"new\n"
    );
    reopened.handle
}
