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
    assert!(
        api::list_retained_edits(h.into(), run.run_id.clone(), None, 10)
            .await
            .expect("unknown not eligible for archival")
            .is_empty()
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
    assert_eq!(
        api::authorize_recovery_write_access(
            h.into(),
            access.session_token.clone(),
            access.session_token.clone(),
            root.display().to_string()
        )
        .await
        .expect_err("read selection cannot become write consent")
        .code,
        "RECOVERY_SELECTION_CONFLICT"
    );
    api::suspend_recovery_write_selection(h.into(), "closed-recovery-write".into())
        .await
        .expect("close lost write callback");
    assert!(
        api::authorize_recovery_write_access(
            h.into(),
            access.session_token.clone(),
            "closed-recovery-write".into(),
            root.display().to_string()
        )
        .await
        .is_err()
    );
    assert!(
        api::authorize_recovery_write_access(
            h.into(),
            access.session_token.clone(),
            "wrong-recovery-write-root".into(),
            base.display().to_string()
        )
        .await
        .is_err()
    );
    let first_write = api::authorize_recovery_write_access(
        h.into(),
        access.session_token.clone(),
        "recovery-write-1".into(),
        root.display().to_string(),
    )
    .await
    .expect("separate write selection");
    assert_eq!(first_write.read_session_token, access.session_token);
    assert!(
        api::suspend_recovery_inspection(h.into(), first_write.session_token.clone())
            .await
            .is_err(),
        "wrong release kind must not stop a live writer"
    );
    assert!(
        api::suspend_recovery_write_selection(h.into(), access.session_token.clone())
            .await
            .is_err(),
        "write release must not stop read authority"
    );
    api::suspend_recovery_write_selection(h.into(), first_write.session_token.clone())
        .await
        .expect("close just write scope");
    assert!(
        api::inspect_recovery(h.into(), access.session_token.clone())
            .await
            .is_ok(),
        "read scope remains independent"
    );
    let dependent_write = api::authorize_recovery_write_access(
        h.into(),
        access.session_token.clone(),
        "recovery-write-2".into(),
        root.display().to_string(),
    )
    .await
    .expect("writer bound to read lifetime");
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
    assert!(
        api::authorize_recovery_write_access(
            h.into(),
            access.session_token.clone(),
            dependent_write.session_token,
            root.display().to_string()
        )
        .await
        .is_err(),
        "closed parent cannot restore child write"
    );
    let second = api::authorize_recovery_inspection(
        h.into(),
        run.run_id.clone(),
        operation.clone(),
        "second-inspection".into(),
        workspace.permission_version.clone(),
        root.display().to_string(),
    )
    .await
    .expect("fresh read selection");
    let global_write = api::authorize_recovery_write_access(
        h.into(),
        second.session_token.clone(),
        "recovery-write-3".into(),
        root.display().to_string(),
    )
    .await
    .expect("independent scope under workspace revocation");
    let before_revoke = api::prepare_recovery_decision(
        h.into(),
        second.session_token.clone(),
        global_write.session_token.clone(),
        "before-global-revoke".into(),
        "keep_current_target".into(),
    )
    .await
    .expect("actual decision preview");
    assert!(before_revoke.inspection.target.matches_result_content);
    // There is no ordinary WorkspaceSignal at this point. Global revocation
    // must still signal and drain this independently authorized read scope.
    let revoked = api::revoke_workspace(
        h.into(),
        workspace.workspace_id,
        workspace.permission_version,
    )
    .await
    .expect("revoke workspace without ordinary scope");
    assert!(
        api::inspect_recovery(h.into(), second.session_token.clone())
            .await
            .is_err()
    );
    assert!(
        api::approve_recovery_decision(
            h.into(),
            second.session_token,
            global_write.session_token.clone(),
            before_revoke.recovery_id,
            before_revoke.digest
        )
        .await
        .is_err(),
        "revoked preview cannot execute"
    );
    api::suspend_recovery_write_selection(h.into(), global_write.session_token)
        .await
        .expect("workspace revoke drained writer too");
    let outcome = api::inspect_recovery_outcome(h.into(), run.run_id.clone(), operation.clone())
        .await
        .expect("metadata after all file scopes revoked");
    assert_eq!(outcome.run_id, run.run_id);
    assert_eq!(outcome.operation_id, operation);
    assert_eq!(outcome.original_execution_state, "unknown");
    assert!(outcome.recovery_id.is_none() && outcome.choice.is_none());
    assert!(
        api::inspect_recovery_outcome(h.into(), "other-run".into(), operation.clone())
            .await
            .is_err()
    );
    let read_again = api::authorize_recovery_inspection(
        h.into(),
        run.run_id.clone(),
        operation.clone(),
        "decision-read-after-revoke".into(),
        revoked.permission_version.clone(),
        root.display().to_string(),
    )
    .await
    .expect("new explicit recovery read consent");
    let write_again = api::authorize_recovery_write_access(
        h.into(),
        read_again.session_token.clone(),
        "decision-write-after-revoke".into(),
        root.display().to_string(),
    )
    .await
    .expect("separate new write consent");
    let first = api::prepare_recovery_decision(
        h.into(),
        read_again.session_token.clone(),
        write_again.session_token.clone(),
        "first-current-decision".into(),
        "keep_current_target".into(),
    )
    .await
    .expect("first review");
    let current = api::prepare_recovery_decision(
        h.into(),
        read_again.session_token.clone(),
        write_again.session_token.clone(),
        "current-decision".into(),
        "keep_current_target".into(),
    )
    .await
    .expect("replacement review");
    assert_eq!(
        api::approve_recovery_decision(
            h.into(),
            read_again.session_token.clone(),
            write_again.session_token.clone(),
            first.recovery_id,
            first.digest
        )
        .await
        .expect_err("superseded view refused")
        .code,
        "RECOVERY_PREVIEW_CHANGED"
    );
    assert!(
        api::approve_recovery_decision(
            h.into(),
            read_again.session_token.clone(),
            write_again.session_token.clone(),
            current.recovery_id.clone(),
            "0".repeat(64)
        )
        .await
        .is_err()
    );
    let completed = api::approve_recovery_decision(
        h.into(),
        read_again.session_token.clone(),
        write_again.session_token.clone(),
        current.recovery_id.clone(),
        current.digest.clone(),
    )
    .await
    .expect("exact current decision approval");
    assert_eq!(
        completed.recovery_id.as_deref(),
        Some(current.recovery_id.as_str())
    );
    assert_eq!(completed.choice.as_deref(), Some("keep_current_target"));
    assert_eq!(completed.original_execution_state, "unknown");
    assert!(
        api::approve_recovery_decision(
            h.into(),
            read_again.session_token.clone(),
            write_again.session_token.clone(),
            current.recovery_id.clone(),
            current.digest
        )
        .await
        .is_err(),
        "no action replay"
    );
    api::suspend_recovery_inspection(h.into(), read_again.session_token)
        .await
        .expect("release read and write");
    api::suspend_recovery_write_selection(h.into(), write_again.session_token)
        .await
        .expect("idempotent physical write release barrier");
    let saved = api::inspect_recovery_outcome(h.into(), run.run_id.clone(), operation.clone())
        .await
        .expect("lost reply reconciled without file access");
    assert_eq!(saved.recovery_id, completed.recovery_id);
    assert_eq!(
        api::list_retained_edits(h.into(), run.run_id.clone(), None, 10)
            .await
            .expect("resolved retention metadata"),
        vec![operation.clone()]
    );
    assert!(
        api::list_retained_edits(h.into(), run.run_id.clone(), Some(operation.clone()), 1)
            .await
            .expect("strict cursor")
            .is_empty()
    );
    assert!(
        api::list_retained_edits(h.into(), "foreign-run".into(), None, 10)
            .await
            .is_err()
    );
    assert!(
        api::list_retained_edits(h.into(), run.run_id.clone(), None, 101)
            .await
            .is_err()
    );
    assert!(
        api::inspect_retention_outcome(h.into(), "foreign-run".into(), operation.clone())
            .await
            .is_err()
    );
    assert!(
        api::inspect_retention_outcome(h.into(), run.run_id.clone(), operation.clone())
            .await
            .expect("not archived")
            .is_none()
    );
    api::suspend_retention_access(h.into(), "late-retention".into())
        .await
        .expect("cancel selection first");
    assert_eq!(
        api::authorize_retention_access(
            h.into(),
            run.run_id.clone(),
            operation.clone(),
            "late-retention".into(),
            revoked.permission_version.clone(),
            root.display().to_string()
        )
        .await
        .expect_err("late native callback refused")
        .code,
        "RETENTION_SELECTION_CLOSED"
    );
    assert!(
        api::authorize_retention_access(
            h.into(),
            run.run_id.clone(),
            operation.clone(),
            "wrong-version-retention".into(),
            "999".into(),
            root.display().to_string()
        )
        .await
        .is_err()
    );
    let access = api::authorize_retention_access(
        h.into(),
        run.run_id.clone(),
        operation.clone(),
        "retention-reader".into(),
        revoked.permission_version.clone(),
        root.display().to_string(),
    )
    .await
    .expect("separate read selection for management");
    let before = api::inspect_retention(h.into(), access.session_token.clone())
        .await
        .expect("actual retained observation and reservations");
    assert_eq!(
        (before.resource_active_records, before.owner_archive_records),
        (1, 0)
    );
    assert!(before.original.matches_original_content);
    assert!(before.archived_review_id.is_none());
    assert!(
        api::authorize_recovery_write_access(
            h.into(),
            access.session_token.clone(),
            "not-a-writer".into(),
            root.display().to_string()
        )
        .await
        .is_err()
    );
    assert!(
        api::suspend_recovery_inspection(h.into(), access.session_token.clone())
            .await
            .is_err()
    );
    let old = api::prepare_retention_archive(
        h.into(),
        access.session_token.clone(),
        "old-retention-review".into(),
    )
    .await
    .expect("first preview");
    let replacement = api::prepare_retention_archive(
        h.into(),
        access.session_token.clone(),
        "replacement-retention-review".into(),
    )
    .await
    .expect("replacement preview");
    assert!(
        api::approve_retention_archive(
            h.into(),
            access.session_token.clone(),
            old.review_id,
            old.digest
        )
        .await
        .is_err()
    );
    assert!(
        api::approve_retention_archive(
            h.into(),
            access.session_token.clone(),
            replacement.review_id,
            replacement.digest
        )
        .await
        .is_err(),
        "attempt consumes the displayed preview"
    );
    let preview = api::prepare_retention_archive(
        h.into(),
        access.session_token.clone(),
        "exact-retention-review".into(),
    )
    .await
    .expect("fresh preview");
    let review_id = api::approve_retention_archive(
        h.into(),
        access.session_token.clone(),
        preview.review_id.clone(),
        preview.digest.clone(),
    )
    .await
    .expect("explicit exact archive confirmation");
    assert_eq!(review_id, preview.review_id);
    assert!(
        api::approve_retention_archive(
            h.into(),
            access.session_token.clone(),
            preview.review_id,
            preview.digest
        )
        .await
        .is_err(),
        "bridge does not replay an approval"
    );
    let after = api::inspect_retention(h.into(), access.session_token.clone())
        .await
        .expect("archived observation");
    assert_eq!(
        (after.resource_active_records, after.owner_archive_records),
        (0, 1)
    );
    assert_eq!(after.changed_since_archival, Some(false));
    assert_eq!(after.archived_review_id, Some(review_id.clone()));
    let handle = h.to_owned();
    let token = access.session_token.clone();
    let receipt = crate::actor::call(handle.clone(), move |registry, rt| {
        let grant = registry
            .signals
            .lock()
            .map_err(|_| failure("HOST_INTERNAL"))?
            .retentions[&token]
            .grant
            .clone();
        rt.block_on(
            registry
                .current(&handle)?
                .journal
                .inspect_selected_retention(&grant),
        )
        .map_err(|_| failure("TEST_RETENTION_FAILED"))
    })
    .await
    .expect("hold real read lease");
    let handle = h.to_owned();
    let token = access.session_token.clone();
    let closing = tokio::spawn(async move { api::suspend_retention_access(handle, token).await });
    bounded(async {
        while receipt.snapshot().is_ok() {
            tokio::task::yield_now().await;
        }
    })
    .await;
    assert!(
        !closing.is_finished(),
        "native release waits for retention read lease"
    );
    drop(receipt);
    bounded(closing)
        .await
        .expect("closing task")
        .expect("drained");
    assert!(
        api::inspect_retention(h.into(), access.session_token)
            .await
            .is_err()
    );
    assert_eq!(
        api::inspect_retention_outcome(h.into(), run.run_id.clone(), operation.clone())
            .await
            .expect("lost response lookup after scope release"),
        Some(review_id)
    );
    assert_eq!(
        api::list_retained_edits(h.into(), run.run_id.clone(), None, 10)
            .await
            .expect("archived remains discoverable"),
        vec![operation]
    );
    assert!(
        api::list_unresolved_edits(h.into(), run.run_id.clone(), None, 10)
            .await
            .expect("resolved index")
            .is_empty()
    );
    assert!(
        api::list_runs(h.into(), None, None, 100)
            .await
            .expect("metadata")
            .runs
            .iter()
            .any(|r| r.run_id == run.run_id && r.phase != "completed")
    );
    assert_eq!(model.calls.load(Ordering::SeqCst), 1);
    assert_eq!(
        fs::read(source).expect("no recovery write was granted"),
        b"new\n"
    );
    reopened.handle
}
