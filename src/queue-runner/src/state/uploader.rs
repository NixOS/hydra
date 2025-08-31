use backon::ExponentialBuilder;
use backon::Retryable as _;
use nix_utils::BaseStore as _;

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
    store_paths: std::sync::Arc<Vec<nix_utils::StorePath>>,
    log_remote_path: std::sync::Arc<String>,
    log_local_path: std::sync::Arc<String>,
}

#[derive(Debug)]
pub struct Uploader {
    queue: super::InspectableChannel<Message>,
    current_tasks: parking_lot::RwLock<Vec<Message>>,

    state_file_path: std::path::PathBuf,
}

impl Uploader {
    pub async fn new(state_file_path: std::path::PathBuf) -> Self {
        let uploader = Self {
            queue: super::InspectableChannel::with_capacity(1000),
            current_tasks: parking_lot::RwLock::new(Vec::with_capacity(10)),
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

    async fn save_state(&self) -> anyhow::Result<()> {
        let mut queue = self.queue.inspect();
        queue.extend(self.current_tasks.read().iter().cloned());
        let json = serde_json::to_string(&queue)?;
        fs_err::tokio::write(&self.state_file_path, json).await?;
        tracing::debug!("Saved uploader state to {}", self.state_file_path.display());
        Ok(())
    }

    async fn load_state(&self) -> anyhow::Result<()> {
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
        store_paths: Vec<nix_utils::StorePath>,
        log_remote_path: String,
        log_local_path: String,
    ) {
        tracing::info!("Scheduling new path upload: {:?}", store_paths);
        self.queue.send(Message {
            id: uuid::Uuid::new_v4(),
            store_paths: std::sync::Arc::new(store_paths),
            log_remote_path: std::sync::Arc::new(log_remote_path),
            log_local_path: std::sync::Arc::new(log_local_path),
        });
        let _ = self.save_state().await;
    }

    #[tracing::instrument(skip(self, local_store, remote_stores))]
    async fn upload_msg(
        &self,
        local_store: nix_utils::LocalStore,
        remote_stores: Vec<binary_cache::S3BinaryCacheClient>,
        msg: Message,
    ) {
        let span = tracing::info_span!("upload_msg", msg = ?msg);
        let _ = span.enter();
        tracing::info!("Start uploading {} paths", msg.store_paths.len());

        let paths_to_copy = match local_store
            .query_requisites(&msg.store_paths.iter().collect::<Vec<_>>(), true)
            .await
        {
            Ok(paths) => paths,
            Err(e) => {
                tracing::error!("Failed to query requisites: {e}");
                return;
            }
        };
        tracing::info!(
            "{} paths results in {} paths_to_copy",
            msg.store_paths.len(),
            paths_to_copy.len()
        );

        for remote_store in remote_stores {
            let bucket = &remote_store.cfg.client_config.bucket;

            // Upload log file with backon retry
            let log_upload_result = (|| async {
                let file = fs_err::tokio::File::open(msg.log_local_path.as_str()).await?;
                let reader = Box::new(tokio::io::BufReader::new(file));

                remote_store
                    .upsert_file_stream(&msg.log_remote_path, reader, "text/plain; charset=utf-8")
                    .await?;

                Ok::<(), anyhow::Error>(())
            })
            .retry(
                ExponentialBuilder::default()
                    .with_max_delay(std::time::Duration::from_secs(30))
                    .with_max_times(3),
            )
            .await;

            if let Err(e) = log_upload_result {
                tracing::error!("Failed to upload log file after retries: {e}");
            }

            let paths_to_copy = remote_store
                .query_missing_paths(paths_to_copy.clone())
                .await;
            tracing::info!(
                "{} paths missing in remote store that we be copied",
                paths_to_copy.len()
            );

            let copy_result = (|| async {
                remote_store
                    .copy_paths(&local_store, paths_to_copy.clone(), false)
                    .await?;

                Ok::<(), anyhow::Error>(())
            })
            .retry(
                ExponentialBuilder::default()
                    .with_max_delay(std::time::Duration::from_secs(60))
                    .with_max_times(5),
            )
            .await;

            if let Err(e) = copy_result {
                tracing::error!("Failed to copy paths after retries: {e}");
            } else {
                tracing::debug!(
                    "Successfully uploaded {} paths to bucket {bucket}",
                    msg.store_paths.len()
                );
            }
        }

        tracing::info!("Finished uploading {} paths", msg.store_paths.len());
    }

    #[tracing::instrument(skip(self, local_store, remote_stores))]
    pub async fn upload_once(
        &self,
        local_store: nix_utils::LocalStore,
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

        self.upload_msg(local_store, remote_stores, msg).await;

        {
            let mut current_tasks = self.current_tasks.write();
            current_tasks.retain(|v| v.id != msg_id);
        }
        let _ = self.save_state().await;
    }

    #[tracing::instrument(skip(self, local_store, remote_stores))]
    pub async fn upload_many(
        &self,
        local_store: nix_utils::LocalStore,
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

        let mut jobs = vec![];
        for msg in messages {
            jobs.push(self.upload_msg(local_store.clone(), remote_stores.clone(), msg));
        }
        futures::future::join_all(jobs).await;

        {
            let mut current_tasks = self.current_tasks.write();
            current_tasks.retain(|v| message_ids.contains(&v.id));
        }
        let _ = self.save_state().await;
    }

    pub fn len_of_queue(&self) -> usize {
        self.queue.len()
    }

    pub fn paths_in_queue(&self) -> Vec<nix_utils::StorePath> {
        self.queue
            .inspect()
            .into_iter()
            .flat_map(|m| m.store_paths.iter().cloned().collect::<Vec<_>>())
            .collect()
    }
}
