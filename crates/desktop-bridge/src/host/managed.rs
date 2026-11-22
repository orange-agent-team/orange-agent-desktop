use super::*;
use crate::{
    api::host::ModelServiceView,
    service::{Client, Settings, cache_error},
};
use orange_model_runtime::cache::ModelCache;

impl HostRegistry {
    async fn configure_service(
        &mut self,
        handle: &str,
        contents: &Path,
        ipc: &Path,
        os: &str,
    ) -> Result<ModelServiceView, BridgeError> {
        let signals = self.signals.clone();
        let host = self.current(handle)?;
        if let Some(client) = &host.service {
            if contents.canonicalize().ok().as_ref() != Some(&client.settings().bundle.contents)
                || ipc.canonicalize().ok().as_deref() != Some(client.settings().base_ipc())
            {
                return Err(failure("MODEL_SERVICE_CONTEXT_CHANGED"));
            }
            return client.view();
        }
        let settings = Settings::prepare(
            &host.root,
            contents,
            ipc,
            os,
            &host.view.runtime_source_commit,
        )?;
        host.journal
            .reserve_private_directory(&settings.ipc)
            .map_err(workspace_error)?;
        let installed = settings.check_installed().await?;
        let client = Client::new(settings, installed)?;
        let view = client.view()?;
        signals
            .lock()
            .map_err(|_| failure("HOST_INTERNAL"))?
            .service = Some(client.clone());
        host.service = Some(client);
        Ok(view)
    }
    async fn select_profile(
        &mut self,
        handle: &str,
        id: &str,
        expected: &str,
    ) -> Result<ModelServiceView, BridgeError> {
        let signals = self.signals.clone();
        let host = self.current(handle)?;
        let old = host
            .service
            .clone()
            .ok_or_else(|| failure("MODEL_SERVICE_NOT_CONFIGURED"))?;
        let previous = old.settings();
        let next = previous.selection.next(id, expected)?;
        if next == previous.selection {
            return old.view();
        }
        if host.model.is_some() || !matches!(old.view()?.phase.as_str(), "idle" | "stopped") {
            return Err(failure("MODEL_SERVICE_BUSY"));
        }
        let settings = Settings::for_selection(
            &host.root,
            previous.bundle.clone(),
            previous.base_ipc(),
            next,
        )?;
        host.journal
            .reserve_private_directory(&settings.ipc)
            .map_err(workspace_error)?;
        let installed = settings.check_installed().await?;
        let mut live = signals.lock().map_err(|_| failure("HOST_INTERNAL"))?;
        if !live.imports.is_empty() {
            return Err(failure("MODEL_SERVICE_BUSY"));
        }
        let new = Client::new(settings, installed)?;
        let view = new.view()?;
        if let Err(error) = next.save(&host.root) {
            new.close();
            return Err(error);
        }
        old.close();
        host.service = Some(new.clone());
        live.service = Some(new);
        Ok(view)
    }
    fn service(&mut self, handle: &str) -> Result<Client, BridgeError> {
        self.current(handle)?
            .service
            .clone()
            .ok_or_else(|| failure("MODEL_SERVICE_NOT_CONFIGURED"))
    }
    async fn import_selected_model(
        &mut self,
        handle: &str,
        path: &Path,
        revision: Option<&str>,
        cancel: tokio::sync::watch::Receiver<bool>,
    ) -> Result<ModelServiceView, BridgeError> {
        let service = self.service(handle)?;
        service.settings().selection.require(revision)?;
        if !matches!(service.view()?.phase.as_str(), "idle" | "stopped") {
            return Err(failure("MODEL_SERVICE_BUSY"));
        }
        let settings = service.settings();
        let cache = ModelCache::new(&settings.cache, settings.selection.profile.quota())
            .map_err(cache_error)?;
        cache
            .import_file_with_cancel(&settings.bundle.spec()?, path, cancel)
            .await
            .map_err(cache_error)?;
        service.installed(true)?;
        service.view()
    }
    async fn start_service(
        &mut self,
        handle: &str,
        request: &str,
        revision: Option<&str>,
    ) -> Result<ModelServiceView, BridgeError> {
        let service = self.service(handle)?;
        service.settings().selection.require(revision)?;
        let installed = match service.settings().check_installed().await {
            Ok(value) => value,
            Err(error) => {
                service.installed(false)?;
                return Err(error);
            }
        };
        if !installed {
            service.installed(false)?;
            return Err(failure("MODEL_NOT_INSTALLED"));
        }
        service.installed(true)?;
        let view = service.start(request).await?;
        if view.phase == "ready" {
            let root = service.settings().root.clone();
            self.connect_managed_gateway(handle, &root).await?;
        }
        Ok(view)
    }
    async fn connect_managed_gateway(
        &mut self,
        handle: &str,
        root: &Path,
    ) -> Result<(), BridgeError> {
        self.connect_model(handle, root).await?;
        Ok(())
    }
    async fn stop_service(
        &mut self,
        handle: &str,
        instance: &str,
    ) -> Result<ModelServiceView, BridgeError> {
        let service = self.service(handle)?;
        let view = service.view()?;
        if view.instance_id.as_deref() != Some(instance) {
            return Err(failure("MODEL_INSTANCE_CHANGED"));
        }
        let runs = self
            .signals
            .lock()
            .map_err(|_| failure("HOST_INTERNAL"))?
            .runs
            .keys()
            .cloned()
            .collect::<Vec<_>>();
        let host = self.current(handle)?;
        for run in runs {
            let view = host
                .journal
                .agent_view(LOCAL_OWNER, &run)
                .map_err(|_| failure("RUN_STORAGE_UNAVAILABLE"))?;
            if matches!(
                view.phase,
                orange_agent_runtime::engine::Phase::Ready
                    | orange_agent_runtime::engine::Phase::ModelPending
                    | orange_agent_runtime::engine::Phase::ToolsPending
                    | orange_agent_runtime::engine::Phase::AwaitingUser
            ) {
                host.journal
                    .cancel_agent_run(LOCAL_OWNER, &run)
                    .map_err(|_| failure("RUN_STORAGE_UNAVAILABLE"))?;
            }
        }
        self.current(handle)?.model = None;
        service.stop(instance).await
    }
}
pub(crate) async fn configure_model_service(
    handle: String,
    contents: String,
    ipc: String,
    os: String,
) -> Result<ModelServiceView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.configure_service(&handle, Path::new(&contents), Path::new(&ipc), &os))
    })
    .await
}
pub(crate) async fn select_model_profile(
    handle: String,
    id: String,
    expected: String,
) -> Result<ModelServiceView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.select_profile(&handle, &id, &expected))
    })
    .await
}
pub(crate) async fn inspect_model_service(handle: String) -> Result<ModelServiceView, BridgeError> {
    crate::actor::model_service(&handle)?.view()
}
pub(crate) async fn current_model_connection(
    handle: String,
) -> Result<crate::api::host::ModelConnectionView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        let service = host.service(&handle)?;
        if !service.ready() {
            return Err(failure("MODEL_SERVICE_UNAVAILABLE"));
        }
        if host.current(&handle)?.model.is_none() {
            rt.block_on(host.connect_managed_gateway(&handle, &service.settings().root))?;
        }
        host.current(&handle)?
            .model
            .as_ref()
            .map(|model| model.view.clone())
            .ok_or_else(|| failure("MODEL_NOT_CONFIGURED"))
    })
    .await
}
pub(crate) async fn cancel_model_start(
    handle: String,
    request: String,
    revision: Option<String>,
) -> Result<ModelServiceView, BridgeError> {
    let client = crate::actor::model_service(&handle)?;
    client.settings().selection.require(revision.as_deref())?;
    if let Some(instance) = client.cancel_request(&request)? {
        stop_model_service(handle, instance).await
    } else {
        client.view()
    }
}
pub(crate) async fn import_model(
    handle: String,
    operation: String,
    path: String,
    revision: Option<String>,
) -> Result<ModelServiceView, BridgeError> {
    let cancel = crate::actor::import_signal(&handle, &operation, &path, revision.as_deref())?;
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.import_selected_model(
            &handle,
            Path::new(&path),
            revision.as_deref(),
            cancel,
        ))
    })
    .await
}
pub(crate) async fn download_model(
    handle: String,
    operation: String,
    revision: Option<String>,
) -> Result<ModelServiceView, BridgeError> {
    let mut cancelled = crate::actor::download_signal(&handle, &operation, revision.as_deref())?;
    let checked = handle.clone();
    let client = crate::actor::call(handle.clone(), move |host, _| host.service(&checked)).await?;
    client.settings().selection.require(revision.as_deref())?;
    if client.settings().selection.profile == crate::service::Profile::SevenB {
        return Err(failure("MODEL_PROFILE_IMPORT_ONLY"));
    }
    if !matches!(client.view()?.phase.as_str(), "idle" | "stopped") {
        return Err(failure("MODEL_SERVICE_BUSY"));
    }
    let settings = client.settings();
    let cache = ModelCache::new(&settings.cache, settings.selection.profile.quota())
        .map_err(cache_error)?;
    let spec = settings.bundle.spec()?;
    if *cancelled.borrow() {
        return Err(failure("MODEL_DOWNLOAD_CANCELLED"));
    }
    // No database actor or UI queue is held during transport. The cache independently
    // owns the digest lock, resumable partial and verified atomic publication.
    // ModelCache itself owns bounded retries, range validation and digest verification.
    let verified = tokio::select! {
        biased;
        _=cancelled.changed()=>false,
        result=cache.ensure(&spec)=>{result.map_err(cache_error)?;true}
    };
    if !verified && !settings.check_installed().await? {
        return Err(failure("MODEL_DOWNLOAD_CANCELLED"));
    }
    let checked = handle.clone();
    crate::actor::call(handle, move |host, _| {
        let current = host.service(&checked)?;
        if current.settings().selection != client.settings().selection {
            return Err(failure("MODEL_SELECTION_CHANGED"));
        }
        current.installed(true)?;
        current.view()
    })
    .await
}
pub(crate) async fn close_model_import(
    handle: String,
    operation: String,
) -> Result<(), BridgeError> {
    close_model_transfer(handle, operation, false).await
}
pub(crate) async fn close_model_download(
    handle: String,
    operation: String,
) -> Result<(), BridgeError> {
    close_model_transfer(handle, operation, true).await
}
async fn close_model_transfer(
    handle: String,
    operation: String,
    download: bool,
) -> Result<(), BridgeError> {
    crate::actor::close_import_signal(&handle, &operation, download)?;
    crate::actor::call(handle, move |host, _| {
        host.signals
            .lock()
            .map_err(|_| failure("HOST_INTERNAL"))?
            .imports
            .remove(&operation);
        Ok(())
    })
    .await
}
pub(crate) async fn start_model_service(
    handle: String,
    request: String,
    revision: Option<String>,
) -> Result<ModelServiceView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.start_service(&handle, &request, revision.as_deref()))
    })
    .await
}
pub(crate) async fn stop_model_service(
    handle: String,
    instance: String,
) -> Result<ModelServiceView, BridgeError> {
    crate::actor::stop_model_signal(&handle, &instance)?;
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.stop_service(&handle, &instance))
    })
    .await
}
