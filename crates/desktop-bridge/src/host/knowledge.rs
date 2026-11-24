use super::{Host, failure};
use crate::api::{
    host::BridgeError,
    knowledge::{KnowledgeHit, KnowledgePage, KnowledgePassage, KnowledgeSelection},
};
use orange_agent_runtime::workspace::{
    WorkspaceError, WorkspaceGrant,
    knowledge::{
        Hit, KnowledgeCollection, KnowledgeError, KnowledgeRequest, KnowledgeResult, Read,
        SavedKnowledgeError, Search,
    },
};
use orange_protocol::valid_id;

pub(super) struct Session {
    selection: KnowledgeSelection,
    paths: Vec<String>,
    name: Option<String>,
    collection: KnowledgeCollection,
}
fn mapped(e: KnowledgeError) -> BridgeError {
    failure(match e {
        KnowledgeError::Invalid | KnowledgeError::Workspace(WorkspaceError::Invalid) => {
            "KNOWLEDGE_REQUEST_INVALID"
        }
        KnowledgeError::Stale | KnowledgeError::Workspace(WorkspaceError::VersionChanged) => {
            "KNOWLEDGE_CITATION_STALE"
        }
        KnowledgeError::Workspace(
            WorkspaceError::Forbidden
            | WorkspaceError::Revoked
            | WorkspaceError::EnvironmentChanged,
        ) => "KNOWLEDGE_ACCESS_DENIED",
        KnowledgeError::Workspace(
            WorkspaceError::Timeout | WorkspaceError::FileTooLarge | WorkspaceError::Limit,
        ) => "KNOWLEDGE_LIMIT",
        _ => "KNOWLEDGE_UNAVAILABLE",
    })
}
fn active<'a>(host: &'a Host, s: &KnowledgeSelection) -> Result<&'a WorkspaceGrant, BridgeError> {
    if !valid_id(&s.collection_id) {
        return Err(failure("KNOWLEDGE_ACCESS_DENIED"));
    }
    active_workspace(host, &s.workspace_id, &s.session_token)
}
fn active_workspace<'a>(
    host: &'a Host,
    workspace: &str,
    token: &str,
) -> Result<&'a WorkspaceGrant, BridgeError> {
    if !valid_id(workspace)
        || !valid_id(token)
        || host.access_tokens.get(workspace).map(String::as_str) != Some(token)
    {
        return Err(failure("KNOWLEDGE_ACCESS_DENIED"));
    }
    host.grants
        .get(workspace)
        .filter(|g| !g.is_revoked())
        .ok_or_else(|| failure("KNOWLEDGE_ACCESS_DENIED"))
}
fn saved_error(error: SavedKnowledgeError) -> BridgeError {
    match error {
        SavedKnowledgeError::Retired => failure("KNOWLEDGE_NAME_RETIRED"),
        SavedKnowledgeError::Workspace(_) => failure("KNOWLEDGE_ACCESS_DENIED"),
        SavedKnowledgeError::Knowledge(KnowledgeError::Busy) => {
            failure("KNOWLEDGE_COLLECTION_BUSY")
        }
        SavedKnowledgeError::Knowledge(e) => mapped(e),
        SavedKnowledgeError::Metadata(_) => failure("KNOWLEDGE_UNAVAILABLE"),
    }
}
fn bound<'a>(
    host: &'a Host,
    s: &KnowledgeSelection,
) -> Result<(&'a WorkspaceGrant, &'a KnowledgeCollection), BridgeError> {
    let grant = active(host, s)?;
    let session = host
        .knowledge
        .get(&s.collection_id)
        .filter(|v| v.selection == *s)
        .ok_or_else(|| failure("KNOWLEDGE_COLLECTION_CLOSED"))?;
    Ok((grant, &session.collection))
}
pub(super) fn forget_workspace(host: &mut Host, id: &str) {
    let closed = &mut host.closed_knowledge;
    host.knowledge.retain(|key, session| {
        if session.selection.workspace_id == id {
            closed.insert(key.clone());
            false
        } else {
            true
        }
    });
}
pub(crate) async fn open(
    handle: String,
    selection: KnowledgeSelection,
    mut paths: Vec<String>,
    name: Option<String>,
) -> Result<(), BridgeError> {
    crate::actor::call(handle.clone(), move |r, _| {
        let h = r.current(&handle)?;
        let grant = active(h, &selection)?.clone();
        if paths.is_empty() || paths.len() > 32 {
            return Err(failure("KNOWLEDGE_REQUEST_INVALID"));
        }
        paths.sort();
        if h.closed_knowledge.contains(&selection.collection_id) {
            return Err(failure("KNOWLEDGE_COLLECTION_CLOSED"));
        }
        if let Some(old) = h.knowledge.get(&selection.collection_id) {
            return if old.selection == selection && old.paths == paths && old.name == name {
                Ok(())
            } else {
                Err(failure("KNOWLEDGE_SELECTION_CONFLICT"))
            };
        }
        if h.knowledge.len() >= 8 || h.knowledge.len() + h.closed_knowledge.len() >= 8192 {
            return Err(failure("KNOWLEDGE_LIMIT"));
        }
        let collection = if let Some(name) = &name {
            h.journal
                .open_saved_knowledge(&selection.workspace_id, &grant, name, paths.clone())
                .map_err(saved_error)?
        } else {
            KnowledgeCollection::open(grant, &selection.collection_id, paths.clone())
                .map_err(mapped)?
        };
        h.knowledge.insert(
            selection.collection_id.clone(),
            Session {
                selection,
                paths,
                name,
                collection,
            },
        );
        Ok(())
    })
    .await
}
fn hit(h: Hit) -> KnowledgeHit {
    KnowledgeHit {
        hit_id: h.hit_id,
        path: h.path,
        source_sha256: h.source_sha256,
        start_byte: h.start_byte,
        end_byte: h.end_byte,
    }
}
pub(crate) async fn search(
    handle: String,
    selection: KnowledgeSelection,
    query: String,
    path: Option<String>,
    limit: u32,
) -> Result<KnowledgePage, BridgeError> {
    crate::actor::call(handle.clone(), move |r, rt| {
        let (g, collection) = bound(r.current(&handle)?, &selection)?;
        let req = KnowledgeRequest::KnowledgeSearch(Search {
            collection_id: collection.collection_id().to_owned(),
            query,
            path,
            limit: Some(limit as usize),
        });
        rt.block_on(
            collection.execute(g.owner(), g.environment(), g.policy(), req, |response| {
                match response {
                    KnowledgeResult::KnowledgeSearch {
                        hits,
                        truncated,
                        unavailable_sources,
                        ..
                    } => Ok(KnowledgePage {
                        hits: hits.into_iter().map(hit).collect(),
                        truncated,
                        unavailable_sources: u32::try_from(unavailable_sources)
                            .map_err(|_| failure("KNOWLEDGE_UNAVAILABLE"))?,
                    }),
                    _ => Err(failure("KNOWLEDGE_UNAVAILABLE")),
                }
            }),
        )
        .map_err(mapped)?
    })
    .await
}
pub(crate) async fn read(
    handle: String,
    selection: KnowledgeSelection,
    hit_id: String,
    expected_sha256: String,
    start: Option<u32>,
    end: Option<u32>,
) -> Result<KnowledgePassage, BridgeError> {
    crate::actor::call(handle.clone(), move |r, rt| {
        let (g, collection) = bound(r.current(&handle)?, &selection)?;
        let req = KnowledgeRequest::KnowledgeRead(Read {
            collection_id: collection.collection_id().to_owned(),
            hit_id,
            expected_sha256,
            start_byte: start.map(|n| n as usize),
            end_byte: end.map(|n| n as usize),
        });
        rt.block_on(
            collection.execute(g.owner(), g.environment(), g.policy(), req, |response| {
                match response {
                    KnowledgeResult::KnowledgeRead {
                        citation,
                        start_byte,
                        end_byte,
                        text,
                    } => Ok(KnowledgePassage {
                        citation: hit(citation),
                        start_byte,
                        end_byte,
                        text,
                    }),
                    _ => Err(failure("KNOWLEDGE_UNAVAILABLE")),
                }
            }),
        )
        .map_err(mapped)?
    })
    .await
}
pub(crate) async fn close(
    handle: String,
    selection: KnowledgeSelection,
) -> Result<(), BridgeError> {
    crate::actor::call(handle.clone(), move |r, _| {
        let host = r.current(&handle)?;
        if let Some(s) = host.knowledge.get(&selection.collection_id)
            && s.selection != selection
        {
            return Err(failure("KNOWLEDGE_ACCESS_DENIED"));
        }
        if host.knowledge.remove(&selection.collection_id).is_some() {
            host.closed_knowledge.insert(selection.collection_id);
        } else if !host.closed_knowledge.contains(&selection.collection_id)
            && active(host, &selection).is_ok()
        {
            // A release can reach the actor before an in-flight selection. Reuse the
            // existing host quota without ever evicting an acknowledged close.
            if host.closed_knowledge.len() + host.knowledge.len() >= 8192 {
                return Err(failure("KNOWLEDGE_LIMIT"));
            }
            host.closed_knowledge.insert(selection.collection_id);
        }
        Ok(())
    })
    .await
}

