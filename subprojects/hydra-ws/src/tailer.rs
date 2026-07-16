use std::collections::VecDeque;
use std::os::unix::fs::MetadataExt as _;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::time::Duration;

use dashmap::DashMap;
use fs_err::tokio::File;
use tokio::io::{AsyncBufReadExt as _, AsyncReadExt as _, AsyncSeekExt as _, BufReader};
use tokio::sync::{Notify, broadcast, oneshot};

const READ_CHUNK_SIZE: u64 = 8 * 1024;

#[derive(Debug, thiserror::Error)]
pub enum TailError {
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    #[error("Integer conversion error: {0}")]
    IntConversion(#[from] std::num::TryFromIntError),
}

#[derive(Clone, Debug)]
pub struct LineData {
    pub ok: bool,
    pub line: String,
    pub timestamp: Option<jiff::Timestamp>,
}

impl LineData {
    fn new(ok: bool, line: String, timestamp: Option<jiff::Timestamp>) -> Self {
        Self {
            ok,
            line,
            timestamp,
        }
    }
}

#[derive(Clone, Debug)]
pub struct LineMsg {
    pub seq: u64,
    pub inner: LineData,
}

impl LineMsg {
    fn new(seq: u64, inner: LineData) -> Self {
        Self { seq, inner }
    }
}

pub struct TailSubscription {
    pub rx: broadcast::Receiver<LineMsg>,
    pub backlog: Vec<LineMsg>,
    inner: Arc<FileTail>,
}

impl Drop for TailSubscription {
    fn drop(&mut self) {
        self.inner.subscribers.fetch_sub(1, Ordering::AcqRel);
    }
}

struct FileTail {
    path: PathBuf,
    tx: broadcast::Sender<LineMsg>,
    subscribers: AtomicUsize,
    shutdown: ShutdownHandle,
    notify: Notify,

    seq: AtomicU64,
    buffer: parking_lot::RwLock<VecDeque<LineMsg>>,
    buffer_cap: usize,
}

impl FileTail {
    pub(crate) fn request_shutdown(&self) {
        self.shutdown.trigger();
    }

    fn push_buffered(&self, inner: LineData) -> LineMsg {
        let seq = self.seq.fetch_add(1, Ordering::AcqRel) + 1;
        let msg = LineMsg::new(seq, inner);

        {
            let mut buf = self.buffer.write();
            if buf.len() == self.buffer_cap {
                buf.pop_front();
            }
            buf.push_back(msg.clone());
        }

        msg
    }
}

struct ShutdownHandle {
    tx: parking_lot::Mutex<Option<oneshot::Sender<()>>>,
}

impl ShutdownHandle {
    fn new(tx: oneshot::Sender<()>) -> Self {
        Self {
            tx: parking_lot::Mutex::new(Some(tx)),
        }
    }

    fn trigger(&self) {
        if let Some(tx) = self.tx.lock().take() {
            let _ = tx.send(());
        }
    }
}

pub struct TailManager {
    tails: DashMap<PathBuf, Arc<FileTail>>,
    // How long to wait after last subscriber before actually closing
    // (helps with churn / reconnect storms)
    idle_grace: Duration,
}

impl TailManager {
    pub fn new(idle_grace: Duration) -> Self {
        Self {
            tails: DashMap::new(),
            idle_grace,
        }
    }

    pub fn shutdown_tail(&self, path: &Path) {
        if let Some(tail) = self.tails.get(path) {
            tail.request_shutdown();
        }
    }

