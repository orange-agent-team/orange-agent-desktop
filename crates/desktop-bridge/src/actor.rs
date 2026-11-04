//! One SQLite owner thread. Model waits never hold the public registry mutex;
//! cancellation/revocation is signalled before queued durable work is awaited.
use crate::{
    api::host::{BridgeError, HostView},
    host::{HostRegistry, failure},
};
use orange_agent_runtime::workspaces::WorkspaceRevoker;
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::{
        Arc, LazyLock, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::Duration,
};
use tokio::sync::{oneshot, watch};

pub(crate) struct RunSignal {
    pub workspace: String,
    pub cancel: watch::Sender<bool>,
}
#[derive(Default)]
pub(crate) struct Signals {
    pub workspaces: HashMap<String, (String, WorkspaceRevoker)>,
    pub runs: HashMap<String, RunSignal>,
}
impl Signals {
    pub fn stop_all(&self) {
        for (_, revoker) in self.workspaces.values() {
            revoker.request_revoke();
        }
        for run in self.runs.values() {
            run.cancel.send_replace(true);
        }
    }
}
type Task = Box<dyn FnOnce(&mut HostRegistry, &tokio::runtime::Runtime) + Send>;
struct Session {
    root: PathBuf,
    view: HostView,
    queue: mpsc::SyncSender<Task>,
    signals: Arc<Mutex<Signals>>,
    closed: Arc<AtomicBool>,
}
static SESSION: LazyLock<Mutex<Option<Session>>> = LazyLock::new(|| Mutex::new(None));
struct WorkerLifetime {
    closed: Arc<AtomicBool>,
    signals: Arc<Mutex<Signals>>,
}
impl Drop for WorkerLifetime {
    fn drop(&mut self) {
        self.closed.store(true, Ordering::Release);
        if let Ok(signals) = self.signals.lock() {
            signals.stop_all();
        }
    }
}

