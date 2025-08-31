use backon::ExponentialBuilder;
use backon::Retryable;
use nix_utils::BaseStore as _;

// TODO: scheduling is shit, because if we crash/restart we need to start again as the builds are
//       already done in the db.
//       So we need to make this persistent!

#[derive(Debug)]
struct Message {
    store_paths: Vec<nix_utils::StorePath>,
    log_remote_path: String,
    log_local_path: String,
}

pub struct Uploader {
    upload_queue_sender: tokio::sync::mpsc::UnboundedSender<Message>,
    upload_queue_receiver: tokio::sync::Mutex<tokio::sync::mpsc::UnboundedReceiver<Message>>,
}

impl Default for Uploader {
    fn default() -> Self {
        Self::new()
    }
}

impl Uploader {
    pub fn new() -> Self {
        let (upload_queue_tx, upload_queue_rx) = tokio::sync::mpsc::unbounded_channel::<Message>();
        Self {
            upload_queue_sender: upload_queue_tx,
            upload_queue_receiver: tokio::sync::Mutex::new(upload_queue_rx),
        }
    }

    #[tracing::instrument(skip(self), err)]
    pub fn schedule_upload(
        &self,
        store_paths: Vec<nix_utils::StorePath>,
        log_remote_path: String,
        log_local_path: String,
    ) -> anyhow::Result<()> {
        tracing::info!("Scheduling new path upload: {:?}", store_paths);
        self.upload_queue_sender.send(Message {
            store_paths,
            log_remote_path,
            log_local_path,
        })?;
        Ok(())
    }

    #[tracing::instrument(skip(self, local_store, remote_stores))]
    async fn upload_msg(
        &self,
        local_store: nix_utils::LocalStore,
        remote_stores: Vec<binary_cache::S3BinaryCacheClient>,
        msg: Message,
    ) {
        tracing::info!("Uploading {} paths", msg.store_paths.len());

        let paths_to_copy = match local_store
            .query_requisites(&msg.store_paths.iter().collect::<Vec<_>>(), false)
            .await
        {
            Ok(paths) => paths,
            Err(e) => {
                tracing::error!("Failed to query requisites: {e}");
                return;
            }
        };

        for remote_store in remote_stores {
            let bucket = &remote_store.cfg.client_config.bucket;

            // Upload log file with backon retry
            let log_upload_result = (|| async {
                let file = fs_err::tokio::File::open(&msg.log_local_path).await?;
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
            if msg.store_paths.is_empty() {
                tracing::debug!("No NAR files to upload (presigned uploads enabled)");
            } else {
                let paths_to_copy = remote_store
                    .query_missing_paths(paths_to_copy.clone())
                    .await;

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
        }

        tracing::info!("Finished uploading {} paths", msg.store_paths.len());
    }

    pub async fn upload_once(
        &self,
        local_store: nix_utils::LocalStore,
        remote_stores: Vec<binary_cache::S3BinaryCacheClient>,
    ) {
        let Some(msg) = ({
            let mut rx = self.upload_queue_receiver.lock().await;
            rx.recv().await
        }) else {
            return;
        };

        self.upload_msg(local_store, remote_stores, msg).await;
    }

    pub async fn upload_many(
        &self,
        local_store: nix_utils::LocalStore,
        remote_stores: Vec<binary_cache::S3BinaryCacheClient>,
        limit: usize,
    ) {
        let mut messages: Vec<Message> = Vec::with_capacity(limit);
        self.upload_queue_receiver
            .lock()
            .await
            .recv_many(&mut messages, limit)
            .await;

        let mut jobs = vec![];
        for msg in messages {
            jobs.push(self.upload_msg(local_store.clone(), remote_stores.clone(), msg));
        }
        futures::future::join_all(jobs).await;
    }
}
