use super::*;
use crate::api::memory as mem;
fn select(token: &str) -> mem::MemorySelection {
    mem::MemorySelection {
        scope_id: "personal-memory".into(),
        session_token: token.into(),
        sources: mem::MemorySources {
            workspace_ids: vec![],
            memory_tokens: vec![],
        },
    }
}
fn edit(request: &str, version: Option<&str>, enabled: bool) -> mem::MemoryEdit {
    mem::MemoryEdit {
        request_id: request.into(),
        entry_id: "note".into(),
        expected_version: version.map(str::to_owned),
        delete: false,
        title: Some("Tea preference".into()),
        content: Some("Jasmine tea".into()),
        enabled: Some(enabled),
    }
}
pub(super) async fn exercise(h: &str) {
    let h = h.to_owned();
    let scope = mem::create_scope(h.clone(), "personal-memory".into(), false)
        .await
        .expect("scope");
    assert!(scope.can_administer && scope.enabled && scope.session_token.is_none());
    assert_eq!(
        mem::create_scope(h.clone(), "personal-memory".into(), false)
            .await
            .expect("idempotent")
            .revision,
        scope.revision
    );
    mem::suspend_access(h.clone(), "closed-before-authorization".into())
        .await
        .expect("known token closed first");
    assert!(
        mem::authorize_scope(
            h.clone(),
            scope.scope_id.clone(),
            scope.revision.clone(),
            "closed-before-authorization".into(),
            true
        )
        .await
        .is_err()
    );
    let read = mem::authorize_scope(
        h.clone(),
        scope.scope_id.clone(),
        scope.revision.clone(),
        "memory-read".into(),
        false,
    )
    .await
    .expect("read grant");
    assert!(!read.write);
    assert!(
        mem::prepare_edit(
            h.clone(),
            select(&read.session_token),
            edit("read-cannot-write", None, true)
        )
        .await
        .is_err()
    );
    assert!(
        mem::inspect_edit(
            h.clone(),
            scope.scope_id.clone(),
            "read-cannot-write".into()
        )
        .await
        .expect("no draft")
        .is_none()
    );
    mem::suspend_access(h.clone(), read.session_token.clone())
        .await
        .expect("release read");
    let write = mem::authorize_scope(
        h.clone(),
        scope.scope_id.clone(),
        scope.revision.clone(),
        "memory-write".into(),
        true,
    )
    .await
    .expect("write grant");
    let selection = select(&write.session_token);
    let preview = mem::prepare_edit(
        h.clone(),
        selection.clone(),
        edit("human-create", None, true),
    )
    .await
    .expect("preview");
    assert!(preview.prior.is_none());
    assert_eq!(preview.content.as_deref(), Some("Jasmine tea"));
    assert!(
        mem::list_entries(h.clone(), selection.clone(), None, 10, false)
            .await
            .expect("uncommitted empty")
            .entries
            .is_empty()
    );
    assert!(
        mem::approve_edit(
            h.clone(),
            selection.clone(),
            preview.draft_id.clone(),
            "0".repeat(64)
        )
        .await
        .is_err()
    );
    let receipt = mem::approve_edit(
        h.clone(),
        selection.clone(),
        preview.draft_id.clone(),
        preview.approval_digest.clone(),
    )
    .await
    .expect("exact approve");
    assert_eq!(receipt.result_version.as_deref(), Some("1"));
    assert!(
        mem::approve_edit(
            h.clone(),
            selection.clone(),
            preview.draft_id,
            preview.approval_digest
        )
        .await
        .is_err()
    );
    let value = mem::read_entry(
        h.clone(),
        selection.clone(),
        "note".into(),
        Some("1".into()),
        0,
        4096,
        false,
    )
    .await
    .expect("actual read");
    assert_eq!(value.content, "Jasmine tea");
    assert_eq!(value.origin, "user_declaration");
    let delivery = crate::actor::memory::capture(&h, &selection).expect("live response fence");
    let observe_handle = h.clone();
    let observation = crate::actor::call(h.clone(), move |registry, _| {
        Ok(
            registry.current(&observe_handle)?.memories["personal-memory"]
                .grant
                .clone(),
        )
    })
    .await
    .expect("test-only observation");
    let entered = Arc::new(Notify::new());
    let release = Arc::new(Notify::new());
    let pause = release.clone();
    let signal = entered.clone();
    let owned = h.clone();
    let holding = tokio::spawn(crate::actor::call(h.clone(), move |registry, rt| {
        rt.block_on(async move {
            let host = registry.current(&owned)?;
            let grant = host.memories["personal-memory"].grant.clone();
            let receipt = host
                .journal
                .read_memory_verified(
                    orange_agent_runtime::engine::MemoryManagementAuthority::new(&grant),
                    orange_agent_runtime::engine::MemoryReadSelection {
                        entry_id: "note".into(),
                        expected_version: Some("1".into()),
                        start_byte: 0,
                        max_bytes: 4096,
                        include_disabled: false,
                    },
                )
                .await
                .map_err(engine_error)?;
            signal.notify_one();
            pause.notified().await;
            assert!(receipt.view(&host.journal).is_err());
            drop(receipt);
            Ok(())
        })
    }));
    tokio::time::timeout(Duration::from_secs(2), entered.notified())
        .await
        .expect("actual receipt held");
    let release_handle = h.clone();
    let token = write.session_token.clone();
    let releasing = tokio::spawn(async move { mem::suspend_access(release_handle, token).await });
    tokio::time::timeout(Duration::from_secs(2), async {
        while !observation.is_revoked() {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("signal precedes queued actor work");
    assert!(delivery.check().is_err());
    assert!(!releasing.is_finished());
    assert!(
        tokio::time::timeout(Duration::from_millis(20), observation.wait_drained())
            .await
            .is_err()
    );
    release.notify_one();
    bounded(holding)
        .await
        .expect("actor task")
        .expect("receipt stopped");
    bounded(releasing)
        .await
        .expect("release task")
        .expect("actual drain");
    assert!(
        mem::read_entry(h.clone(), selection, "note".into(), None, 0, 4096, false)
            .await
            .is_err()
    );
    assert_eq!(
        mem::inspect_edit(h.clone(), scope.scope_id.clone(), "human-create".into())
            .await
            .expect("lost reply metadata")
            .expect("receipt")
            .state,
        "approved"
    );
    let write = mem::authorize_scope(
        h.clone(),
        scope.scope_id.clone(),
        scope.revision.clone(),
        "memory-write-restored".into(),
        true,
    )
    .await
    .expect("explicit restore");
    let selection = select(&write.session_token);
    let update = mem::prepare_edit(
        h.clone(),
        selection.clone(),
        edit("human-disable-entry", Some("1"), false),
    )
    .await
    .expect("update preview");
    assert_eq!(update.prior.as_ref().expect("prior").version, "1");
    mem::approve_edit(
        h.clone(),
        selection.clone(),
        update.draft_id,
        update.approval_digest,
    )
    .await
    .expect("disable entry");
    assert!(
        mem::list_entries(h.clone(), selection.clone(), None, 10, false)
            .await
            .expect("active only")
            .entries
            .is_empty()
    );
    assert_eq!(
        mem::list_entries(h.clone(), selection.clone(), None, 10, true)
            .await
            .expect("explicit disabled entry")
            .entries
            .len(),
        1
    );
    let disabled = mem::set_scope_enabled(h.clone(), scope.scope_id.clone(), scope.revision, false)
        .await
        .expect("disable scope");
    assert!(!disabled.enabled && disabled.session_token.is_none());
    assert!(
        mem::authorize_scope(
            h.clone(),
            scope.scope_id.clone(),
            disabled.revision.clone(),
            "disabled-scope".into(),
            false
        )
        .await
        .is_err()
    );
    assert_eq!(
        mem::inspect_edit(
            h.clone(),
            scope.scope_id.clone(),
            "human-disable-entry".into()
        )
        .await
        .expect("metadata while disabled")
        .expect("receipt")
        .result_version
        .as_deref(),
        Some("2")
    );
    let enabled =
        mem::set_scope_enabled(h.clone(), scope.scope_id.clone(), disabled.revision, true)
            .await
            .expect("enable metadata");
    assert!(enabled.session_token.is_none());
    let active = mem::authorize_scope(
        h.clone(),
        scope.scope_id.clone(),
        enabled.revision,
        "memory-delete".into(),
        true,
    )
    .await
    .expect("new explicit grant");
    let selected = select(&active.session_token);
    let delete = mem::prepare_edit(
        h.clone(),
        selected.clone(),
        mem::MemoryEdit {
            request_id: "human-delete".into(),
            entry_id: "note".into(),
            expected_version: Some("2".into()),
            delete: true,
            title: None,
            content: None,
            enabled: None,
        },
    )
    .await
    .expect("delete disabled entry preview");
    mem::approve_edit(
        h.clone(),
        selected.clone(),
        delete.draft_id,
        delete.approval_digest,
    )
    .await
    .expect("delete");
    assert!(
        mem::read_entry(h.clone(), selected, "note".into(), None, 0, 4096, true)
            .await
            .is_err()
    );
    let shared = mem::create_scope(h.clone(), "shared-memory".into(), true)
        .await
        .expect("shared scope");
    let shared = mem::set_member(
        h.clone(),
        shared.scope_id.clone(),
        shared.revision,
        "collaborator".into(),
        "read".into(),
    )
    .await
    .expect("explicit member");
    assert!(
        mem::list_members(h.clone(), shared.scope_id.clone(), "1".into(), None, 64)
            .await
            .is_err()
    );
    let members = mem::list_members(
        h.clone(),
        shared.scope_id.clone(),
        shared.revision.clone(),
        None,
        64,
    )
    .await
    .expect("owner directory");
    assert!(
        members
            .members
            .iter()
            .any(|m| m.principal == "collaborator" && m.access == "read")
    );
    let shared = mem::set_member(
        h.clone(),
        shared.scope_id.clone(),
        shared.revision,
        "collaborator".into(),
        "revoked".into(),
    )
    .await
    .expect("revoke member");
    assert!(
        mem::list_members(h.clone(), shared.scope_id, shared.revision, None, 64)
            .await
            .expect("retained explicit revocation")
            .members
            .iter()
            .any(|m| m.principal == "collaborator" && m.access == "revoked")
    );
    let scopes = mem::list_scopes(h, None, 100).await.expect("directory");
    assert!(
        scopes
            .scopes
            .iter()
            .any(|s| s.scope_id == "personal-memory" && s.can_administer)
    );
}
