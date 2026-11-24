use super::*;
use crate::{
    api::host::{ModelCacheView, ModelServiceView},
    service::{Client, Settings, cache_error},
};
use orange_model_runtime::cache::{CacheError, CacheState, ModelCache, StagingCleanup};

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
                || ipc.canonicalize().ok().as_ref() != Some(&client.settings().ipc)
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
        cancel: tokio::sync::watch::Receiver<bool>,
    ) -> Result<ModelServiceView, BridgeError> {
        let service = self.service(handle)?;
        if !matches!(service.view()?.phase.as_str(), "idle" | "stopped") {
            return Err(failure("MODEL_SERVICE_BUSY"));
        }
        let settings = service.settings();
        let cache =
            ModelCache::new(&settings.cache, 2 * 1024 * 1024 * 1024).map_err(cache_error)?;
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
    ) -> Result<ModelServiceView, BridgeError> {
        let service = self.service(handle)?;
        let installed = match service.settings().verified_weight().await {
            Ok(value) => value,
            Err(error) => {
                service.installed(false)?;
                return Err(error);
            }
        };
        let Some(weight) = installed else {
            service.installed(false)?;
            return Err(failure("MODEL_NOT_INSTALLED"));
        };
        service.installed(true)?;
        let view = service.start(request, weight).await?;
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
pub(crate) async fn inspect_model_service(handle: String) -> Result<ModelServiceView, BridgeError> {
    crate::actor::model_service(&handle)?.view()
}
pub(crate) async fn inspect_model_cache(handle: String) -> Result<ModelCacheView, BridgeError> {
    let client = crate::actor::model_service(&handle)?;
    let settings = client.settings();
    let state = ModelCache::observe(&settings.cache, &settings.bundle.spec()?)
        .await
        .map_err(cache_error)?;
    // Hashing may have outlived the initiating host handle.
    crate::actor::model_service(&handle)?;
    Ok(ModelCacheView {
        state: match state.state {
            CacheState::Absent => "absent",
            CacheState::Staged => "staged",
            CacheState::Verified => "verified",
            CacheState::Invalid => "invalid",
        }
        .into(),
        sha256: state.sha256,
        expected_bytes: state.expected_bytes.to_string(),
        download_staging_bytes: state.download_staging_bytes.map(|v| v.to_string()),
        import_staging_bytes: state.import_staging_bytes.map(|v| v.to_string()),
        read_lease_observed: state.read_lease_observed,
    })
}
pub(crate) async fn discard_model_staging(handle: String) -> Result<ModelCacheView, BridgeError> {
    let current = handle.clone();
    crate::actor::call(handle.clone(), move |host, _| {
        let client = host.service(&current)?;
        let settings = client.settings();
        let cache =
            ModelCache::new(&settings.cache, 2 * 1024 * 1024 * 1024).map_err(cache_error)?;
        match cache
            .discard_staging(&settings.bundle.spec()?)
            .map_err(cache_error)?
        {
            StagingCleanup::Released { .. } => Ok(()),
            StagingCleanup::RetainedForSubscribers | StagingCleanup::WriterBusy => {
                Err(failure("MODEL_CACHE_BUSY"))
            }
        }
    })
    .await?;
    inspect_model_cache(handle).await
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
) -> Result<ModelServiceView, BridgeError> {
    let client = crate::actor::model_service(&handle)?;
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
) -> Result<ModelServiceView, BridgeError> {
    let cancel = crate::actor::import_signal(&handle, &operation, &path)?;
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.import_selected_model(&handle, Path::new(&path), cancel))
    })
    .await
}
pub(crate) async fn download_model(
    handle: String,
    operation: String,
) -> Result<ModelServiceView, BridgeError> {
    let cancelled = crate::actor::download_signal(&handle, &operation)?;
    let checked = handle.clone();
    let client = crate::actor::call(handle.clone(), move |host, _| host.service(&checked)).await?;
    if !matches!(client.view()?.phase.as_str(), "idle" | "stopped") {
        return Err(failure("MODEL_SERVICE_BUSY"));
    }
    let settings = client.settings();
    let cache = ModelCache::new(&settings.cache, 2 * 1024 * 1024 * 1024).map_err(cache_error)?;
    let spec = settings.bundle.spec()?;
    if *cancelled.borrow() {
        return Err(failure("MODEL_DOWNLOAD_CANCELLED"));
    }
    // No database actor or UI queue is held during transport. The cache independently
    // owns the digest lock, resumable partial and verified atomic publication.
    // ModelCache itself owns bounded retries, range validation and digest verification.
    let result = match cache.ensure_with_cancel(&spec, cancelled.clone()).await {
        Err(error) if origin_unavailable(&error) => {
            let Some(alternate) = settings.bundle.alternate_spec()? else {
                return Err(cache_error(error));
            };
            eprintln!(
                "Reviewed model primary source unavailable; trying the pinned publisher alternate"
            );
            cache.ensure_with_cancel(&alternate, cancelled).await
        }
        result => result,
    };
    match result {
        Ok(_) => {}
        Err(CacheError::Cancelled) => {
            if !settings.check_installed().await? {
                return Err(failure("MODEL_DOWNLOAD_CANCELLED"));
            }
        }
        Err(error) => return Err(cache_error(error)),
    }
    let checked = handle.clone();
    crate::actor::call(handle, move |host, _| {
        let current = host.service(&checked)?;
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
) -> Result<ModelServiceView, BridgeError> {
    crate::actor::call(handle.clone(), move |host, rt| {
        rt.block_on(host.start_service(&handle, &request))
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

fn origin_unavailable(error: &CacheError) -> bool {
    matches!(
        error,
        CacheError::Timeout
            | CacheError::Connection
            | CacheError::Transport
            | CacheError::Incomplete
            | CacheError::Http(403 | 404 | 408 | 410 | 429 | 500..=599)
    )
}

#[cfg(test)]
mod origin_failover_tests {
    use super::*;
    #[test]
    fn only_source_unavailability_can_switch_to_the_reviewed_alternate() {
        assert!(origin_unavailable(&CacheError::Http(503)));
        assert!(origin_unavailable(&CacheError::Timeout));
        assert!(!origin_unavailable(&CacheError::Integrity));
        assert!(!origin_unavailable(&CacheError::Protocol));
        assert!(!origin_unavailable(&CacheError::Redirect));
        assert!(!origin_unavailable(&CacheError::Http(401)));
    }
}
