use super::{Host, failure};
use crate::api::{
    host::BridgeError,
    knowledge::{KnowledgeHit, KnowledgePage, KnowledgePassage, KnowledgeSelection},
};
use orange_agent_runtime::workspace::{
    WorkspaceError, WorkspaceGrant,
    knowledge::{
        Hit, KnowledgeCollection, KnowledgeError, KnowledgeRequest, KnowledgeResult, Read, Search,
    },
};
use orange_protocol::valid_id;

pub(super) struct Session {
    selection: KnowledgeSelection,
    paths: Vec<String>,
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
    if !valid_id(&s.workspace_id)
        || !valid_id(&s.session_token)
        || !valid_id(&s.collection_id)
        || host.access_tokens.get(&s.workspace_id) != Some(&s.session_token)
    {
        return Err(failure("KNOWLEDGE_ACCESS_DENIED"));
    }
    host.grants
        .get(&s.workspace_id)
        .filter(|g| !g.is_revoked())
        .ok_or_else(|| failure("KNOWLEDGE_ACCESS_DENIED"))
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
            return if old.selection == selection && old.paths == paths {
                Ok(())
            } else {
                Err(failure("KNOWLEDGE_SELECTION_CONFLICT"))
            };
        }
        if h.knowledge.len() >= 8 || h.knowledge.len() + h.closed_knowledge.len() >= 8192 {
            return Err(failure("KNOWLEDGE_LIMIT"));
        }
        let collection = KnowledgeCollection::open(grant, &selection.collection_id, paths.clone())
            .map_err(mapped)?;
        h.knowledge.insert(
            selection.collection_id.clone(),
            Session {
                selection,
                paths,
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
            collection_id: selection.collection_id,
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
            collection_id: selection.collection_id,
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
