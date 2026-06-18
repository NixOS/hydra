use std::sync::Arc;

use backon::ExponentialBuilder;
use backon::Retryable as _;
use harmonia_store_path::StorePath;

#[derive(Debug, thiserror::Error)]
pub(crate) enum UploaderError {
    #[error("uploader state I/O")]
    Io(#[from] std::io::Error),
    #[error("(de)serializing uploader state")]
    Json(#[from] serde_json::Error),
    #[error(transparent)]
    Cache(#[from] binary_cache::CacheError),
}

#[allow(clippy::unnecessary_wraps)]
fn deserialize_with_new_v4<'de, D>(_: D) -> Result<uuid::Uuid, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Ok(uuid::Uuid::new_v4())
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
struct Message {
    #[serde(skip_serializing, deserialize_with = "deserialize_with_new_v4")]
    id: uuid::Uuid,
    store_paths: Arc<Vec<StorePath>>,
    log_remote_path: Arc<String>,
    log_local_path: Arc<std::path::PathBuf>,
    /// Drv path to report on the completion channel once the upload was
    /// attempted. Set for steps whose finished flag is gated on the upload.
    #[serde(default)]
    notify_drv: Option<StorePath>,
}

#[derive(Debug)]
pub struct Uploader {
    queue: super::InspectableChannel<Message>,
    current_tasks: parking_lot::RwLock<Vec<Message>>,
    completion_tx: tokio::sync::mpsc::UnboundedSender<StorePath>,

    state_file_path: std::path::PathBuf,
}

impl Uploader {
    pub async fn new(
        state_file_path: std::path::PathBuf,
        completion_tx: tokio::sync::mpsc::UnboundedSender<StorePath>,
    ) -> Self {
        let uploader = Self {
            queue: super::InspectableChannel::with_capacity(1000),
            current_tasks: parking_lot::RwLock::new(Vec::with_capacity(10)),
            completion_tx,
            state_file_path,
        };

        if let Err(e) = uploader.load_state().await {
            tracing::warn!(
                "Failed to load uploader state from {}: {}",
                uploader.state_file_path.display(),
                e
            );
        }

        uploader
    }

    async fn save_state(&self) -> Result<(), UploaderError> {
        let mut queue = self.queue.inspect();
        queue.extend(self.current_tasks.read().iter().cloned());
        let json = serde_json::to_string(&queue)?;
        fs_err::tokio::write(&self.state_file_path, json).await?;
        tracing::debug!("Saved uploader state to {}", self.state_file_path.display());
        Ok(())
    }

    async fn load_state(&self) -> Result<(), UploaderError> {
        if !self.state_file_path.exists() {
            tracing::info!(
                "Uploader state file {} does not exist, starting with empty queue",
                self.state_file_path.display()
            );
            return Ok(());
        }

        let content = fs_err::tokio::read_to_string(&self.state_file_path).await?;
        self.queue.load_vec_into(serde_json::from_str(&content)?);
        tracing::info!(
            "Loaded uploader state from {} with {} items",
            self.state_file_path.display(),
            self.queue.len()
        );
        Ok(())
    }

    #[tracing::instrument(skip(self))]
    pub async fn schedule_upload(
        &self,
        store_paths: Vec<StorePath>,
        log_remote_path: String,
        log_local_path: std::path::PathBuf,
        notify_drv: Option<StorePath>,
    ) {
        tracing::info!("Scheduling new path upload: {:?}", store_paths);
        self.queue.send(Message {
            id: uuid::Uuid::new_v4(),
            store_paths: Arc::new(store_paths),
            log_remote_path: Arc::new(log_remote_path),
            log_local_path: Arc::new(log_local_path),
            notify_drv,
        });
        let _ = self.save_state().await;
    }

    #[tracing::instrument(skip(self, local_db, local_store, remote_stores))]
    async fn upload_msg(
        &self,
        local_db: crate::local_db::LocalNixDb,
        local_store: daemon_client_utils::DaemonConnector,
        remote_stores: Vec<binary_cache::S3BinaryCacheClient>,
        msg: Message,
    ) {
        self.upload_msg_inner(local_db, local_store, remote_stores, &msg)
            .await;
        if let Some(drv) = &msg.notify_drv {
            // Reported even when the upload failed: the gated step then
            // finishes anyway and dependents fall back to substituting the
            // inputs themselves, instead of hanging forever.
            let _ = self.completion_tx.send(drv.clone());
        }
    }

    #[tracing::instrument(skip(self, local_db, local_store, remote_stores))]
    async fn upload_msg_inner(
        &self,
        local_db: crate::local_db::LocalNixDb,
        local_store: daemon_client_utils::DaemonConnector,
        remote_stores: Vec<binary_cache::S3BinaryCacheClient>,
        msg: &Message,
    ) {
        let span = tracing::info_span!("upload_msg", msg = ?msg);
        let _ = span.enter();
        tracing::info!("Start uploading {} paths", msg.store_paths.len());

        let closure = match local_db.query_closure_infos(msg.store_paths.to_vec()).await {
            Ok(c) => c,
            Err(e) => {
                tracing::error!("Failed to query requisites: {e}");
                return;
            }
        };
        tracing::info!(
            "{} paths results in {} paths_to_copy",
            msg.store_paths.len(),
            closure.len()
        );

        let store_dir = local_store.store_dir().clone();
        for remote_store in remote_stores {
            if let Err(e) = Self::upload_to_store(&remote_store, &store_dir, msg, &closure).await {
                // Non-fatal: per-store failure shouldn't block other
                // stores. Outputs remain in the local store.
                tracing::error!(
                    "Failed to upload to {}: {e:#}",
                    remote_store.cfg.client_config.bucket,
                );
            }
        }

        tracing::info!(
            "Finished attempting to upload {} paths to remotes stores",
            msg.store_paths.len()
        );
    }

    /// Upload log + NARs to a single remote store. Returns `Err` if
    /// anything goes wrong (after retries).
    async fn upload_to_store(
        remote_store: &binary_cache::S3BinaryCacheClient,
        store_dir: &harmonia_store_path::StoreDir,
        msg: &Message,
        closure: &[harmonia_store_path_info::ValidPathInfo],
    ) -> Result<(), UploaderError> {
        // Steps that did not run here (substituted paths, builds finished
        // before a restart) have no log file. A missing log must not block
        // the NAR upload.
        match fs_err::tokio::metadata(msg.log_local_path.as_path()).await {
            Ok(_) => {
                (|| async {
                    let file = fs_err::tokio::File::open(msg.log_local_path.as_path()).await?;
                    let reader = Box::new(tokio::io::BufReader::new(file));
                    remote_store
                        .upsert_file_stream(
                            &msg.log_remote_path,
                            reader,
                            "text/plain; charset=utf-8",
                        )
                        .await?;
                    Ok::<(), UploaderError>(())
                })
                .retry(
                    ExponentialBuilder::default()
                        .with_max_delay(std::time::Duration::from_secs(30))
                        .with_max_times(3),
                )
                .await?;
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                tracing::warn!(
                    "no build log at {}, skipping log upload",
                    msg.log_local_path.display()
                );
            }
            Err(e) => return Err(e.into()),
        }

        // Copy NARs
        let missing_paths: hashbrown::HashSet<StorePath> = remote_store
            .query_missing_paths(closure.iter().map(|vpi| vpi.path.clone()).collect())
            .await
            .into_iter()
            .collect();
        let paths_to_copy: Vec<_> = closure
            .iter()
            .filter(|vpi| missing_paths.contains(&vpi.path))
            .cloned()
            .collect();
        tracing::info!(
            "{} paths missing in remote store that will be copied",
            paths_to_copy.len()
        );

        (|| async {
            remote_store
                .copy_paths(store_dir, paths_to_copy.clone(), false)
                .await?;
            Ok::<(), UploaderError>(())
        })
        .retry(
            ExponentialBuilder::default()
                .with_max_delay(std::time::Duration::from_mins(1))
                .with_max_times(5),
        )
        .await?;

        tracing::debug!(
            "Successfully uploaded {} paths to bucket {}",
            msg.store_paths.len(),
            remote_store.cfg.client_config.bucket,
        );
        Ok(())
    }

    #[tracing::instrument(skip(self, local_db, local_store, remote_stores))]
    pub async fn upload_once(
        &self,
        local_db: crate::local_db::LocalNixDb,
        local_store: daemon_client_utils::DaemonConnector,
        remote_stores: Vec<binary_cache::S3BinaryCacheClient>,
    ) {
        let Some(msg) = self.queue.recv().await else {
            return;
        };
        let msg_id = msg.id;
        {
            let mut current_tasks = self.current_tasks.write();
            current_tasks.push(msg.clone());
        }

        self.upload_msg(local_db, local_store, remote_stores, msg)
            .await;

        {
            let mut current_tasks = self.current_tasks.write();
            current_tasks.retain(|v| v.id != msg_id);
        }
        let _ = self.save_state().await;
    }

    #[tracing::instrument(skip(self, local_db, local_store, remote_stores))]
    pub async fn upload_many(
        self: &Arc<Self>,
        local_db: crate::local_db::LocalNixDb,
        local_store: daemon_client_utils::DaemonConnector,
        remote_stores: Vec<binary_cache::S3BinaryCacheClient>,
        limit: usize,
    ) {
        let messages = self.queue.recv_many(limit).await;
        if messages.is_empty() {
            tokio::task::yield_now().await;
            return;
        }
        let message_ids = messages.iter().map(|m| m.id).collect::<Vec<_>>();
        {
            let mut current_tasks = self.current_tasks.write();
            current_tasks.extend(messages.iter().cloned());
        }

        // Spawn a task per upload so NAR compression runs on multiple worker
        // threads instead of interleaving on one.
        let mut jobs = tokio::task::JoinSet::new();
        for msg in messages {
            let this = self.clone();
            let local_db = local_db.clone();
            let local_store = local_store.clone();
            let remote_stores = remote_stores.clone();
            jobs.spawn(async move {
                this.upload_msg(local_db, local_store, remote_stores, msg)
                    .await;
            });
        }
        while let Some(res) = jobs.join_next().await {
            if let Err(e) = res {
                tracing::error!("Upload task panicked: {e}");
            }
        }

        {
            let mut current_tasks = self.current_tasks.write();
            current_tasks.retain(|v| message_ids.contains(&v.id));
        }
        let _ = self.save_state().await;
    }

    pub fn len_of_queue(&self) -> usize {
        self.queue.len()
    }

    pub fn paths_in_queue(&self) -> Vec<StorePath> {
        self.queue
            .inspect()
            .into_iter()
            .flat_map(|m| m.store_paths.iter().cloned().collect::<Vec<_>>())
            .collect()
    }
}
