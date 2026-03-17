use std::sync::Arc;

use hashbrown::{HashMap, HashSet};
use nix_utils::{Derivation, LocalStore, StorePath};

#[derive(Debug)]
pub struct FodChecker {
    ca_derivations: parking_lot::RwLock<HashMap<StorePath, Derivation>>,
    to_traverse: parking_lot::RwLock<HashSet<StorePath>>,

    notify_traverse: tokio::sync::Notify,
    traverse_done_notifier: Option<tokio::sync::mpsc::Sender<()>>,
}

async fn collect_ca_derivations(
    store: &LocalStore,
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

    let Some(parsed) = nix_utils::query_drv(store, drv).await.ok().flatten() else {
        return HashMap::new();
    };

    let is_ca = parsed.is_ca();
    let mut out = if parsed.input_drvs.is_empty() {
        HashMap::new()
    } else {
        futures::StreamExt::map(tokio_stream::iter(parsed.input_drvs.clone()), |i| {
            let processed = processed.clone();
            async move {
                let i = StorePath::new(&i);
                Box::pin(collect_ca_derivations(store, &i, processed)).await
            }
        })
        .buffered(10)
        .flat_map(futures::stream::iter)
        .collect::<HashMap<_, _>>()
        .await
    };
    if is_ca {
        out.insert(drv.clone(), parsed);
    }

    out
}

impl FodChecker {
    #[must_use]
    pub fn new(traverse_done_notifier: Option<tokio::sync::mpsc::Sender<()>>) -> Self {
        Self {
            ca_derivations: parking_lot::RwLock::new(HashMap::with_capacity(1000)),
            to_traverse: parking_lot::RwLock::new(HashSet::new()),

            notify_traverse: tokio::sync::Notify::new(),
            traverse_done_notifier,
        }
    }

    pub(super) fn add_ca_drv_parsed(&self, drv: &StorePath, parsed: &Derivation) {
        if parsed.is_ca() {
            let mut ca = self.ca_derivations.write();
            ca.insert(drv.clone(), parsed.clone());
        }
    }

    pub fn to_traverse(&self, drv: &StorePath) {
        let mut tt = self.to_traverse.write();
        tt.insert(drv.clone());
    }

    async fn traverse(&self, store: &LocalStore) {
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
            let store = LocalStore::init();
            self.traverse(&store).await;
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
    use nix_utils::BaseStore as _;

    #[ignore = "Requires a valid drv in the nix-store"]
    #[tokio::test]
    async fn test_traverse() {
        let store = nix_utils::LocalStore::init();
        let hello_drv =
            nix_utils::StorePath::new("rl5m4zxd24mkysmpbp4j9ak6q7ia6vj8-hello-2.12.2.drv");
        store.ensure_path(&hello_drv).await.unwrap();

        let fod = FodChecker::new(None);
        fod.to_traverse(&hello_drv);
        fod.traverse(&store).await;
        assert_eq!(fod.ca_derivations.read().len(), 59);
    }
}
