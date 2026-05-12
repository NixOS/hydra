use std::path::PathBuf;

use dashmap::DashMap;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

use crate::messages::HydraWsResponse;

struct Subscriber {
    handle: JoinHandle<()>,
    tx: mpsc::Sender<HydraWsResponse>,
    path: PathBuf,
}

type SubMap = DashMap<(u64, Option<u64>), Vec<Subscriber>>;

pub struct Subscriptions {
    inner: SubMap,
}

impl Subscriptions {
    #[must_use]
    pub fn new() -> Self {
        Self {
            inner: DashMap::new(),
        }
    }

    pub fn register(
        &self,
        build_id: u64,
        step_id: Option<u64>,
        handle: JoinHandle<()>,
        tx: mpsc::Sender<HydraWsResponse>,
        path: PathBuf,
    ) {
        self.inner
            .entry((build_id, step_id))
            .or_default()
            .push(Subscriber { handle, tx, path });
    }

    #[must_use]
    pub fn has(
        &self,
        build_id: u64,
        step_id: Option<u64>,
        tx: &mpsc::Sender<HydraWsResponse>,
    ) -> bool {
        self.inner
            .get(&(build_id, step_id))
            .is_some_and(|entry| entry.iter().any(|s| s.tx.same_channel(tx)))
    }

    pub fn abort(
        &self,
        build_id: u64,
        step_id: Option<u64>,
        tx: &mpsc::Sender<HydraWsResponse>,
    ) -> bool {
        if let Some(mut entry) = self.inner.get_mut(&(build_id, step_id)) {
            let pos = entry.iter().position(|s| s.tx.same_channel(tx));
            if let Some(idx) = pos {
                let s = entry.remove(idx);
                s.handle.abort();
                return true;
            }
        }
        false
    }

    pub fn cleanup(&self, build_id: u64, step_id: Option<u64>, tx: &mpsc::Sender<HydraWsResponse>) {
        if let Some(mut entry) = self.inner.get_mut(&(build_id, step_id)) {
            entry.retain(|s| !s.tx.same_channel(tx));
        }
    }

    pub fn cleanup_connection(&self, tx: &mpsc::Sender<HydraWsResponse>) {
        let keys: Vec<(u64, Option<u64>)> = self.inner.iter().map(|e| *e.key()).collect();

        for key in keys {
            if let Some(mut entry) = self.inner.get_mut(&key) {
                entry.retain(|s| {
                    if s.tx.same_channel(tx) {
                        s.handle.abort();
                        false
                    } else {
                        true
                    }
                });
            }
        }
    }

    pub fn notify_step_finished(&self, build_id: u64, step_id: u64) -> Vec<PathBuf> {
        let msg = HydraWsResponse::StepFinished { build_id, step_id };
        let keys: Vec<(u64, Option<u64>)> = self
            .inner
            .iter()
            .filter(|e| e.key().0 == build_id && e.key().1.is_some_and(|sid| sid == step_id))
            .map(|e| *e.key())
            .collect();

        let mut paths = Vec::new();
        for key in keys {
            if let Some(entry) = self.inner.get_mut(&key) {
                if let Some(p) = entry.first().map(|s| s.path.clone()) {
                    paths.push(p);
                }
                for s in entry.iter() {
                    if s.tx.try_send(msg.clone()).is_err() {
                        tracing::warn!("Failed to send step_finished notification, channel full");
                    }
                    s.handle.abort();
                }
                drop(entry);
            }
        }
        paths
    }