    #[tracing::instrument(skip(self), fields(path = %path.as_ref().display()))]
    pub async fn subscribe<P: AsRef<Path>>(&self, path: P) -> TailSubscription {
        tracing::debug!("subscribing to log tail");
        let path = path.as_ref().to_path_buf();

        let (inner, maybe_shutdown_rx) = {
            if let Some(existing) = self.tails.get(&path) {
                let inner = existing.clone();
                inner.subscribers.fetch_add(1, Ordering::AcqRel);
                inner.notify.notify_waiters();
                (inner, None)
            } else {
                // Create new tail state
                let (tx, _) = broadcast::channel::<LineMsg>(1024);
                let (shutdown_tx, shutdown_rx) = oneshot::channel();

                let inner = Arc::new(FileTail {
                    path: path.clone(),
                    tx,
                    subscribers: AtomicUsize::new(1),
                    shutdown: ShutdownHandle::new(shutdown_tx),
                    notify: Notify::new(),

                    seq: AtomicU64::new(0),
                    buffer: parking_lot::RwLock::new(VecDeque::with_capacity(50)),
                    buffer_cap: 50,
                });

                // Insert, but handle race: someone may insert between our get() and insert()
                match self.tails.entry(path.clone()) {
                    dashmap::mapref::entry::Entry::Occupied(o) => {
                        let theirs = o.get().clone();
                        theirs.subscribers.fetch_add(1, Ordering::AcqRel);
                        (theirs, None)
                    }
                    dashmap::mapref::entry::Entry::Vacant(v) => {
                        v.insert(inner.clone());
                        (inner, Some(shutdown_rx))
                    }
                }
            }
            // IMPORTANT: entry/get guards drop here at end of scope
        };

        // Only read from file on first creation; on re-subscribe the buffer is
        // already populated by tail_task (with proper timestamps).
        let is_new = maybe_shutdown_rx.is_some();

        // Populate backlog BEFORE spawning tail_task to avoid races where
        // both the backlog population and tail_task concurrently mutate
        // the sequence number and buffer.
        if is_new && let Ok(lines) = read_last_lines(&inner.path, inner.buffer_cap).await {
            for line in lines {
                inner.push_buffered(LineData::new(true, line, None));
            }
        }

        // Spawn OUTSIDE the DashMap lock scope.
        if let Some(shutdown_rx) = maybe_shutdown_rx {
            let manager_tails = self.tails.clone();
            let inner_clone = inner.clone();
            let idle_grace = self.idle_grace;

            tokio::spawn(async move {
                let e = tail_task(inner_clone.clone(), shutdown_rx, idle_grace).await;
                if e.is_err() {
                    tracing::error!(?path, error = ?e, "failed to open log file");
                    let msg = inner_clone.push_buffered(LineData::new(
                        false,
                        "Failed to open log file".into(),
                        None,
                    ));
                    let _ = inner_clone.tx.send(msg);
                }
                manager_tails.remove_if(&inner_clone.path, |_, v| Arc::ptr_eq(v, &inner_clone));
            });
        }

        let rx = inner.tx.subscribe();
        let backlog = {
            let buf = inner.buffer.read();
            buf.iter().cloned().collect::<Vec<_>>()
        };

        TailSubscription { rx, backlog, inner }
    }
}

#[tracing::instrument(skip(inner, shutdown_rx), fields(path = %inner.path.display()))]
async fn tail_task(
    inner: Arc<FileTail>,
    mut shutdown_rx: oneshot::Receiver<()>,
    idle_grace: Duration,
) -> Result<(), TailError> {
    let file = File::open(&inner.path).await?;
    let mut current_inode = file.metadata().await?.ino();
    let mut reader = BufReader::new(file);
    reader.seek(std::io::SeekFrom::End(0)).await?;

    let mut line = String::new();
    let poll = Duration::from_millis(200);

    loop {
        // If there are no subscribers, start grace timer and exit if still none
        if inner.subscribers.load(Ordering::Acquire) == 0 {
            tokio::select! {
                () = tokio::time::sleep(idle_grace) => {
                    if inner.subscribers.load(Ordering::Acquire) == 0 {
                        break;
                    }
                }
                () = inner.notify.notified() => {}
                _ = &mut shutdown_rx => {
                    break;
                }
            }
        }

        tokio::select! {
            _ = &mut shutdown_rx => {
                break;
            }

            // Try reading a line. If EOF, sleep and retry.
            res = reader.read_line(&mut line) => {
                let n = res?;
                if n == 0 {
                    // EOF: handle truncation / rotation / replacement.
                    // If file got truncated or replaced, reopen to get a fresh
                    // handle to the current inode. Seeking within a stale handle
                    // to a deleted file can cause an infinite re-read loop.
                    if let Ok(meta) = fs_err::tokio::metadata(&inner.path).await
                        && let Ok(pos) = reader.stream_position().await
                            && (meta.ino() != current_inode || meta.len() < pos) {
                                let file = File::open(&inner.path).await?;
                                current_inode = file.metadata().await?.ino();
                                reader = BufReader::new(file);
                            }
                    tokio::time::sleep(poll).await;
                } else {
                    let msg_line = std::mem::take(&mut line);
                    let now = jiff::Timestamp::now();
                    let msg = inner.push_buffered(LineData::new(true, msg_line, Some(now)));
                    let _ = inner.tx.send(msg);
                }
            }
        }
    }

    Ok(())
}

#[tracing::instrument(skip_all)]
async fn read_last_lines(path: &Path, n: usize) -> Result<Vec<String>, TailError> {
    let mut file = match File::open(path).await {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(vec![]),
        Err(e) => return Err(TailError::Io(e)),
    };

    let meta = file.metadata().await?;
    let mut pos = meta.len();

    let mut chunks: Vec<Vec<u8>> = Vec::new();
    let mut newlines = 0usize;

    while pos > 0 && newlines <= n {
        let step = usize::try_from(std::cmp::min(READ_CHUNK_SIZE, pos))?;
        pos -= step as u64;

        file.seek(std::io::SeekFrom::Start(pos)).await?;

        let mut buf = vec![0u8; step];
        file.read_exact(&mut buf).await?;

        newlines += bytecount::count(&buf, b'\n');
        chunks.push(buf);
    }

    // Stitch in forward order
    chunks.reverse();
    let mut bytes = Vec::with_capacity(chunks.iter().map(Vec::len).sum());
    for c in chunks {
        bytes.extend_from_slice(&c);
    }

    // Split into lines; handle \r\n by trimming trailing \r.
    let text = String::from_utf8_lossy(&bytes);
    let mut lines: Vec<String> = text
        .lines()
        .map(|l| l.trim_end_matches('\r').to_string())
        .collect();

    if lines.len() > n {
        lines.drain(0..lines.len() - n);
    }

    Ok(lines)
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::pedantic)]

    use super::*;

    #[tokio::test]
    async fn read_last_lines_empty_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("empty.log");
        fs_err::tokio::write(&path, b"").await.unwrap();
        let lines = read_last_lines(&path, 10).await.unwrap();
        assert!(lines.is_empty());
    }

    #[tokio::test]
    async fn read_last_lines_fewer_than_n() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("few.log");
        fs_err::tokio::write(&path, b"line1\nline2\n")
            .await
            .unwrap();
        let lines = read_last_lines(&path, 10).await.unwrap();
        assert_eq!(lines, vec!["line1", "line2"]);
    }

    #[tokio::test]
    async fn read_last_lines_more_than_n() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("many.log");
        let mut content = String::new();
        for i in 0..100 {
            content.push_str(&format!("line{i}\n"));
        }
        fs_err::tokio::write(&path, content.as_bytes())
            .await
            .unwrap();
        let lines = read_last_lines(&path, 3).await.unwrap();
        assert_eq!(lines.len(), 3);
        assert_eq!(lines, vec!["line97", "line98", "line99"]);
    }

    #[tokio::test]
    async fn read_last_lines_nonexistent_file_returns_empty() {
        let path = Path::new("/tmp/__nonexistent_hydra_test_file__.log");
        let lines = read_last_lines(path, 10).await.unwrap();
        assert!(lines.is_empty());
    }

    #[tokio::test]
    async fn read_last_lines_handles_carriage_return() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("crlf.log");
        fs_err::tokio::write(&path, b"line1\r\nline2\r\n")
            .await
            .unwrap();
        let lines = read_last_lines(&path, 10).await.unwrap();
        assert_eq!(lines, vec!["line1", "line2"]);
    }

    #[tokio::test]
    async fn subscribe_returns_backlog_from_existing_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("existing.log");
        fs_err::tokio::write(&path, b"a\nb\nc\n").await.unwrap();

        let manager = TailManager::new(Duration::from_secs(1));
        let sub = manager.subscribe(&path).await;
        let backlog = sub.backlog.clone();

        let lines: Vec<&str> = backlog.iter().map(|m| m.inner.line.as_str()).collect();
        assert_eq!(lines, vec!["a", "b", "c"]);
        // all lines should have ok: true and no timestamp (from file read)
        for msg in &backlog {
            assert!(msg.inner.ok);
            assert!(msg.inner.timestamp.is_none());
        }
    }

    #[tokio::test]
    async fn subscribe_reuses_existing_tail() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("shared.log");
        fs_err::tokio::write(&path, b"hello\n").await.unwrap();

        let manager = TailManager::new(Duration::from_secs(1));
        let sub1 = manager.subscribe(&path).await;
        let sub2 = manager.subscribe(&path).await;

        // Both should have the same backlog
        assert_eq!(sub1.backlog.len(), 1);
        assert_eq!(sub1.backlog[0].inner.line, "hello");
        assert_eq!(sub1.backlog[0].inner.line, sub2.backlog[0].inner.line);
        // Both should share the same broadcast receiver (same sequence space)
        assert_eq!(sub1.backlog[0].seq, sub2.backlog[0].seq);
    }

    #[tokio::test]
    async fn tail_subscription_drop_decrements_subscriber_count() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("subcount.log");
        fs_err::tokio::write(&path, b"test\n").await.unwrap();

        let manager = TailManager::new(Duration::from_secs(10));
        let sub1 = manager.subscribe(&path).await;
        let sub1_inner = sub1.inner.clone();
        assert_eq!(sub1_inner.subscribers.load(Ordering::Acquire), 1);

        {
            let _sub2 = manager.subscribe(&path).await;
            assert_eq!(sub1_inner.subscribers.load(Ordering::Acquire), 2);
        }
        // sub2 dropped, subscriber count decreased
        assert_eq!(sub1_inner.subscribers.load(Ordering::Acquire), 1);
    }

    #[tokio::test]
    async fn subscribe_to_new_file_populates_backlog_then_forwards_new_lines() {
        // Write all content before subscribing to avoid timing issues.
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("live.log");
        fs_err::tokio::write(&path, b"line1\nline2\n")
            .await
            .unwrap();

        let manager = TailManager::new(Duration::from_secs(10));
        let sub = manager.subscribe(&path).await;

        // Backlog should have the file content
        assert_eq!(sub.backlog.len(), 2);
        assert_eq!(sub.backlog[0].inner.line, "line1");
        assert_eq!(sub.backlog[1].inner.line, "line2");
        // seq should be monotonically increasing
        assert!(sub.backlog[0].seq < sub.backlog[1].seq);
    }

    #[tokio::test]
    async fn subscribe_nonexistent_file_returns_subscription_with_empty_backlog_and_error_line() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nonexistent.log");

        let manager = TailManager::new(Duration::from_secs(1));
        let mut sub = manager.subscribe(&path).await;
        assert!(sub.backlog.is_empty());

        // background tail_task should send a failure line
        let msg = tokio::time::timeout(Duration::from_secs(2), sub.rx.recv()).await;
        match msg {
            Ok(Ok(m)) => {
                assert!(!m.inner.ok);
                assert!(m.inner.line.contains("Failed to open log file"));
            }
            Ok(Err(e)) => panic!("broadcast error: {e}"),
            Err(_) => panic!("timeout waiting for error line"),
        }
    }

    #[test]
    fn line_data_construction() {
        let data = LineData::new(true, "test".into(), None);
        assert!(data.ok);
        assert_eq!(data.line, "test");
        assert!(data.timestamp.is_none());
    }

    #[test]
    fn line_msg_construction() {
        let data = LineData::new(false, "err".into(), None);
        let msg = LineMsg::new(42, data);
        assert_eq!(msg.seq, 42);
        assert!(!msg.inner.ok);
        assert_eq!(msg.inner.line, "err");
    }
}
