use super::*;
pub(super) async fn exercise(h: &str, base: &Path, run: &str, operation: &str, export: &str) {
    let directory = base.join("retention-export-destination");
    let read = api::authorize_export_inspection(
        h.into(),
        run.into(),
        operation.into(),
        export.into(),
        "retirement-read".into(),
        directory.display().to_string(),
    )
    .await
    .expect("read");
    let snapshot = api::inspect_export_files(h.into(), read.session_token.clone())
        .await
        .expect("snapshot");
    let original = fs::read(directory.join(&snapshot.file_name)).expect("bytes");
    assert!(
        api::authorize_export_retirement(
            h.into(),
            read.session_token.clone(),
            read.session_token.clone(),
            directory.display().to_string()
        )
        .await
        .is_err()
    );
    api::suspend_export_retirement(h.into(), "retirement-late".into())
        .await
        .expect("early cancellation");
    assert!(
        api::authorize_export_retirement(
            h.into(),
            read.session_token.clone(),
            "retirement-late".into(),
            directory.display().to_string()
        )
        .await
        .is_err()
    );
    let write = api::authorize_export_retirement(
        h.into(),
        read.session_token.clone(),
        "retirement-write".into(),
        directory.display().to_string(),
    )
    .await
    .expect("write");
    assert!(
        api::suspend_export_inspection(h.into(), write.session_token.clone())
            .await
            .is_err()
    );
    assert!(
        api::suspend_export_destination(h.into(), write.session_token.clone())
            .await
            .is_err()
    );
    let review = api::prepare_export_retirement(
        h.into(),
        write.session_token.clone(),
        "retirement-review".into(),
        "target".into(),
    )
    .await
    .expect("preview");
    assert_eq!(
        fs::read(directory.join(&snapshot.file_name)).expect("no preview effects"),
        original
    );
    assert!(
        api::approve_export_retirement(
            h.into(),
            write.session_token.clone(),
            review.retirement_id.clone(),
            "0".repeat(64)
        )
        .await
        .is_err()
    );
    let review = api::prepare_export_retirement(
        h.into(),
        write.session_token.clone(),
        "retirement-review".into(),
        "target".into(),
    )
    .await
    .expect("same preview");
    // Closing the reader drops cached proofs before drain, including the write permit.
    bounded(api::suspend_export_inspection(h.into(), read.session_token))
        .await
        .expect("drained without deadlock");
    assert!(
        api::approve_export_retirement(
            h.into(),
            write.session_token,
            review.retirement_id.clone(),
            review.digest
        )
        .await
        .is_err()
    );
    assert_eq!(
        fs::read(directory.join(&snapshot.file_name)).expect("no late effects"),
        original
    );
    let read = api::authorize_export_inspection(
        h.into(),
        run.into(),
        operation.into(),
        export.into(),
        "retirement-read-2".into(),
        directory.display().to_string(),
    )
    .await
    .expect("fresh read");
    let write = api::authorize_export_retirement(
        h.into(),
        read.session_token.clone(),
        "retirement-write-2".into(),
        directory.display().to_string(),
    )
    .await
    .expect("fresh write");
    let review = api::prepare_export_retirement(
        h.into(),
        write.session_token.clone(),
        "retirement-review-2".into(),
        "target".into(),
    )
    .await
    .expect("new preview");
    let result = api::approve_export_retirement(
        h.into(),
        write.session_token.clone(),
        review.retirement_id.clone(),
        review.digest.clone(),
    )
    .await
    .expect("capture");
    assert_eq!(result.state, "retained");
    assert!(!directory.join(&snapshot.file_name).exists());
    let capsule = directory.join(format!(
        ".orange-agent-tmp-retired-{}",
        review.retirement_id
    ));
    assert_eq!(
        fs::read(capsule.join("item")).expect("data retained"),
        original
    );
    let inspected = api::inspect_export_retirement(
        h.into(),
        read.session_token.clone(),
        review.retirement_id.clone(),
    )
    .await
    .expect("actual capsule");
    assert!(inspected.capsule_bound);
    assert!(inspected.retained.expect("item").matches_approved_artifact);
    assert_eq!(
        api::inspect_export_outcome(h.into(), run.into(), operation.into(), export.into())
            .await
            .expect("export")
            .expect("record")
            .state,
        "succeeded"
    );
    assert_eq!(
        api::list_export_retirements(
            h.into(),
            run.into(),
            operation.into(),
            export.into(),
            None,
            100
        )
        .await
        .expect("index")
        .len(),
        2
    );
    assert!(
        api::approve_export_retirement(
            h.into(),
            write.session_token,
            review.retirement_id.clone(),
            review.digest
        )
        .await
        .is_err()
    );
    bounded(api::suspend_export_inspection(h.into(), read.session_token))
        .await
        .expect("close");
    super::export_restoration::exercise(h, base, run, operation, export, &review.retirement_id)
        .await;
}