    pub fn notify_build_finished(&self, build_id: u64) -> Vec<PathBuf> {
        let msg = HydraWsResponse::BuildFinished { build_id };
        let keys: Vec<(u64, Option<u64>)> = self
            .inner
            .iter()
            .filter(|e| e.key().0 == build_id)
            .map(|e| *e.key())
            .collect();

        let mut paths = Vec::new();
        for key in keys {
            if let Some(entry) = self.inner.get_mut(&key) {
                if let Some(p) = entry.first().map(|s| s.path.clone()) {
                    paths.push(p);
                }
                for s in entry.iter() {
                    if s.tx.try_send(msg.clone()).is_err() {
                        tracing::warn!("Failed to send build_finished notification, channel full");
                    }
                    s.handle.abort();
                }
                drop(entry);
                self.inner.remove(&key);
            }
        }
        paths
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use std::path::PathBuf;
    use tokio::sync::mpsc;

    use super::*;

    #[tokio::test]
    async fn register_and_has_subscription() {
        let subs = Subscriptions::new();
        let (tx, _rx) = mpsc::channel(16);

        subs.register(
            1,
            Some(2),
            tokio::spawn(std::future::pending::<()>()),
            tx.clone(),
            PathBuf::from("/tmp/test"),
        );
        assert!(subs.has(1, Some(2), &tx));
        assert!(!subs.has(1, None, &tx));
        assert!(!subs.has(1, Some(3), &tx));
        assert!(!subs.has(2, Some(2), &tx));
    }

    #[tokio::test]
    async fn register_multiple_subscribers_same_key() {
        let subs = Subscriptions::new();
        let (tx1, _rx1) = mpsc::channel(16);
        let (tx2, _rx2) = mpsc::channel(16);

        subs.register(
            1,
            None,
            tokio::spawn(std::future::pending::<()>()),
            tx1.clone(),
            PathBuf::from("/tmp/a"),
        );
        subs.register(
            1,
            None,
            tokio::spawn(std::future::pending::<()>()),
            tx2.clone(),
            PathBuf::from("/tmp/b"),
        );

        assert!(subs.has(1, None, &tx1));
        assert!(subs.has(1, None, &tx2));
    }

    #[tokio::test]
    async fn abort_removes_subscription_and_aborts_handle() {
        let subs = Subscriptions::new();
        let (tx, _rx) = mpsc::channel(16);
        let handle = tokio::spawn(std::future::pending::<()>());
        subs.register(1, None, handle, tx.clone(), PathBuf::from("/tmp/test"));

        assert!(subs.has(1, None, &tx));
        assert!(subs.abort(1, None, &tx));
        assert!(!subs.has(1, None, &tx));
    }

    #[tokio::test]
    async fn abort_returns_false_for_nonexistent() {
        let subs = Subscriptions::new();
        let (tx, _rx) = mpsc::channel(16);
        assert!(!subs.abort(1, None, &tx));
    }

    #[tokio::test]
    async fn abort_one_subscriber_keeps_others() {
        let subs = Subscriptions::new();
        let (tx1, _rx1) = mpsc::channel(16);
        let (tx2, _rx2) = mpsc::channel(16);

        subs.register(
            1,
            None,
            tokio::spawn(std::future::pending::<()>()),
            tx1.clone(),
            PathBuf::from("/tmp/a"),
        );
        subs.register(
            1,
            None,
            tokio::spawn(std::future::pending::<()>()),
            tx2.clone(),
            PathBuf::from("/tmp/b"),
        );

        assert!(subs.abort(1, None, &tx1));
        assert!(!subs.has(1, None, &tx1));
        assert!(subs.has(1, None, &tx2));
    }

    #[tokio::test]
    async fn cleanup_removes_subscription_without_abort() {
        let subs = Subscriptions::new();
        let (tx, _rx) = mpsc::channel(16);
        subs.register(
            1,
            None,
            tokio::spawn(std::future::pending::<()>()),
            tx.clone(),
            PathBuf::from("/tmp/test"),
        );

        assert!(subs.has(1, None, &tx));
        subs.cleanup(1, None, &tx);
        assert!(!subs.has(1, None, &tx));
    }

    #[tokio::test]
    async fn cleanup_connection_removes_all_for_tx() {
        let subs = Subscriptions::new();
        let (tx1, _rx1) = mpsc::channel(16);
        let (tx2, _rx2) = mpsc::channel(16);

        subs.register(
            1,
            None,
            tokio::spawn(std::future::pending::<()>()),
            tx1.clone(),
            PathBuf::from("/tmp/a"),
        );
        subs.register(
            2,
            Some(1),
            tokio::spawn(std::future::pending::<()>()),
            tx1.clone(),
            PathBuf::from("/tmp/b"),
        );
        subs.register(
            3,
            None,
            tokio::spawn(std::future::pending::<()>()),
            tx2.clone(),
            PathBuf::from("/tmp/c"),
        );

        subs.cleanup_connection(&tx1);

        assert!(!subs.has(1, None, &tx1));
        assert!(!subs.has(2, Some(1), &tx1));
        assert!(subs.has(3, None, &tx2));
    }

    #[tokio::test]
    async fn notify_step_finished_sends_message_and_returns_path() {
        let subs = Subscriptions::new();
        let (tx, mut rx) = mpsc::channel(16);
        subs.register(
            1,
            Some(5),
            tokio::spawn(std::future::pending::<()>()),
            tx.clone(),
            PathBuf::from("/tmp/test"),
        );

        let paths = subs.notify_step_finished(1, 5);

        assert_eq!(paths, vec![PathBuf::from("/tmp/test")]);
        let msg = rx.try_recv().unwrap();
        assert!(matches!(
            msg,
            HydraWsResponse::StepFinished {
                build_id: 1,
                step_id: 5
            }
        ));
        assert!(subs.has(1, Some(5), &tx));
    }

    #[tokio::test]
    async fn notify_step_finished_only_matches_exact_step() {
        let subs = Subscriptions::new();
        let (tx_step, mut rx_step) = mpsc::channel(16);
        let (tx_other, _rx_other) = mpsc::channel(16);

        subs.register(
            1,
            Some(5),
            tokio::spawn(std::future::pending::<()>()),
            tx_step.clone(),
            PathBuf::from("/tmp/step5"),
        );
        subs.register(
            1,
            Some(6),
            tokio::spawn(std::future::pending::<()>()),
            tx_other.clone(),
            PathBuf::from("/tmp/step6"),
        );

        let paths = subs.notify_step_finished(1, 5);

        assert_eq!(paths, vec![PathBuf::from("/tmp/step5")]);
        let msg = rx_step.try_recv().unwrap();
        assert!(matches!(
            msg,
            HydraWsResponse::StepFinished {
                build_id: 1,
                step_id: 5
            }
        ));
        assert!(subs.has(1, Some(5), &tx_step));
        assert!(subs.has(1, Some(6), &tx_other));
    }

    #[tokio::test]
    async fn notify_build_finished_sends_messages_and_returns_paths() {
        let subs = Subscriptions::new();
        let (tx1, _rx1) = mpsc::channel(16);
        let (tx2, _rx2) = mpsc::channel(16);

        subs.register(
            1,
            None,
            tokio::spawn(std::future::pending::<()>()),
            tx1.clone(),
            PathBuf::from("/tmp/a"),
        );
        subs.register(
            1,
            Some(2),
            tokio::spawn(std::future::pending::<()>()),
            tx2.clone(),
            PathBuf::from("/tmp/b"),
        );

        let paths = subs.notify_build_finished(1);

        assert_eq!(paths.len(), 2);
        assert!(paths.contains(&PathBuf::from("/tmp/a")));
        assert!(paths.contains(&PathBuf::from("/tmp/b")));
        assert!(!subs.has(1, None, &tx1));
        assert!(!subs.has(1, Some(2), &tx2));
    }

    #[tokio::test]
    async fn notify_build_finished_only_matches_build_id() {
        let subs = Subscriptions::new();
        let (tx1, _rx1) = mpsc::channel(16);
        let (tx2, _rx2) = mpsc::channel(16);

        subs.register(
            1,
            None,
            tokio::spawn(std::future::pending::<()>()),
            tx1.clone(),
            PathBuf::from("/tmp/1"),
        );
        subs.register(
            2,
            None,
            tokio::spawn(std::future::pending::<()>()),
            tx2.clone(),
            PathBuf::from("/tmp/2"),
        );

        let paths = subs.notify_build_finished(1);

        assert_eq!(paths, vec![PathBuf::from("/tmp/1")]);
        assert!(!subs.has(1, None, &tx1));
        assert!(subs.has(2, None, &tx2));
    }

    #[test]
    fn new_subscriptions_is_empty() {
        let subs = Subscriptions::new();
        let (tx, _rx) = mpsc::channel(16);
        assert!(!subs.has(1, None, &tx));
        assert!(!subs.abort(1, None, &tx));
    }
}
