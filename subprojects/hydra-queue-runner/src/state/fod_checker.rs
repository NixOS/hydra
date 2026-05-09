use std::sync::Arc;

use harmonia_store_derivation::derivation::{Derivation, DerivationOutput};
use harmonia_store_path::StorePath;
use hashbrown::{HashMap, HashSet};

pub struct FodChecker {
    pool: harmonia_store_remote::ConnectionPool,
    ca_derivations: parking_lot::RwLock<HashMap<StorePath, Derivation>>,
    to_traverse: parking_lot::RwLock<HashSet<StorePath>>,

    notify_traverse: tokio::sync::Notify,
    traverse_done_notifier: Option<tokio::sync::mpsc::Sender<()>>,
}

impl std::fmt::Debug for FodChecker {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FodChecker")
            .field("ca_derivations_count", &self.ca_derivations.read().len())
            .field("to_traverse_count", &self.to_traverse.read().len())
            .finish()
    }
}

async fn collect_ca_derivations(
    store: &harmonia_store_remote::ConnectionPool,
    drv: &StorePath,
    processed: Arc<parking_lot::RwLock<HashSet<StorePath>>>,
) -> HashMap<StorePath, Derivation> {
    use futures::StreamExt as _;

    {
        let p = processed.read();
        if p.contains(drv) {
            return HashMap::new();
        }
    }
    {
        let mut p = processed.write();
        p.insert(drv.clone());
    }

    let parsed = async {
        let drv_path_str = store.store_dir().display(drv).to_string();
        let content = fs_err::tokio::read_to_string(&drv_path_str).await.ok()?;
        let drv_name_str = drv.name().to_string();
        let name = drv_name_str.strip_suffix(".drv")?.parse().ok()?;
        harmonia_store_aterm::parse_derivation_aterm(store.store_dir(), content.as_bytes(), name)
            .ok()
    }
    .await;
    let Some(parsed) = parsed as Option<Derivation> else {
        return HashMap::new();
    };

    let ca_fixed_hash = parsed.outputs.values().find_map(|o| match o {
        DerivationOutput::CAFixed(ca) => Some(ca.hash()),
        _ => None,
    });
    let input_drvs: Vec<StorePath> =
        harmonia_store_derivation::derivation::DerivationInputs::from(&parsed.inputs)
            .drvs
            .into_keys()
            .collect();
    let mut out = if input_drvs.is_empty() {
        HashMap::new()
    } else {
        futures::StreamExt::map(tokio_stream::iter(input_drvs), |i| {
            let processed = processed.clone();
            async move { Box::pin(collect_ca_derivations(store, &i, processed)).await }
        })
        .buffered(10)
        .flat_map(futures::stream::iter)
        .collect::<HashMap<_, _>>()
        .await
    };
    if ca_fixed_hash.is_some() {
        out.insert(drv.clone(), parsed);
    }

    out
}

impl FodChecker {
    #[must_use]
    pub fn new(
        pool: harmonia_store_remote::ConnectionPool,
        traverse_done_notifier: Option<tokio::sync::mpsc::Sender<()>>,
    ) -> Self {
        Self {
            pool,
            ca_derivations: parking_lot::RwLock::new(HashMap::with_capacity(1000)),
            to_traverse: parking_lot::RwLock::new(HashSet::new()),

            notify_traverse: tokio::sync::Notify::new(),
            traverse_done_notifier,
        }
    }

    pub(super) fn add_ca_drv_parsed(&self, drv: &StorePath, parsed: &Derivation) {
        let ca_fixed_hash = parsed.outputs.values().find_map(|o| match o {
            DerivationOutput::CAFixed(ca) => Some(ca.hash()),
            _ => None,
        });
        if ca_fixed_hash.is_some() {
            let mut ca = self.ca_derivations.write();
            ca.insert(drv.clone(), parsed.clone());
        }
    }

    pub fn to_traverse(&self, drv: &StorePath) {
        let mut tt = self.to_traverse.write();
        tt.insert(drv.clone());
    }

    async fn traverse(&self, store: &harmonia_store_remote::ConnectionPool) {
        use futures::StreamExt as _;

        let drvs = {
            let mut tt = self.to_traverse.write();
            let v: Vec<_> = tt.iter().map(Clone::clone).collect();
            tt.clear();
            v
        };

        let processed = Arc::new(parking_lot::RwLock::new(HashSet::<StorePath>::new()));
        let out = futures::StreamExt::map(tokio_stream::iter(drvs), |i| {
            let processed = processed.clone();
            async move { Box::pin(collect_ca_derivations(store, &i, processed)).await }
        })
        .buffered(10)
        .flat_map(futures::stream::iter)
        .collect::<HashMap<_, _>>()
        .await;

        {
            let mut ca_derivations = self.ca_derivations.write();
            ca_derivations.extend(out);
        }
        tracing::info!("ca count: {}", self.ca_derivations.read().len());
    }

    #[tracing::instrument(skip(self))]
    pub fn trigger_traverse(&self) {
        self.notify_traverse.notify_one();
    }

    #[tracing::instrument(skip(self))]
    async fn traverse_loop(&self) {
        loop {
            tokio::select! {
                () = self.notify_traverse.notified() => {},
                () = tokio::time::sleep(tokio::time::Duration::from_secs(60)) => {},
            };
            self.traverse(&self.pool).await;
            if let Some(tx) = &self.traverse_done_notifier {
                let _ = tx.send(()).await;
            }
        }
    }

    pub fn start_traverse_loop(self: Arc<Self>) -> tokio::task::AbortHandle {
        let task = tokio::task::spawn(async move {
            Box::pin(self.traverse_loop()).await;
        });
        task.abort_handle()
    }

    pub async fn process<F>(&self, processor: F) -> i64
    where
        F: AsyncFn(StorePath, Derivation) -> (),
    {
        let drvs = {
            let mut drvs = self.ca_derivations.write();
            let cloned = drvs.clone();
            drvs.clear();
            cloned
        };

        let mut c = 0;
        for (path, drv) in drvs {
            processor(path, drv).await;
            c += 1;
        }

        c
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use crate::state::fod_checker::FodChecker;
    use harmonia_store_path::StorePath;

    #[ignore = "Requires a valid drv in the nix-store"]
    #[tokio::test]
    async fn test_traverse() {
        let nix_config = daemon_client_utils::parse_nix_remote().unwrap();
        let store = harmonia_store_remote::ConnectionPool::new(
            &nix_config.socket,
            harmonia_store_remote::PoolConfig::default(),
        );
        let hello_drv =
            StorePath::from_base_path("rl5m4zxd24mkysmpbp4j9ak6q7ia6vj8-hello-2.12.2.drv").unwrap();
        daemon_client_utils::ensure_path(&store, &hello_drv)
            .await
            .unwrap();

        let fod = FodChecker::new(store.clone(), None);
        fod.to_traverse(&hello_drv);
        fod.traverse(&fod.pool).await;
        assert_eq!(fod.ca_derivations.read().len(), 59);
    }
}
