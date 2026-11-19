use super::*;
#[cfg(test)]
mod tests;
use crate::api::host::{
    AgentRunView, ModelConnectionView, ToolApprovalView, UserQuestionGroupView, UserQuestionView,
};
use orange_agent_runtime::engine::{
    EngineError, GatewayFailure, ModelFuture, ModelGateway, RunConfig, RunView,
};
use orange_model_runtime::llama::LlamaClient;
use orange_protocol::model::{GenerateRequest, Message, Role};
use orange_protocol::questions::AnswerUser;
use std::{
    io::Read,
    time::{SystemTime, UNIX_EPOCH},
};
use tokio::sync::watch;

#[derive(Default)]
pub(super) struct WriteSelection<'a> {
    pub memory: Option<&'a crate::api::memory::TaskMemorySelection>,
    pub creation: Option<(&'a str, &'a str)>,
    pub editing: Option<(&'a str, &'a str)>,
}
fn start_base(
    j: &mut Journal,
    c: &RunConfig,
    m: Vec<Message>,
    r: &workspace::WorkspaceGrant,
    create: Option<&orange_agent_runtime::workspace::creation::CreateFileGrant>,
    interactive: bool,
) -> Result<(), BridgeError> {
    if let Some(create) = create {
        j.start_agent_creating(c, m, r, create, interactive)
    } else if interactive {
        j.start_agent_interactive(c, m, r)
    } else {
        j.start_agent(c, m, r)
    }
    .map_err(engine_error)?;
    Ok(())
}
async fn advance_base(
    j: &mut Journal,
    run: &str,
    r: &workspace::WorkspaceGrant,
    create: Option<&orange_agent_runtime::workspace::creation::CreateFileGrant>,
    model: &impl ModelGateway,
    cancel: watch::Receiver<bool>,
) -> Result<(), BridgeError> {
    if let Some(create) = create {
        j.advance_agent_creating(LOCAL_OWNER, run, r, create, model, cancel)
            .await
    } else {
        j.advance_agent(LOCAL_OWNER, run, r, model, cancel).await
    }
    .map_err(engine_error)?;
    Ok(())
}
pub(super) struct ModelConnection {
    pub view: ModelConnectionView,
    pub gateway: Box<dyn ModelGateway>,
}
struct LocalGateway {
    id: String,
    alias: String,
    client: LlamaClient,
}
impl ModelGateway for LocalGateway {
    fn generate<'a>(
        &'a self,
        request: &'a GenerateRequest,
        cancel: watch::Receiver<bool>,
    ) -> ModelFuture<'a> {
        Box::pin(async move {
            if request.model_version != self.id {
                return Err(GatewayFailure);
            }
            let mut request = request.clone();
            request.model_version = self.alias.clone();
            let projection =
                llama_memory::Projection::for_request(&request).map_err(|_| GatewayFailure)?;
            let wire = projection.as_ref().map_or(&request, |p| &p.request);
            let result =
                self.client
                    .generate(wire, cancel)
                    .await
                    .and_then(|answer| match projection {
                        Some(mapping) => mapping.decode(&request, answer),
                        None => Ok(answer),
                    });
            result.map_err(|kind| {
                eprintln!("Local model request failed ({kind:?})");
                GatewayFailure
            })
        })
    }
}
pub(super) fn now() -> Result<i64, BridgeError> {
    i64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| failure("CLOCK_UNAVAILABLE"))?
            .as_secs(),
    )
    .map_err(|_| failure("CLOCK_UNAVAILABLE"))
}
pub(super) fn engine_error(error: EngineError) -> BridgeError {
    failure(match error {
        EngineError::Forbidden => "RUN_FORBIDDEN",
        EngineError::ExecutionEnvironmentUnavailable => "HOST_EXECUTION_ENVIRONMENT_UNAVAILABLE",
        EngineError::ApprovalRequired => "TOOL_APPROVAL_REQUIRED",
        EngineError::RecoveryRequired => "RUN_RECOVERY_REQUIRED",
        EngineError::Invalid => "INVALID_RUN_REQUEST",
        EngineError::Workspace(_) => "RUN_SOURCE_UNAVAILABLE",
        EngineError::Journal(orange_agent_runtime::JournalError::Conflict) => "RUN_CONFLICT",
        _ => "RUN_STORAGE_UNAVAILABLE",
    })
}
fn revision(view: &RunView) -> String {
    format!(
        "{:?}:{}:{}:{}",
        view.phase,
        view.steps,
        view.invocations,
        view.final_text.is_some()
    )
}
fn project(
    view: RunView,
    workspace: String,
    model: String,
    creation_consent_id: Option<String>,
    editing_consent_id: Option<String>,
) -> Result<AgentRunView, BridgeError> {
    let phase = serde_json::to_value(&view.phase)
        .map_err(|_| failure("RUN_INVALID_STATE"))?
        .as_str()
        .ok_or_else(|| failure("RUN_INVALID_STATE"))?
        .to_owned();
    let version = revision(&view);
    let pending = view
        .pending
        .into_iter()
        .map(|p| {
            let value =
                serde_json::to_value(&p.request).map_err(|_| failure("RUN_INVALID_STATE"))?;
            Ok(ToolApprovalView {
                operation_id: p.operation_id,
                tool_name: p.request.name().into(),
                arguments_json: serde_json::to_string(&value["arguments"])
                    .map_err(|_| failure("RUN_INVALID_STATE"))?,
                argument_digest: p.argument_digest,
            })
        })
        .collect::<Result<Vec<_>, BridgeError>>()?;
    Ok(AgentRunView {
        creation_consent_id,
        editing_consent_id,
        run_id: view.run_id,
        workspace_id: workspace,
        model_id: model,
        phase,
        revision: version,
        steps: view.steps,
        invocations: view.invocations,
        pending,
        user_question: view.user_question.map(|group| UserQuestionGroupView {
            question_id: group.question_id,
            argument_digest: group.argument_digest,
            questions: group
                .questions
                .into_iter()
                .map(|q| UserQuestionView {
                    prompt: q.prompt,
                    choices: q.choices,
                })
                .collect(),
        }),
        final_text: view.final_text,
        failure: view.failure,
    })
}
fn private_read(path: &Path, limit: u64) -> Result<Vec<u8>, BridgeError> {
    let meta = fs::symlink_metadata(path).map_err(|_| failure("MODEL_SERVICE_UNAVAILABLE"))?;
    if !meta.is_file() || meta.file_type().is_symlink() {
        return Err(failure("PRIVATE_MODEL_SERVICE_REQUIRED"));
    }
    let mut options = fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
        if meta.mode() & 0o077 != 0 || meta.nlink() != 1 {
            return Err(failure("PRIVATE_MODEL_SERVICE_REQUIRED"));
        }
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let file = options
        .open(path)
        .map_err(|_| failure("MODEL_SERVICE_UNAVAILABLE"))?;
    let opened = file
        .metadata()
        .map_err(|_| failure("MODEL_SERVICE_UNAVAILABLE"))?;
    if !opened.is_file() || opened.len() > limit {
        return Err(failure("PRIVATE_MODEL_SERVICE_REQUIRED"));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if opened.dev() != meta.dev()
            || opened.ino() != meta.ino()
            || opened.nlink() != 1
            || opened.mode() & 0o077 != 0
        {
            return Err(failure("PRIVATE_MODEL_SERVICE_REQUIRED"));
        }
    }
    let mut bytes = Vec::new();
    file.take(limit + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| failure("MODEL_SERVICE_UNAVAILABLE"))?;
    if bytes.len() as u64 > limit {
        return Err(failure("MODEL_SERVICE_LIMIT"));
    }
    Ok(bytes)
}
impl HostRegistry {
    pub(super) fn run_context(
        &mut self,
        handle: &str,
        run: &str,
    ) -> Result<
        (
            String,
            RunConfig,
            workspace::WorkspaceGrant,
            watch::Receiver<bool>,
        ),
        BridgeError,
    > {
        let signals = self.signals.clone();
        let host = self.current(handle)?;
        let config = host
            .journal
            .agent_config(LOCAL_OWNER, run)
            .map_err(engine_error)?;
        let workspace = host
            .journal
            .agent_workspace_id(LOCAL_OWNER, run)
            .map_err(engine_error)?
            .ok_or_else(|| failure("RUN_WORKSPACE_REQUIRED"))?;
        if !host.grants.get(&workspace).is_some_and(|g| !g.is_revoked()) {
            return Err(failure("WORKSPACE_SESSION_ACCESS_REQUIRED"));
        }
        if !host.run_grants.contains_key(run) {
            if host.run_grants.len() >= 256 {
                return Err(failure("RUN_SESSION_LIMIT"));
            }
            let grant = host
                .journal
                .open_workspace(LOCAL_OWNER, &workspace)
                .map_err(workspace_error)?;
            host.run_grants.insert(run.into(), grant);
        }
        let grant = host
            .run_grants
            .get(run)
            .ok_or_else(|| failure("RUN_CONTEXT_UNAVAILABLE"))?
            .clone();
        let creation_id = host
            .journal
            .agent_creation_requirement(LOCAL_OWNER, run)
            .map_err(engine_error)?
            .map(|r| r.consent_id);
        let editing_id = host
            .journal
            .agent_edit_requirement(LOCAL_OWNER, run)
            .map_err(engine_error)?
            .map(|r| r.consent_id);
        let mut signals = signals.lock().map_err(|_| failure("HOST_INTERNAL"))?;
        let control = signals
            .runs
            .entry(run.into())
            .or_insert_with(|| crate::actor::RunSignal {
                memories: Vec::new(),
                workspace: workspace.clone(),
                creation_id,
                editing_id,
                #[cfg(target_vendor = "apple")]
                editing_grant: None,
                cancel: watch::channel(false).0,
                grant: grant.clone(),
            });
        control.memories = host
            .task_memory
            .get(run)
            .map(|task| task.grants())
            .unwrap_or_default();
        Ok((workspace, config, grant, control.cancel.subscribe()))
    }
    pub(super) async fn connect_model(
        &mut self,
        handle: &str,
        path: &Path,
    ) -> Result<ModelConnectionView, BridgeError> {
        if !path.is_absolute() || path.is_symlink() {
            return Err(failure("PRIVATE_MODEL_SERVICE_REQUIRED"));
        }
        let root = path
            .canonicalize()
            .map_err(|_| failure("MODEL_SERVICE_UNAVAILABLE"))?;
        let host = self.current(handle)?;
        if !root.starts_with(&host.root) {
            return Err(failure("MODEL_SERVICE_OUTSIDE_HOST_STORAGE"));
        }
        if host
            .service
            .as_ref()
            .is_some_and(|service| !service.ready() || service.settings().root != root)
        {
            return Err(failure("MODEL_SERVICE_UNAVAILABLE"));
        }
        host.journal
            .reserve_private_directory(&root)
            .map_err(workspace_error)?;
        let profile: serde_json::Value =
            serde_json::from_slice(&private_read(&root.join("profile.json"), 16 * 1024)?)
                .map_err(|_| failure("INVALID_MODEL_SERVICE"))?;
        let record: serde_json::Value =
            serde_json::from_slice(&private_read(&root.join("process.json"), 16 * 1024)?)
                .map_err(|_| failure("INVALID_MODEL_SERVICE"))?;
        let alias = profile["model_version"]
            .as_str()
            .filter(|v| orange_protocol::valid_id(v))
            .ok_or_else(|| failure("INVALID_MODEL_SERVICE"))?
            .to_owned();
        let context = u32::try_from(
            profile["context_tokens"]
                .as_u64()
                .ok_or_else(|| failure("INVALID_MODEL_SERVICE"))?,
        )
        .map_err(|_| failure("INVALID_MODEL_SERVICE"))?;
        let configured_root = profile["runtime_directory"]
            .as_str()
            .and_then(|s| Path::new(s).canonicalize().ok());
        if profile["protocol"] != 1
            || configured_root.as_ref() != Some(&root)
            || !(256..=32768).contains(&context)
            || record["phase"] != "ready"
            || record["cpu_only"] != true
            || record["model_version"] != alias
            || !["model_sha256", "executable_sha256"].iter().all(|field| {
                profile[field]
                    .as_str()
                    .is_some_and(orange_protocol::valid_digest)
                    && profile[field] == record[field]
            })
        {
            return Err(failure("INVALID_MODEL_SERVICE"));
        }
        let instance = record["instance_id"]
            .as_str()
            .filter(|s| orange_protocol::valid_id(s))
            .ok_or_else(|| failure("INVALID_MODEL_SERVICE"))?;
        if profile
            .get("instance_id")
            .is_some_and(|value| !value.is_null() && value != instance)
        {
            return Err(failure("INVALID_MODEL_SERVICE"));
        }
        let key = String::from_utf8(private_read(&root.join("api.key"), 1024)?)
            .map_err(|_| failure("INVALID_MODEL_SERVICE"))?;
        // Only the authenticated filesystem endpoint may live in a short
        // private IPC directory. Profile, key, journal and process state remain
        // in Host storage; the model never chooses a network URL.
        let socket_root = match profile.get("socket_directory") {
            None | Some(serde_json::Value::Null) => root.clone(),
            Some(serde_json::Value::String(value)) => {
                let selected = Path::new(value);
                if !selected.is_absolute() || selected.is_symlink() {
                    return Err(failure("PRIVATE_MODEL_SERVICE_REQUIRED"));
                }
                let private = selected
                    .canonicalize()
                    .map_err(|_| failure("MODEL_SERVICE_UNAVAILABLE"))?;
                host.journal
                    .reserve_private_directory(&private)
                    .map_err(workspace_error)?;
                private
            }
            _ => return Err(failure("INVALID_MODEL_SERVICE")),
        };
        #[cfg(unix)]
        let client = LlamaClient::private_socket(
            &socket_root.join("engine.sock"),
            key.trim().into(),
            alias.clone(),
            context,
        )
        .map_err(|_| failure("INVALID_MODEL_SERVICE"))?;
        #[cfg(not(unix))]
        return Err(failure("MODEL_TRANSPORT_UNAVAILABLE"));
        #[cfg(unix)]
        {
            client
                .health()
                .await
                .map_err(|_| failure("MODEL_SERVICE_UNAVAILABLE"))?;
            let latest: serde_json::Value =
                serde_json::from_slice(&private_read(&root.join("process.json"), 16 * 1024)?)
                    .map_err(|_| failure("INVALID_MODEL_SERVICE"))?;
            if latest != record || latest["instance_id"] != instance {
                return Err(failure("MODEL_SERVICE_CHANGED"));
            }
            let id = format!(
                "local-{}",
                orange_protocol::request_digest(
                    "desktop-model-v1",
                    &(
                        alias.clone(),
                        context,
                        &profile["model_sha256"],
                        &profile["executable_sha256"]
                    )
                )
                .map_err(|_| failure("INVALID_MODEL_SERVICE"))?
            );
            let view = ModelConnectionView {
                model_id: id.clone(),
                display_name: alias.clone(),
                context_tokens: context,
                verification: "local-development-configuration".into(),
            };
            host.model = Some(ModelConnection {
                view: view.clone(),
                gateway: Box::new(LocalGateway { id, alias, client }),
            });
            Ok(view)
        }
    }
    async fn start_run(
        &mut self,
        handle: &str,
        workspace: &str,
        id: &str,
        prompt: &str,
        interactive: bool,
    ) -> Result<AgentRunView, BridgeError> {
        self.start_run_mode(
            handle,
            workspace,
            id,
            prompt,
            interactive,
            WriteSelection::default(),
        )
        .await
    }
    pub(super) async fn start_run_mode(
        &mut self,
        handle: &str,
        workspace: &str,
        id: &str,
        prompt: &str,
        interactive: bool,
        selection: WriteSelection<'_>,
    ) -> Result<AgentRunView, BridgeError> {
        if !orange_protocol::valid_id(id) || prompt.trim().is_empty() || prompt.len() > 64 * 1024 {
            return Err(failure("INVALID_RUN_REQUEST"));
        }
        let host = self.current(handle)?;
        if !host.run_grants.contains_key(id) && host.run_grants.len() >= 256 {
            return Err(failure("RUN_SESSION_LIMIT"));
        }
        if host.model.is_some()
            && host
                .service
                .as_ref()
                .is_some_and(|service| !service.ready())
        {
            return Err(failure("MODEL_SERVICE_UNAVAILABLE"));
        }
        if !host.grants.get(workspace).is_some_and(|g| !g.is_revoked()) {
            return Err(failure("WORKSPACE_SESSION_ACCESS_REQUIRED"));
        }
        let model = host
            .model
            .as_ref()
            .ok_or_else(|| failure("MODEL_NOT_CONFIGURED"))?;
        let grant = host
            .journal
            .open_workspace(LOCAL_OWNER, workspace)
            .map_err(workspace_error)?;
        let config = match host.journal.agent_config(LOCAL_OWNER, id) {
            Ok(config) => {
                if host
                    .journal
                    .agent_workspace_id(LOCAL_OWNER, id)
                    .map_err(engine_error)?
                    .as_deref()
                    != Some(workspace)
                {
                    return Err(failure("RUN_CONFLICT"));
                }
                config
            }
            Err(EngineError::Forbidden) => RunConfig {
                owner: LOCAL_OWNER.into(),
                run_id: id.into(),
                policy: READ_POLICY.into(),
                environment: grant.environment().into(),
                model_version: model.view.model_id.clone(),
                max_steps: 30,
                max_invocations: 20,
                max_output_tokens: 256,
                deadline_unix: now()? + 900,
            },
            Err(error) => return Err(engine_error(error)),
        };
        let mut messages = Vec::new();
        if selection.memory.is_some() {
            messages.push(Message::plain(Role::System, llama_memory::guide()));
        }
        messages.push(Message::plain(Role::User, prompt.into()));
        let create = if let Some((id, version)) = selection.creation {
            let current = host
                .creations
                .get(id)
                .filter(|s| {
                    s.workspace == workspace
                        && s.available.load(std::sync::atomic::Ordering::Acquire)
                })
                .ok_or_else(|| failure("CREATION_SESSION_ACCESS_REQUIRED"))?;
            if current.grant.consent_version() != version {
                return Err(failure("CREATION_PERMISSION_CHANGED"));
            }
            Some(current.grant.clone())
        } else {
            None
        };
        #[cfg(target_vendor = "apple")]
        let editing = if let Some((id, version)) = selection.editing {
            let current = host
                .editings
                .get(id)
                .filter(|s| {
                    s.workspace == workspace
                        && s.available.load(std::sync::atomic::Ordering::Acquire)
                })
                .ok_or_else(|| failure("EDITING_SESSION_ACCESS_REQUIRED"))?;
            if current.grant.consent_version().as_deref() != Some(version) {
                return Err(failure("EDITING_PERMISSION_CHANGED"));
            }
            Some(current.grant.clone())
        } else {
            None
        };
        #[cfg(not(target_vendor = "apple"))]
        if selection.editing.is_some() {
            return Err(failure("EDITING_UNAVAILABLE_ON_TARGET"));
        }
        if let Some(selection) = selection.memory {
            let task = task_memory::TaskMemory::derive(host, selection)?;
            let mut authority = task.authority(&grant);
            if let Some(create) = &create {
                authority = authority.with_creation(create);
            }
            #[cfg(target_vendor = "apple")]
            if let Some(edit) = &editing {
                authority = authority.with_editing(edit);
            }
            host.journal
                .start_agent_discovering(&config, messages, authority, interactive)
                .map_err(engine_error)?;
            if let Some(old) = host.task_memory.insert(id.into(), task) {
                old.revoke();
            }
        } else {
            #[cfg(target_vendor = "apple")]
            if let Some(edit) = &editing {
                host.journal
                    .start_agent_editing(
                        &config,
                        messages,
                        orange_agent_runtime::engine::EditingAuthority {
                            read: &grant,
                            create: create.as_ref(),
                            edit,
                        },
                        interactive,
                    )
                    .map_err(engine_error)?;
            } else {
                start_base(
                    &mut host.journal,
                    &config,
                    messages,
                    &grant,
                    create.as_ref(),
                    interactive,
                )?;
            }
            #[cfg(not(target_vendor = "apple"))]
            start_base(
                &mut host.journal,
                &config,
                messages,
                &grant,
                create.as_ref(),
                interactive,
            )?;
        }
        if host
            .service
            .as_ref()
            .is_some_and(|service| !service.ready())
        {
            host.journal
                .cancel_agent_run(LOCAL_OWNER, id)
                .map_err(engine_error)?;
            return Err(failure("MODEL_SERVICE_UNAVAILABLE"));
        }
        self.inspect_run(handle, id).await
    }
    pub(super) async fn inspect_run(
        &mut self,
        handle: &str,
        run: &str,
    ) -> Result<AgentRunView, BridgeError> {
        let (workspace, config, grant, _) = self.run_context(handle, run)?;
        let host = self.current(handle)?;
        let view = host
            .journal
            .agent_view_authorized_scopes(
                LOCAL_OWNER,
                run,
                host.task_memory
                    .get(run)
                    .cloned()
                    .unwrap_or_default()
                    .authority(&grant),
            )
            .await
            .map_err(engine_error)?;
        project(
            view,
            workspace,
            config.model_version,
            host.journal
                .agent_creation_requirement(LOCAL_OWNER, run)
                .map_err(engine_error)?
                .map(|r| r.consent_id),
            host.journal
                .agent_edit_requirement(LOCAL_OWNER, run)
                .map_err(engine_error)?
                .map(|r| r.consent_id),
        )
    }
    async fn approve_tool(
        &mut self,
        handle: &str,
        run: &str,
        operation: &str,
        digest: &str,
    ) -> Result<AgentRunView, BridgeError> {
        let (_, config, grant, _) = self.run_context(handle, run)?;
        let host = self.current(handle)?;
        let view = host
            .journal
            .agent_view_authorized_scopes(
                LOCAL_OWNER,
                run,
                host.task_memory
                    .get(run)
                    .cloned()
                    .unwrap_or_default()
                    .authority(&grant),
            )
            .await
            .map_err(engine_error)?;
        if !view
            .pending
            .iter()
            .any(|p| p.operation_id == operation && p.argument_digest == digest)
        {
            return Err(failure("TOOL_PREVIEW_CHANGED"));
        }
        host.journal
            .approve_agent_tool(
                LOCAL_OWNER,
                run,
                operation,
                (now()? + 60).min(config.deadline_unix),
                &grant,
            )
            .map_err(engine_error)?;
        self.inspect_run(handle, run).await
    }
    async fn approve_creation_tool(
        &mut self,
        handle: &str,
        run: &str,
        operation: &str,
        digest: &str,
    ) -> Result<AgentRunView, BridgeError> {
        let (_, config, grant, _) = self.run_context(handle, run)?;
        let host = self.current(handle)?;
        let create = super::creation::run_creation(host, run)?
            .ok_or_else(|| failure("CREATION_SESSION_ACCESS_REQUIRED"))?;
        host.journal
            .approve_agent_creation_authorized(
                LOCAL_OWNER,
                run,
                orange_agent_runtime::engine::CreationApproval {
                    operation_id: operation,
                    argument_digest: digest,
                    expires_at: (now()? + 60).min(config.deadline_unix),
                },
                host.task_memory
                    .get(run)
                    .cloned()
                    .unwrap_or_default()
                    .authority(&grant)
                    .with_creation(&create),
            )
            .await
            .map_err(engine_error)?;
        self.inspect_run(handle, run).await
    }
    async fn answer_question(
        &mut self,
        handle: &str,
        run: &str,
        question: &str,
        digest: &str,
        answers: Vec<String>,
    ) -> Result<AgentRunView, BridgeError> {
        let (workspace, config, grant, cancel) = self.run_context(handle, run)?;
        let host = self.current(handle)?;
        let answer = AnswerUser {
            question_id: question.into(),
            argument_digest: digest.into(),
            answers,
        };
        // Runtime validates immutable response binding, current source versions,
        // exact replay, cancellation and limits. No model or approval is invoked.
        let view = host
            .journal
            .answer_agent_question_authorized(
                LOCAL_OWNER,
                run,
                &answer,
                host.task_memory
                    .get(run)
                    .cloned()
                    .unwrap_or_default()
                    .authority(&grant),
                cancel,
            )
            .await
            .map_err(engine_error)?;
        project(
            view,
            workspace,
            config.model_version,
            host.journal
                .agent_creation_requirement(LOCAL_OWNER, run)
                .map_err(engine_error)?
                .map(|r| r.consent_id),
            host.journal
                .agent_edit_requirement(LOCAL_OWNER, run)
                .map_err(engine_error)?
                .map(|r| r.consent_id),
        )
    }
    async fn advance_run(
        &mut self,
        handle: &str,
        run: &str,
        expected: &str,
    ) -> Result<AgentRunView, BridgeError> {
        let (workspace, config, grant, cancel) = self.run_context(handle, run)?;
        #[cfg(target_vendor = "apple")]
        let signals = self.signals.clone();
        let host = self.current(handle)?;
        if host
            .service
            .as_ref()
            .is_some_and(|service| !service.ready())
        {
            return Err(failure("MODEL_SERVICE_UNAVAILABLE"));
        }
        let view = if let Some(task) = host.task_memory.get(run) {
            host.journal
                .agent_view_authorized_scopes(LOCAL_OWNER, run, task.authority(&grant))
                .await
        } else {
            host.journal.agent_view(LOCAL_OWNER, run)
        }
        .map_err(engine_error)?;
        if revision(&view) != expected {
            return Err(failure("RUN_VERSION_CHANGED"));
        }
        let create = super::creation::run_creation(host, run)?;
        #[cfg(target_vendor = "apple")]
        let editing = super::editing::run_editing(host, run, &signals)?;
        let model = host
            .model
            .as_ref()
            .ok_or_else(|| failure("MODEL_NOT_CONFIGURED"))?;
        if model.view.model_id != config.model_version {
            return Err(failure("MODEL_CONTEXT_CHANGED"));
        }
        let gateway = GatewayRef(model.gateway.as_ref());
        if let Some(task) = host.task_memory.get(run) {
            let mut authority = task.authority(&grant);
            if let Some(create) = &create {
                authority = authority.with_creation(create);
            }
            #[cfg(target_vendor = "apple")]
            if let Some(edit) = &editing {
                authority = authority.with_editing(edit);
            }
            host.journal
                .advance_agent_authorized(LOCAL_OWNER, run, authority, &gateway, cancel)
                .await
                .map_err(engine_error)?;
            return self.inspect_run(handle, run).await;
        }
        #[cfg(target_vendor = "apple")]
        if let Some(edit) = &editing {
            host.journal
                .advance_agent_editing(
                    LOCAL_OWNER,
                    run,
                    orange_agent_runtime::engine::EditingAuthority {
                        read: &grant,
                        create: create.as_ref(),
                        edit,
                    },
                    &gateway,
                    cancel,
                )
                .await
                .map_err(engine_error)?;
        } else {
            advance_base(
                &mut host.journal,
                run,
                &grant,
                create.as_ref(),
                &gateway,
                cancel,
            )
            .await?;
        }
        #[cfg(not(target_vendor = "apple"))]
        advance_base(
            &mut host.journal,
            run,
            &grant,
            create.as_ref(),
            &gateway,
            cancel,
        )
        .await?;
        let view = host
            .journal
            .agent_view(LOCAL_OWNER, run)
            .map_err(engine_error)?;
        let view = if view.final_text.is_some()
            || !view.pending.is_empty()
            || view.user_question.is_some()
        {
            host.journal
                .agent_view_authorized_scopes(
                    LOCAL_OWNER,
                    run,
                    host.task_memory
                        .get(run)
                        .cloned()
                        .unwrap_or_default()
                        .authority(&grant),
                )
                .await
                .map_err(engine_error)?
        } else {
            view
        };
        project(
            view,
            workspace,
            config.model_version,
            host.journal
                .agent_creation_requirement(LOCAL_OWNER, run)
                .map_err(engine_error)?
                .map(|r| r.consent_id),
            host.journal
                .agent_edit_requirement(LOCAL_OWNER, run)
                .map_err(engine_error)?
                .map(|r| r.consent_id),
        )
    }
    fn cancel_run(&mut self, handle: &str, run: &str) -> Result<AgentRunView, BridgeError> {
        let host = self.current(handle)?;
        let config = host
            .journal
            .agent_config(LOCAL_OWNER, run)
            .map_err(engine_error)?;
        let workspace = host
            .journal
            .agent_workspace_id(LOCAL_OWNER, run)
            .map_err(engine_error)?
            .ok_or_else(|| failure("RUN_WORKSPACE_REQUIRED"))?;
        if let Some(task) = host.task_memory.remove(run) {
            task.revoke();
        }
        if let Some(grant) = host.run_grants.remove(run) {
            grant.request_revoke();
        }
        project(
            host.journal
                .cancel_agent_run(LOCAL_OWNER, run)
                .map_err(engine_error)?,
            workspace,
            config.model_version,
            host.journal
                .agent_creation_requirement(LOCAL_OWNER, run)
                .map_err(engine_error)?
                .map(|r| r.consent_id),
            host.journal
                .agent_edit_requirement(LOCAL_OWNER, run)
                .map_err(engine_error)?
                .map(|r| r.consent_id),
        )
    }
}
struct GatewayRef<'a>(&'a dyn ModelGateway);
impl ModelGateway for GatewayRef<'_> {
    fn generate<'a>(&'a self, r: &'a GenerateRequest, c: watch::Receiver<bool>) -> ModelFuture<'a> {
        self.0.generate(r, c)
    }
}
pub(crate) async fn connect_local_model(
    handle: String,
    selected_directory: String,
) -> Result<ModelConnectionView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.connect_model(&handle, Path::new(&selected_directory)))
    })
    .await
}
pub(crate) async fn disconnect_local_model(handle: String) -> Result<(), BridgeError> {
    crate::actor::call(handle.clone(), move |host, _| {
        host.current(&handle)?.model = None;
        Ok(())
    })
    .await
}
pub(crate) async fn start_run(
    handle: String,
    workspace_id: String,
    request_id: String,
    prompt: String,
) -> Result<AgentRunView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.start_run(&handle, &workspace_id, &request_id, &prompt, false))
    })
    .await
}
pub(crate) async fn start_interactive_run(
    handle: String,
    workspace_id: String,
    request_id: String,
    prompt: String,
) -> Result<AgentRunView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.start_run(&handle, &workspace_id, &request_id, &prompt, true))
    })
    .await
}
pub(crate) async fn answer_user_question(
    handle: String,
    run_id: String,
    question_id: String,
    expected_digest: String,
    answers: Vec<String>,
) -> Result<AgentRunView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.answer_question(&handle, &run_id, &question_id, &expected_digest, answers))
    })
    .await
}
pub(crate) async fn inspect_run(
    handle: String,
    run_id: String,
) -> Result<AgentRunView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.inspect_run(&handle, &run_id))
    })
    .await
}
pub(crate) async fn approve_tool(
    handle: String,
    run_id: String,
    operation_id: String,
    expected_digest: String,
) -> Result<AgentRunView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.approve_tool(&handle, &run_id, &operation_id, &expected_digest))
    })
    .await
}
pub(crate) async fn advance_run(
    handle: String,
    run_id: String,
    expected_revision: String,
) -> Result<AgentRunView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.advance_run(&handle, &run_id, &expected_revision))
    })
    .await
}
pub(crate) async fn cancel_run(
    handle: String,
    run_id: String,
) -> Result<AgentRunView, BridgeError> {
    crate::actor::signal_cancel(&handle, &run_id)?;
    crate::actor::call(handle.clone(), move |host, _| {
        host.cancel_run(&handle, &run_id)
    })
    .await
}

pub(crate) async fn start_creation_run(
    handle: String,
    workspace: String,
    request: String,
    prompt: String,
    consent: String,
    version: String,
    interactive: bool,
) -> Result<AgentRunView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.start_run_mode(
            &handle,
            &workspace,
            &request,
            &prompt,
            interactive,
            WriteSelection {
                memory: None,
                creation: Some((&consent, &version)),
                editing: None,
            },
        ))
    })
    .await
}
pub(crate) async fn approve_creation_tool(
    handle: String,
    run: String,
    operation: String,
    digest: String,
) -> Result<AgentRunView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.approve_creation_tool(&handle, &run, &operation, &digest))
    })
    .await
}