pub(crate) fn initialize(path: &Path) -> Result<HostView, BridgeError> {
    let mut registry = SESSION.lock().map_err(|_| failure("HOST_INTERNAL"))?;
    if registry
        .as_ref()
        .is_some_and(|session| session.closed.load(Ordering::Acquire))
    {
        registry.take();
    }
    if let Some(session) = registry.as_ref() {
        if path.canonicalize().ok().as_ref() != Some(&session.root) {
            return Err(failure("HOST_CONTEXT_CHANGED"));
        }
        return Ok(session.view.clone());
    }
    let (queue, receiver) = mpsc::sync_channel::<Task>(32);
    let (initial, ready) = mpsc::sync_channel(1);
    let signals = Arc::new(Mutex::new(Signals::default()));
    let closed = Arc::new(AtomicBool::new(false));
    let owned_path = path.to_owned();
    let worker_signals = signals.clone();
    let worker_closed = closed.clone();
    std::thread::Builder::new()
        .name("orange-local-host".into())
        .spawn(move || {
            let _lifetime = WorkerLifetime {
                closed: worker_closed.clone(),
                signals: worker_signals.clone(),
            };
            let runtime = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(runtime) => runtime,
                Err(_) => {
                    let _ = initial.send(Err(failure("HOST_RUNTIME_UNAVAILABLE")));
                    return;
                }
            };
            let mut host = HostRegistry::with_signals(worker_signals);
            let view = match host.initialize(&owned_path) {
                Ok(view) => view,
                Err(error) => {
                    let _ = initial.send(Err(error));
                    return;
                }
            };
            if initial.send(Ok(view)).is_err() {
                return;
            }
            while let Ok(task) = receiver.recv() {
                if worker_closed.load(Ordering::Acquire) {
                    break;
                }
                task(&mut host, &runtime);
            }
            drop(host);
            runtime.shutdown_timeout(Duration::from_secs(1));
        })
        .map_err(|_| failure("HOST_RUNTIME_UNAVAILABLE"))?;
    let view = match ready.recv_timeout(Duration::from_secs(10)) {
        Ok(result) => result?,
        Err(_) => {
            closed.store(true, Ordering::Release);
            return Err(failure("HOST_STARTUP_UNCONFIRMED"));
        }
    };
    let root = path
        .canonicalize()
        .map_err(|_| failure("STORAGE_UNAVAILABLE"))?;
    *registry = Some(Session {
        root,
        view: view.clone(),
        queue,
        signals,
        closed,
    });
    Ok(view)
}
pub(crate) fn inspect(handle: &str) -> Result<HostView, BridgeError> {
    let registry = SESSION.lock().map_err(|_| failure("HOST_INTERNAL"))?;
    let session = registry
        .as_ref()
        .filter(|s| s.view.handle == handle && !s.closed.load(Ordering::Acquire))
        .ok_or_else(|| failure("STALE_HOST_HANDLE"))?;
    Ok(session.view.clone())
}
pub(crate) fn close(handle: &str) -> Result<(), BridgeError> {
    let mut registry = SESSION.lock().map_err(|_| failure("HOST_INTERNAL"))?;
    if !registry.as_ref().is_some_and(|s| s.view.handle == handle) {
        return Err(failure("STALE_HOST_HANDLE"));
    }
    if let Some(session) = registry.take() {
        session.closed.store(true, Ordering::Release);
        session
            .signals
            .lock()
            .map_err(|_| failure("HOST_INTERNAL"))?
            .stop_all();
        // Dropping the only stored sender wakes an idle owner. Running work sees
        // its cancellation signal; no resource-release claim is made here.
    }
    Ok(())
}
pub(crate) async fn call<T, F>(handle: String, operation: F) -> Result<T, BridgeError>
where
    T: Send + 'static,
    F: FnOnce(&mut HostRegistry, &tokio::runtime::Runtime) -> Result<T, BridgeError>
        + Send
        + 'static,
{
    let (queue, closed) = {
        let registry = SESSION.lock().map_err(|_| failure("HOST_INTERNAL"))?;
        let session = registry
            .as_ref()
            .filter(|s| s.view.handle == handle && !s.closed.load(Ordering::Acquire))
            .ok_or_else(|| failure("STALE_HOST_HANDLE"))?;
        (session.queue.clone(), session.closed.clone())
    };
    let (reply, response) = oneshot::channel();
    let guard = closed.clone();
    queue
        .try_send(Box::new(move |host, runtime| {
            let result = if guard.load(Ordering::Acquire) {
                Err(failure("STALE_HOST_HANDLE"))
            } else {
                operation(host, runtime)
            };
            let _ = reply.send(result);
        }))
        .map_err(|e| match e {
            mpsc::TrySendError::Full(_) => failure("HOST_BUSY"),
            mpsc::TrySendError::Disconnected(_) => failure("HOST_UNAVAILABLE"),
        })?;
    drop(queue);
    let result = response.await.map_err(|_| failure("HOST_UNAVAILABLE"));
    if closed.load(Ordering::Acquire) {
        return Err(failure("STALE_HOST_HANDLE"));
    }
    result?
}
pub(crate) fn signal_cancel(handle: &str, run: &str) -> Result<(), BridgeError> {
    let registry = SESSION.lock().map_err(|_| failure("HOST_INTERNAL"))?;
    let session = registry
        .as_ref()
        .filter(|s| s.view.handle == handle)
        .ok_or_else(|| failure("STALE_HOST_HANDLE"))?;
    let signals = session
        .signals
        .lock()
        .map_err(|_| failure("HOST_INTERNAL"))?;
    if let Some(run) = signals.runs.get(run) {
        run.cancel.send_replace(true);
    }
    Ok(())
}
pub(crate) fn signal_revoke(
    handle: &str,
    workspace: &str,
    version: &str,
) -> Result<(), BridgeError> {
    let registry = SESSION.lock().map_err(|_| failure("HOST_INTERNAL"))?;
    let session = registry
        .as_ref()
        .filter(|s| s.view.handle == handle)
        .ok_or_else(|| failure("STALE_HOST_HANDLE"))?;
    let signals = session
        .signals
        .lock()
        .map_err(|_| failure("HOST_INTERNAL"))?;
    if let Some((current, revoker)) = signals.workspaces.get(workspace) {
        if current != version {
            return Err(failure("WORKSPACE_CONFLICT"));
        }
        revoker.request_revoke();
        for run in signals
            .runs
            .values()
            .filter(|run| run.workspace == workspace)
        {
            run.cancel.send_replace(true);
        }
    }
    Ok(())
}