pub(crate) async fn saved_names(
    handle: String,
    workspace: String,
    token: String,
) -> Result<Vec<String>, BridgeError> {
    crate::actor::call(handle.clone(), move |r, _| {
        let h = r.current(&handle)?;
        let grant = active_workspace(h, &workspace, &token)?;
        h.journal
            .saved_knowledge_names(&workspace, grant)
            .map_err(saved_error)
    })
    .await
}
pub(crate) async fn retire(
    handle: String,
    workspace: String,
    token: String,
    name: String,
) -> Result<(), BridgeError> {
    crate::actor::call(handle.clone(), move |r, _| {
        let h = r.current(&handle)?;
        active_workspace(h, &workspace, &token)?;
        let closed = &mut h.closed_knowledge;
        h.knowledge.retain(|key, s| {
            if s.selection.workspace_id == workspace && s.name.as_ref() == Some(&name) {
                closed.insert(key.clone());
                return false;
            }
            true
        });
        h.journal
            .retire_saved_knowledge(super::LOCAL_OWNER, &workspace, &name)
            .map_err(saved_error)
    })
    .await
}

pub(crate) async fn reconcile(handle: String) -> Result<(), BridgeError> {
    crate::actor::call(handle.clone(), move |r, _| {
        let h = r.current(&handle)?;
        let result = h.journal.reconcile_saved_knowledge();
        h.knowledge_cleanup_pending = result.is_err();
        result.map_err(|_| failure("KNOWLEDGE_CLEANUP_PENDING"))
    })
    .await
}

pub(crate) async fn cleanup_pending(handle: String) -> Result<bool, BridgeError> {
    crate::actor::call(handle.clone(), move |r, _| {
        Ok(r.current(&handle)?.knowledge_cleanup_pending)
    })
    .await
}
