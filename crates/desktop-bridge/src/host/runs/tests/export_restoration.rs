use super::*;
pub(super) async fn exercise(
    h: &str,
    base: &Path,
    run: &str,
    operation: &str,
    export: &str,
    retirement: &str,
) {
    let directory = base.join("retention-export-destination");
    let capsule = directory.join(format!(".orange-agent-tmp-retired-{retirement}/item"));
    let bytes = fs::read(&capsule).expect("capsule");
    let read = api::authorize_export_inspection(
        h.into(),
        run.into(),
        operation.into(),
        export.into(),
        "restore-read".into(),
        directory.display().to_string(),
    )
    .await
    .expect("reader");
    api::suspend_export_restoration(h.into(), "restore-late".into())
        .await
        .expect("early close");
    assert!(
        api::authorize_export_restoration(
            h.into(),
            read.session_token.clone(),
            "restore-late".into(),
            directory.display().to_string()
        )
        .await
        .is_err()
    );
    assert!(
        api::authorize_export_restoration(
            h.into(),
            read.session_token.clone(),
            read.session_token.clone(),
            directory.display().to_string()
        )
        .await
        .is_err()
    );
    let write = api::authorize_export_restoration(
        h.into(),
        read.session_token.clone(),
        "restore-write".into(),
        directory.display().to_string(),
    )
    .await
    .expect("write");
    assert!(
        api::suspend_export_retirement(h.into(), write.session_token.clone())
            .await
            .is_err()
    );
    assert!(
        api::suspend_export_destination(h.into(), write.session_token.clone())
            .await
            .is_err()
    );
    assert!(
        api::suspend_export_inspection(h.into(), write.session_token.clone())
            .await
            .is_err()
    );
    assert!(
        api::prepare_export_restoration(
            h.into(),
            write.session_token.clone(),
            "wrong-parent".into(),
            "not-owned".into(),
            "recovered.orange-retained.json".into()
        )
        .await
        .is_err()
    );
    let review = api::prepare_export_restoration(
        h.into(),
        write.session_token.clone(),
        "restore-one".into(),
        retirement.into(),
        "recovered.orange-retained.json".into(),
    )
    .await
    .expect("preview");
    assert_eq!(review.retirement_id, retirement);
    assert!(!directory.join(&review.file_name).exists());
    assert!(
        api::approve_export_restoration(
            h.into(),
            write.session_token.clone(),
            review.restoration_id.clone(),
            "0".repeat(64)
        )
        .await
        .is_err()
    );
    let review = api::prepare_export_restoration(
        h.into(),
        write.session_token.clone(),
        "restore-one".into(),
        retirement.into(),
        "recovered.orange-retained.json".into(),
    )
    .await
    .expect("same preview");
    bounded(api::suspend_export_inspection(h.into(), read.session_token))
        .await
        .expect("drop cached restoration permits before reader drain");
    assert!(
        api::approve_export_restoration(
            h.into(),
            write.session_token,
            review.restoration_id,
            review.digest
        )
        .await
        .is_err()
    );
    assert!(!directory.join("recovered.orange-retained.json").exists());
    let read = api::authorize_export_inspection(
        h.into(),
        run.into(),
        operation.into(),
        export.into(),
        "restore-read-2".into(),
        directory.display().to_string(),
    )
    .await
    .expect("new reader");
    let write = api::authorize_export_restoration(
        h.into(),
        read.session_token.clone(),
        "restore-write-2".into(),
        directory.display().to_string(),
    )
    .await
    .expect("new writer");
    let review = api::prepare_export_restoration(
        h.into(),
        write.session_token.clone(),
        "restore-two".into(),
        retirement.into(),
        "recovered.orange-retained.json".into(),
    )
    .await
    .expect("new preview");
    let result = api::approve_export_restoration(
        h.into(),
        write.session_token.clone(),
        review.restoration_id.clone(),
        review.digest.clone(),
    )
    .await
    .expect("copy published");
    assert_eq!(result.state, "succeeded");
    assert_eq!(
        fs::read(directory.join(&review.file_name)).expect("restored"),
        bytes
    );
    assert_eq!(fs::read(&capsule).expect("original remains"), bytes);
    let inspected = api::inspect_export_restoration(
        h.into(),
        read.session_token.clone(),
        review.restoration_id.clone(),
    )
    .await
    .expect("actual copy");
    assert!(inspected.target.matches_approved_artifact);
    assert_eq!(inspected.staged.kind, "missing");
    assert!(
        api::approve_export_restoration(
            h.into(),
            write.session_token.clone(),
            review.restoration_id,
            review.digest
        )
        .await
        .is_err()
    );
    assert!(
        api::prepare_export_restoration(
            h.into(),
            write.session_token.clone(),
            "overwrite".into(),
            retirement.into(),
            "recovered.orange-retained.json".into()
        )
        .await
        .is_err()
    );
    let database =
        rusqlite::Connection::open(base.join("private/host.sqlite")).expect("owned database");
    database.execute_batch("CREATE TRIGGER restoration_receipt_fault BEFORE INSERT ON events WHEN NEW.kind='patch.export_restoration_completed' BEGIN SELECT RAISE(ABORT,'owned receipt fault');END;").expect("install fault");
    drop(database);
    let review = api::prepare_export_restoration(
        h.into(),
        write.session_token.clone(),
        "restore-receipt-failure".into(),
        retirement.into(),
        "unconfirmed.orange-retained.json".into(),
    )
    .await
    .expect("fault preview");
    assert!(
        api::approve_export_restoration(
            h.into(),
            write.session_token.clone(),
            review.restoration_id.clone(),
            review.digest
        )
        .await
        .is_err()
    );
    assert_eq!(
        fs::read(directory.join(&review.file_name)).expect("effect retained"),
        bytes
    );
    let records = api::list_export_restorations(
        h.into(),
        run.into(),
        operation.into(),
        retirement.into(),
        None,
        100,
    )
    .await
    .expect("metadata");
    assert_eq!(records.len(), 3);
    assert_eq!(
        records
            .iter()
            .find(|v| v.restoration_id == review.restoration_id)
            .expect("unknown")
            .state,
        "unknown"
    );
    let inspected = api::inspect_export_restoration(
        h.into(),
        read.session_token.clone(),
        review.restoration_id,
    )
    .await
    .expect("unknown actual files");
    assert!(inspected.target.matches_approved_artifact);
    assert_eq!(inspected.recorded_state, "unknown");
    bounded(api::suspend_export_inspection(h.into(), read.session_token))
        .await
        .expect("close");
    assert_eq!(fs::read(capsule).expect("no erasure"), bytes);
}
