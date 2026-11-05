use super::{Bundle, io};
use crate::{
    api::host::{BridgeError, ModelServiceView},
    host::failure,
};
use serde::{Deserialize, Serialize};
use std::{
    fs::File,
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt, BufReader},
    process::{Child, ChildStdin, ChildStdout, Command},
    sync::{mpsc, oneshot, watch},
};

const ALIAS: &str = "orange-local-qwen-v1";
#[derive(Clone)]
pub(crate) struct Settings {
    pub bundle: Bundle,
    pub root: PathBuf,
    pub ipc: PathBuf,
    pub cache: PathBuf,
    pub startup_seconds: u64,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Entry {
    request: String,
    instance: String,
    phase: String,
    failure: Option<String>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct History {
    schema: u32,
    entries: Vec<Entry>,
    #[serde(default)]
    closed_requests: Vec<String>,
}
struct Shared {
    history: History,
    installed: bool,
    cancel: Option<watch::Sender<bool>>,
    phase: String,
    failure: Option<String>,
    closed_requests: std::collections::HashSet<String>,
}
enum Work {
    Start {
        index: usize,
        cancel: watch::Receiver<bool>,
        reply: oneshot::Sender<Result<ModelServiceView, BridgeError>>,
    },
    Stop {
        instance: String,
        reply: oneshot::Sender<Result<ModelServiceView, BridgeError>>,
    },
}
#[derive(Clone)]
pub(crate) struct Client {
    settings: Settings,
    state: Arc<Mutex<Shared>>,
    queue: mpsc::Sender<Work>,
    closing: watch::Sender<bool>,
    alive: Arc<AtomicBool>,
}
struct Owned {
    child: Child,
    input: Option<ChildStdin>,
    output: BufReader<ChildStdout>,
    instance: String,
    index: usize,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Record {
    instance_id: String,
    model_version: String,
    executable_sha256: String,
    model_sha256: String,
    phase: String,
    #[serde(rename = "pid")]
    _pid: Option<u32>,
    #[serde(rename = "exit_code")]
    _exit_code: Option<i32>,
    cpu_only: bool,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Frame {
    protocol: u32,
    record: Record,
}

fn record(settings: &Settings) -> Result<Option<Record>, BridgeError> {
    let path = settings.root.join("process.json");
    match std::fs::symlink_metadata(&path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(_) => Err(failure("MODEL_STORAGE_UNAVAILABLE")),
        Ok(_) => serde_json::from_slice(&io::read(&path, 16 * 1024, true)?)
            .map(Some)
            .map_err(|_| failure("MODEL_RECOVERY_REQUIRED")),
    }
}
fn save(settings: &Settings, state: &Shared) -> Result<(), BridgeError> {
    io::write_json(&settings.root.join("manager.json"), &state.history)
}
fn snapshot(settings: &Settings, state: &Shared) -> ModelServiceView {
    ModelServiceView {
        phase: if matches!(state.phase.as_str(), "starting" | "ready")
            && state.cancel.as_ref().is_some_and(|cancel| *cancel.borrow())
        {
            "stopping".into()
        } else {
            state.phase.clone()
        },
        model_name: settings.bundle.model_name.clone(),
        model_bytes: settings.bundle.model_bytes.to_string(),
        installed: state.installed,
        instance_id: state.history.entries.last().map(|e| e.instance.clone()),
        failure: state.failure.clone(),
    }
}
fn change(
    settings: &Settings,
    state: &Arc<Mutex<Shared>>,
    index: usize,
    phase: &str,
    code: Option<&str>,
) -> Result<ModelServiceView, BridgeError> {
    let mut shared = state.lock().map_err(|_| failure("MODEL_INTERNAL"))?;
    let entry = shared
        .history
        .entries
        .get_mut(index)
        .ok_or_else(|| failure("MODEL_INVALID_STATE"))?;
    entry.phase = phase.into();
    entry.failure = code.map(str::to_owned);
    shared.phase = phase.into();
    shared.failure = code.map(str::to_owned);
    save(settings, &shared)?;
    Ok(snapshot(settings, &shared))
}
impl Client {
    pub fn new(settings: Settings, installed: bool) -> Result<Self, BridgeError> {
        let lease = io::lease(&settings.root.join("control.lease"))?;
        let path = settings.root.join("manager.json");
        let mut history: History = match std::fs::symlink_metadata(&path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => History {
                schema: 1,
                entries: vec![],
                closed_requests: vec![],
            },
            Err(_) => return Err(failure("MODEL_STORAGE_UNAVAILABLE")),
            Ok(_) => serde_json::from_slice(&io::read(&path, 256 * 1024, true)?)
                .map_err(|_| failure("MODEL_RECOVERY_REQUIRED"))?,
        };
        if history.schema != 1
            || history.entries.len() > 256
            || history.entries.iter().any(|e| {
                !orange_protocol::valid_id(&e.request)
                    || !orange_protocol::valid_id(&e.instance)
                    || !matches!(
                        e.phase.as_str(),
                        "starting" | "ready" | "stopped" | "recovery_required"
                    )
            })
        {
            return Err(failure("MODEL_RECOVERY_REQUIRED"));
        }
        let mut requests = std::collections::HashSet::new();
        let mut instances = std::collections::HashSet::new();
        if history.entries.iter().any(|entry| {
            !requests.insert(entry.request.clone())
                || !instances.insert(entry.instance.clone())
                || entry
                    .failure
                    .as_ref()
                    .is_some_and(|value| !orange_protocol::valid_id(value))
        }) {
            return Err(failure("MODEL_RECOVERY_REQUIRED"));
        }
        let previous = record(&settings)?;
        let closed = history
            .closed_requests
            .iter()
            .cloned()
            .collect::<std::collections::HashSet<_>>();
        if closed.len() != history.closed_requests.len()
            || closed.len() > 256
            || closed.iter().any(|id| !orange_protocol::valid_id(id))
        {
            return Err(failure("MODEL_RECOVERY_REQUIRED"));
        }
        let stopped = previous.as_ref().is_none_or(|r| {
            r.phase == "stopped"
                && r.cpu_only
                && orange_protocol::valid_digest(&r.executable_sha256)
                && orange_protocol::valid_digest(&r.model_sha256)
        });
        let mut phase = if stopped { "idle" } else { "recovery_required" };
        if let Some(last) = history.entries.last_mut() {
            if previous.as_ref().is_some_and(|r| {
                r.instance_id == last.instance && r.phase == "stopped" && r.cpu_only
            }) {
                last.phase = "stopped".into();
            }
            if last.phase != "stopped" {
                phase = "recovery_required";
            } else if stopped {
                phase = "stopped";
            }
        }
        let shared = Shared {
            closed_requests: closed,
            history,
            installed,
            cancel: None,
            phase: phase.into(),
            failure: if phase == "recovery_required" {
                Some("MODEL_RECOVERY_REQUIRED".into())
            } else {
                None
            },
        };
        save(&settings, &shared)?;
        let state = Arc::new(Mutex::new(shared));
        let (queue, receiver) = mpsc::channel(8);
        let (closing, close) = watch::channel(false);
        let alive = Arc::new(AtomicBool::new(true));
        let client = Self {
            settings: settings.clone(),
            state: state.clone(),
            queue,
            closing,
            alive: alive.clone(),
        };
        std::thread::Builder::new()
            .name("orange-model-owner".into())
            .spawn(move || {
                struct Lifetime(Arc<AtomicBool>);
                impl Drop for Lifetime {
                    fn drop(&mut self) {
                        self.0.store(false, Ordering::Release);
                    }
                }
                let _lifetime = Lifetime(alive);
                let _lease: File = lease;
                if let Ok(runtime) = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                {
                    runtime.block_on(run(settings, state, receiver, close));
                    runtime.shutdown_timeout(Duration::from_secs(1));
                }
            })
            .map_err(|_| failure("MODEL_SERVICE_UNAVAILABLE"))?;
        Ok(client)
    }
    pub fn settings(&self) -> &Settings {
        &self.settings
    }
    pub fn view(&self) -> Result<ModelServiceView, BridgeError> {
        let state = self.state.lock().map_err(|_| failure("MODEL_INTERNAL"))?;
        if !self.alive.load(Ordering::Acquire) && state.phase != "stopped" {
            return Err(failure("MODEL_SERVICE_UNAVAILABLE"));
        }
        Ok(snapshot(&self.settings, &state))
    }
    pub fn installed(&self, value: bool) -> Result<(), BridgeError> {
        self.state
            .lock()
            .map_err(|_| failure("MODEL_INTERNAL"))?
            .installed = value;
        Ok(())
    }
    pub fn ready(&self) -> bool {
        self.view().is_ok_and(|view| view.phase == "ready") && !*self.closing.borrow()
    }
    pub fn close(&self) {
        self.closing.send_replace(true);
    }
    pub fn signal_stop(&self, instance: &str) -> Result<(), BridgeError> {
        let state = self.state.lock().map_err(|_| failure("MODEL_INTERNAL"))?;
        if state
            .history
            .entries
            .last()
            .is_none_or(|e| e.instance != instance)
        {
            return Err(failure("MODEL_INSTANCE_CHANGED"));
        }
        if let Some(cancel) = &state.cancel {
            cancel.send_replace(true);
        }
        Ok(())
    }
    pub fn cancel_request(&self, request: &str) -> Result<Option<String>, BridgeError> {
        if !orange_protocol::valid_id(request) {
            return Err(failure("INVALID_MODEL_REQUEST"));
        }
        let mut state = self.state.lock().map_err(|_| failure("MODEL_INTERNAL"))?;
        if state.closed_requests.len() >= 256 && !state.closed_requests.contains(request) {
            return Err(failure("MODEL_COMMAND_LIMIT"));
        }
        if state.closed_requests.insert(request.into()) {
            state.history.closed_requests.push(request.into());
            save(&self.settings, &state)?;
        }
        let target = state
            .history
            .entries
            .last()
            .filter(|entry| entry.request == request)
            .map(|entry| entry.instance.clone());
        if target.is_some()
            && let Some(cancel) = &state.cancel
        {
            cancel.send_replace(true);
        }
        Ok(target)
    }
    pub async fn start(&self, request: &str) -> Result<ModelServiceView, BridgeError> {
        if !orange_protocol::valid_id(request) {
            return Err(failure("INVALID_MODEL_REQUEST"));
        }
        if *self.closing.borrow() || !self.alive.load(Ordering::Acquire) {
            return Err(failure("MODEL_SERVICE_UNAVAILABLE"));
        }
        let (reply, response) = oneshot::channel();
        {
            let mut state = self.state.lock().map_err(|_| failure("MODEL_INTERNAL"))?;
            if state.closed_requests.contains(request) {
                return Err(failure("MODEL_START_CANCELLED"));
            }
            if let Some(entry) = state.history.entries.iter().find(|e| e.request == request) {
                let mut view = snapshot(&self.settings, &state);
                view.instance_id = Some(entry.instance.clone());
                if state
                    .history
                    .entries
                    .last()
                    .is_none_or(|last| last.instance != entry.instance)
                {
                    view.phase = entry.phase.clone();
                }
                view.failure = entry.failure.clone();
                return Ok(view);
            }
            if state.phase == "recovery_required" {
                return Err(failure("MODEL_RECOVERY_REQUIRED"));
            }
            if !matches!(state.phase.as_str(), "idle" | "stopped") {
                return Err(failure("MODEL_SERVICE_BUSY"));
            }
            if !state.installed {
                return Err(failure("MODEL_NOT_INSTALLED"));
            }
            if state.history.entries.len() >= 256 {
                return Err(failure("MODEL_COMMAND_LIMIT"));
            }
            let index = state.history.entries.len();
            let (cancel, receiver) = watch::channel(false);
            state.history.entries.push(Entry {
                request: request.into(),
                instance: uuid::Uuid::new_v4().to_string(),
                phase: "starting".into(),
                failure: None,
            });
            state.phase = "starting".into();
            state.failure = None;
            state.cancel = Some(cancel);
            save(&self.settings, &state)?;
            if self
                .queue
                .try_send(Work::Start {
                    index,
                    cancel: receiver,
                    reply,
                })
                .is_err()
            {
                // try_send returns the unaccepted command; no child can have
                // been spawned for this request. Persist that known outcome.
                state.history.entries[index].phase = "stopped".into();
                state.history.entries[index].failure = Some("MODEL_DISPATCH_REJECTED".into());
                state.phase = "stopped".into();
                state.failure = Some("MODEL_DISPATCH_REJECTED".into());
                save(&self.settings, &state)?;
                return Err(failure("MODEL_DISPATCH_REJECTED"));
            }
        }
        response
            .await
            .map_err(|_| failure("MODEL_SERVICE_UNAVAILABLE"))?
    }
    pub async fn stop(&self, instance: &str) -> Result<ModelServiceView, BridgeError> {
        self.signal_stop(instance)?;
        let (reply, response) = oneshot::channel();
        self.queue
            .try_send(Work::Stop {
                instance: instance.into(),
                reply,
            })
            .map_err(|_| failure("MODEL_SERVICE_BUSY"))?;
        response
            .await
            .map_err(|_| failure("MODEL_SERVICE_UNAVAILABLE"))?
    }
}

async fn frame(output: &mut BufReader<ChildStdout>) -> Result<Frame, BridgeError> {
    let mut bytes = Vec::new();
    let mut byte = [0];
    while bytes.len() < 16 * 1024 {
        if output
            .read(&mut byte)
            .await
            .map_err(|_| failure("MODEL_SERVICE_UNAVAILABLE"))?
            == 0
        {
            return Err(failure("MODEL_SERVICE_UNAVAILABLE"));
        }
        bytes.push(byte[0]);
        if byte[0] == b'\n' {
            return serde_json::from_slice(&bytes).map_err(|_| failure("MODEL_CONTROL_INVALID"));
        }
    }
    Err(failure("MODEL_CONTROL_INVALID"))
}
async fn send(input: &mut ChildStdin, bytes: &[u8]) -> Result<(), BridgeError> {
    tokio::time::timeout(Duration::from_secs(2), input.write_all(bytes))
        .await
        .map_err(|_| failure("MODEL_CONTROL_UNAVAILABLE"))?
        .map_err(|_| failure("MODEL_CONTROL_UNAVAILABLE"))
}
async fn stop_owned(
    settings: &Settings,
    state: &Arc<Mutex<Shared>>,
    owned: &mut Option<Owned>,
) -> Result<ModelServiceView, BridgeError> {
    let process = owned
        .as_mut()
        .ok_or_else(|| failure("MODEL_RECOVERY_REQUIRED"))?;
    let index = process.index;
    if let Some(mut input) = process.input.take() {
        // A failed send is followed by EOF and an actual exit/record check;
        // it never turns a failed write into an acknowledged stopped state.
        let _ = send(&mut input, b"shutdown\n").await;
        let _ = tokio::time::timeout(Duration::from_secs(2), input.shutdown()).await;
    }
    let exited = tokio::time::timeout(Duration::from_secs(15), process.child.wait()).await;
    let stopped = exited.is_ok_and(|result| result.is_ok())
        && record(settings)?.is_some_and(|r| {
            r.instance_id == process.instance
                && r.phase == "stopped"
                && r.cpu_only
                && r.model_sha256 == settings.bundle.model_sha
                && r.executable_sha256 == settings.bundle.backend_sha
                && r.model_version == ALIAS
        });
    if stopped {
        *owned = None;
        change(settings, state, index, "stopped", None)
    } else {
        change(
            settings,
            state,
            index,
            "recovery_required",
            Some("MODEL_CLEANUP_UNCONFIRMED"),
        )?;
        Err(failure("MODEL_CLEANUP_UNCONFIRMED"))
    }
}
async fn start_owned(
    settings: &Settings,
    state: &Arc<Mutex<Shared>>,
    owned: &mut Option<Owned>,
    index: usize,
    mut cancel: watch::Receiver<bool>,
    mut closing: watch::Receiver<bool>,
) -> Result<ModelServiceView, BridgeError> {
    if *cancel.borrow() || *closing.borrow() {
        change(
            settings,
            state,
            index,
            "stopped",
            Some("MODEL_START_CANCELLED"),
        )?;
        return Err(failure("MODEL_START_CANCELLED"));
    }
    settings.bundle.verify_programs()?;
    if record(settings)?.is_some_and(|r| r.phase != "stopped") {
        return Err(failure("MODEL_RECOVERY_REQUIRED"));
    }
    let instance = state
        .lock()
        .map_err(|_| failure("MODEL_INTERNAL"))?
        .history
        .entries[index]
        .instance
        .clone();
    let nonce =
        uuid::Uuid::new_v4().simple().to_string() + &uuid::Uuid::new_v4().simple().to_string();
    io::write_json(
        &settings.root.join("profile.json"),
        &serde_json::json!({"protocol":1,"runtime_directory":settings.root,"socket_directory":settings.ipc,"executable":settings.bundle.backend,"executable_sha256":settings.bundle.backend_sha,
        "model":settings.cache.join(format!("{}.gguf",settings.bundle.model_sha)),"model_sha256":settings.bundle.model_sha,"model_bytes":settings.bundle.model_bytes,"model_version":ALIAS,"context_tokens":4096,"startup_timeout_seconds":settings.startup_seconds,"control_nonce":nonce,"instance_id":instance}),
    )?;
    if *cancel.borrow() || *closing.borrow() {
        change(
            settings,
            state,
            index,
            "stopped",
            Some("MODEL_START_CANCELLED"),
        )?;
        return Err(failure("MODEL_START_CANCELLED"));
    }
    let mut child = Command::new(&settings.bundle.helper)
        .arg(settings.root.join("profile.json"))
        .current_dir(&settings.root)
        .env_clear()
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|_| failure("MODEL_START_FAILED"))?;
    let input = child
        .stdin
        .take()
        .ok_or_else(|| failure("MODEL_START_FAILED"))?;
    let output = child
        .stdout
        .take()
        .ok_or_else(|| failure("MODEL_START_FAILED"))?;
    *owned = Some(Owned {
        child,
        input: Some(input),
        output: BufReader::new(output),
        instance: instance.clone(),
        index,
    });
    let process = owned
        .as_mut()
        .ok_or_else(|| failure("MODEL_INVALID_STATE"))?;
    send(
        process
            .input
            .as_mut()
            .ok_or_else(|| failure("MODEL_START_FAILED"))?,
        format!("auth {nonce}\n").as_bytes(),
    )
    .await?;
    let ready = frame(&mut process.output);
    tokio::pin!(ready);
    let deadline = tokio::time::sleep(Duration::from_secs(settings.startup_seconds + 20));
    tokio::pin!(deadline);
    let mut ping = tokio::time::interval(Duration::from_secs(5));
    let result = loop {
        tokio::select! {
            _=cancel.changed()=>break Err(failure("MODEL_START_CANCELLED")),
            _=closing.changed()=>break Err(failure("MODEL_START_CANCELLED")),
            _=&mut deadline=>break Err(failure("MODEL_START_UNCONFIRMED")),
            result=&mut ready=>break result,
            _=ping.tick()=>{if send(process.input.as_mut().ok_or_else(||failure("MODEL_START_FAILED"))?,b"ping\n").await.is_err(){break Err(failure("MODEL_START_FAILED"));}}
        }
    };
    let cancelled = *cancel.borrow() || *closing.borrow();
    match result {
        Ok(value)
            if !cancelled
                && value.protocol == 1
                && value.record.phase == "ready"
                && value.record.instance_id == instance
                && value.record.model_sha256 == settings.bundle.model_sha
                && value.record.executable_sha256 == settings.bundle.backend_sha
                && value.record.model_version == ALIAS
                && value.record.cpu_only =>
        {
            change(settings, state, index, "ready", None)
        }
        _ => Err(failure(if cancelled {
            "MODEL_START_CANCELLED"
        } else {
            "MODEL_START_UNCONFIRMED"
        })),
    }
}
async fn run(
    settings: Settings,
    state: Arc<Mutex<Shared>>,
    mut queue: mpsc::Receiver<Work>,
    mut close: watch::Receiver<bool>,
) {
    let mut owned = None;
    let mut tick = tokio::time::interval(Duration::from_secs(5));
    loop {
        tokio::select! {
            _=close.changed()=>break,
            command=queue.recv()=>match command {
                None=>break,
                Some(Work::Start{index,cancel,reply})=>{
                    let result=start_owned(&settings,&state,&mut owned,index,cancel,close.clone()).await;
                    if let Err(error)=&result {
                        if owned.is_some(){let _=stop_owned(&settings,&state,&mut owned).await;}
                        else {let phase=if error.code=="MODEL_RECOVERY_REQUIRED" || error.code=="MODEL_START_UNCONFIRMED" {"recovery_required"}else{"stopped"};let _=change(&settings,&state,index,phase,Some(&error.code));}
                    }
                    let _=reply.send(result);
                }
                Some(Work::Stop{instance,reply})=>{
                    let current=state.lock().ok().and_then(|s|s.history.entries.last().map(|e|e.instance.clone()));
                    let result=if current.as_deref()!=Some(&instance){Err(failure("MODEL_INSTANCE_CHANGED"))}
                        else if owned.is_some(){stop_owned(&settings,&state,&mut owned).await}
                        else {state.lock().map_err(|_|failure("MODEL_INTERNAL")).and_then(|s|if s.phase=="stopped"{Ok(snapshot(&settings,&s))}else{Err(failure("MODEL_RECOVERY_REQUIRED"))})};
                    let _=reply.send(result);
                }
            },
            _=tick.tick()=>{
                let cancelled=state.lock().map(|s|s.cancel.as_ref().is_some_and(|cancel|*cancel.borrow())).unwrap_or(true);
                if cancelled && owned.is_some(){let _=stop_owned(&settings,&state,&mut owned).await;continue;}
                if let Some(process)=owned.as_mut() {
                    match process.child.try_wait() {
                        Ok(Some(_))=>{let _=stop_owned(&settings,&state,&mut owned).await;}
                        Ok(None)=>{if let Some(input)=process.input.as_mut() && send(input,b"ping\n").await.is_err(){let _=stop_owned(&settings,&state,&mut owned).await;}}
                        Err(_)=>{let _=change(&settings,&state,process.index,"recovery_required",Some("MODEL_SERVICE_UNAVAILABLE"));}
                    }
                }
            }
        }
    }
    if owned.is_some() {
        let _ = stop_owned(&settings, &state, &mut owned).await;
    }
    while let Ok(command) = queue.try_recv() {
        match command {
            Work::Start { index, reply, .. } => {
                let _ = change(
                    &settings,
                    &state,
                    index,
                    "stopped",
                    Some("MODEL_START_CANCELLED"),
                );
                let _ = reply.send(Err(failure("MODEL_START_CANCELLED")));
            }
            Work::Stop { reply, .. } => {
                let _ = reply.send(Err(failure("MODEL_SERVICE_UNAVAILABLE")));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn rejected_queue_request_is_durable_without_inventing_a_process() {
        let temp = tempfile::tempdir().expect("fixture");
        let root = io::directory(&temp.path().join("private")).expect("private root");
        // No executable is used in this admission test. Catalog/executable
        // validation and actual process behavior have separate acceptance.
        let bundle = Bundle {
            contents: root.clone(),
            helper: root.join("unused-host"),
            backend: root.join("unused-backend"),
            helper_sha: "0".repeat(64),
            helper_bytes: 1,
            backend_sha: "0".repeat(64),
            backend_bytes: 1,
            model_sha: "0".repeat(64),
            model_bytes: 4,
            model_name: "admission-fixture".into(),
            model_url: "https://huggingface.co/fixture".into(),
        };
        let settings = Settings {
            bundle,
            root: root.clone(),
            ipc: root.clone(),
            cache: root.clone(),
            startup_seconds: 1,
        };
        let state = Arc::new(Mutex::new(Shared {
            history: History {
                schema: 1,
                entries: vec![],
                closed_requests: vec![],
            },
            installed: true,
            cancel: None,
            phase: "idle".into(),
            failure: None,
            closed_requests: Default::default(),
        }));
        let (queue, receiver) = mpsc::channel(1);
        drop(receiver);
        let (closing, _receiver) = watch::channel(false);
        let client = Client {
            settings: settings.clone(),
            state,
            queue,
            closing,
            alive: Arc::new(AtomicBool::new(true)),
        };
        assert_eq!(
            client
                .start("rejected-start")
                .await
                .expect_err("closed queue")
                .code,
            "MODEL_DISPATCH_REJECTED"
        );
        assert_eq!(client.view().expect("state").phase, "stopped");
        assert!(!root.join("profile.json").exists());
        assert!(!root.join("process.json").exists());
        let restarted =
            Client::new(settings, true).expect("known not-dispatched outcome remains recoverable");
        assert_eq!(
            restarted
                .start("rejected-start")
                .await
                .expect("idempotent rejected outcome")
                .phase,
            "stopped"
        );
        assert_eq!(restarted.view().expect("view").failure.as_deref(), None);
        restarted.close();
    }
}
