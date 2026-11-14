use super::*;
pub(super) async fn exercise(h: &str, base: &Path, run: &str, operation: &str, export: &str) {
    let destination = base.join("retention-export-destination");
    api::suspend_export_inspection(h.into(), "late-check".into())
        .await
        .expect("cancel before native callback");
    assert_eq!(
        api::authorize_export_inspection(
            h.into(),
            run.into(),
            operation.into(),
            export.into(),
            "late-check".into(),
            destination.display().to_string()
        )
        .await
        .expect_err("late check refused")
        .code,
        "EXPORT_INSPECTION_CLOSED"
    );
    assert!(
        api::authorize_export_inspection(
            h.into(),
            "wrong-run".into(),
            operation.into(),
            export.into(),
            "wrong-check".into(),
            destination.display().to_string()
        )
        .await
        .is_err()
    );
    assert!(
        api::authorize_export_inspection(
            h.into(),
            run.into(),
            operation.into(),
            export.into(),
            "wrong-directory".into(),
            base.join("recovery-inspection-workspace")
                .display()
                .to_string()
        )
        .await
        .is_err()
    );
    let check = api::authorize_export_inspection(
        h.into(),
        run.into(),
        operation.into(),
        export.into(),
        "independent-check".into(),
        destination.display().to_string(),
    )
    .await
    .expect("source scope closed, destination-only inspection");
    let observed = api::inspect_export_files(h.into(), check.session_token.clone())
        .await
        .expect("actual observation");
    assert_eq!(observed.recorded_state, "succeeded");
    assert!(observed.target.matches_approved_artifact);
    assert!(observed.target.valid_export_document);
    assert_eq!(observed.staged.kind, "missing");
    assert!(
        api::authorize_export_destination(
            h.into(),
            check.session_token.clone(),
            "not-source".into(),
            destination.display().to_string()
        )
        .await
        .is_err()
    );
    assert!(
        api::suspend_export_destination(h.into(), check.session_token.clone())
            .await
            .is_err()
    );
    assert!(
        api::suspend_retention_access(h.into(), check.session_token.clone())
            .await
            .is_err()
    );
    let handle = h.to_owned();
    let token = check.session_token.clone();
    let held = crate::actor::call(handle.clone(), move |registry, rt| {
        let grant = registry
            .signals
            .lock()
            .map_err(|_| failure("HOST_INTERNAL"))?
            .export_checks[&token]
            .grant
            .clone();
        rt.block_on(
            registry
                .current(&handle)?
                .journal
                .inspect_export_files(&grant),
        )
        .map_err(|_| failure("TEST_EXPORT_CHECK_FAILED"))
    })
    .await
    .expect("hold real inspection lease");
    let handle = h.to_owned();
    let token = check.session_token.clone();
    let close = tokio::spawn(async move { api::suspend_export_inspection(handle, token).await });
    bounded(async {
        while held.view().is_ok() {
            tokio::task::yield_now().await;
        }
    })
    .await;
    assert!(
        !close.is_finished(),
        "native release cannot precede inspection drain"
    );
    drop(held);
    bounded(close).await.expect("close task").expect("drained");
    assert!(
        api::inspect_export_files(h.into(), check.session_token)
            .await
            .is_err()
    );
    assert_eq!(
        api::inspect_export_outcome(h.into(), run.into(), operation.into(), export.into())
            .await
            .expect("metadata after closing")
            .expect("receipt")
            .state,
        "succeeded"
    );
}
