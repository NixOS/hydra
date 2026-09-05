use std::collections::VecDeque;
use std::os::unix::fs::MetadataExt as _;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::time::Duration;

use dashmap::DashMap;
use fs_err::tokio::File;
use tokio::io::{AsyncBufReadExt as _, AsyncReadExt as _, AsyncSeekExt as _, BufReader};
use tokio::sync::{Notify, broadcast};

const READ_CHUNK_SIZE: u64 = 8 * 1024;

const MAX_BACKLOG_SCAN_BYTES: u64 = 4 * 1024 * 1024;

const POLL_INTERVAL: Duration = Duration::from_millis(200);

type TailMap = DashMap<PathBuf, Arc<FileTail>>;

#[allow(clippy::disallowed_methods)]
fn log_bytes_to_text(bytes: &[u8]) -> std::borrow::Cow<'_, str> {
    String::from_utf8_lossy(bytes)
}

#[derive(Debug, thiserror::Error)]
pub enum TailError {
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    #[error("Integer conversion error: {0}")]
    IntConversion(#[from] std::num::TryFromIntError),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LineKind {
    Line,
    Error,
    Eof,
}

#[derive(Clone, Debug)]
pub struct LineData {
    pub kind: LineKind,
    pub line: String,
    pub timestamp: Option<jiff::Timestamp>,
}

impl LineData {
    fn new(kind: LineKind, line: String, timestamp: Option<jiff::Timestamp>) -> Self {
        Self {
            kind,
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
    finished: AtomicBool,
    notify: Notify,

    seq: AtomicU64,
    buffer: parking_lot::RwLock<VecDeque<LineMsg>>,
    buffer_cap: usize,
}

impl FileTail {
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

    fn emit_line(&self, pending: &mut Vec<u8>) {
        if pending.is_empty() {
            return;
        }
        let line = log_bytes_to_text(pending)
            .trim_end_matches(['\n', '\r'])
            .to_owned();
        pending.clear();

        let msg = self.push_buffered(LineData::new(
            LineKind::Line,
            line,
            Some(jiff::Timestamp::now()),
        ));
        let _ = self.tx.send(msg);
    }

    fn emit_control(&self, kind: LineKind, line: String) {
        let msg = self.push_buffered(LineData::new(kind, line, None));
        let _ = self.tx.send(msg);
    }
}

pub struct TailManager {
    tails: Arc<TailMap>,
    // How long to wait after last subscriber before actually closing
    // (helps with churn / reconnect storms)
    idle_grace: Duration,
}

impl TailManager {
    pub fn new(idle_grace: Duration) -> Self {
        Self {
            tails: Arc::new(DashMap::new()),
            idle_grace,
        }
    }

    pub fn finish_tail(&self, path: &Path) {
        if let Some(tail) = self.tails.get(path) {
            tail.finished.store(true, Ordering::Release);
            tail.notify.notify_one();
        }
    }

    #[tracing::instrument(skip(self), fields(path = %path.as_ref().display()))]
    pub async fn subscribe<P: AsRef<Path>>(&self, path: P) -> TailSubscription {
        tracing::debug!("subscribing to log tail");
        let path = path.as_ref().to_path_buf();

        let (inner, is_new) = {
            if let Some(existing) = self.tails.get(&path) {
                let inner = existing.clone();
                inner.subscribers.fetch_add(1, Ordering::AcqRel);
                inner.notify.notify_one();
                (inner, false)
            } else {
                // Create new tail state
                let (tx, _) = broadcast::channel::<LineMsg>(1024);

                let inner = Arc::new(FileTail {
                    path: path.clone(),
                    tx,
                    subscribers: AtomicUsize::new(1),
                    finished: AtomicBool::new(false),
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
                        (theirs, false)
                    }
                    dashmap::mapref::entry::Entry::Vacant(v) => {
                        v.insert(inner.clone());
                        (inner, true)
                    }
                }
            }
        };

        // Only read from file on first creation; on re-subscribe the buffer is
        // already populated by tail_task (with proper timestamps).
        //
        // Populate backlog BEFORE spawning tail_task to avoid races where
        // both the backlog population and tail_task concurrently mutate
        // the sequence number and buffer.
        //
        // This also fixes the resume offset while still inside subscribe(): the
        // tail task only opens the file later, and anything appended in between
        // would otherwise fall into neither the backlog nor the stream.
        if is_new {
            let mut resume_at: Option<u64> = None;
            match read_last_lines(&inner.path, inner.buffer_cap).await {
                Ok((lines, offset)) => {
                    for line in lines {
                        inner.push_buffered(LineData::new(LineKind::Line, line, None));
                    }
                    resume_at = Some(offset);
                }
                Err(e) => {
                    tracing::warn!(path = ?inner.path, error = ?e, "failed to read log backlog");
                }
            }

            // Spawn OUTSIDE the DashMap lock scope.
            let tails = self.tails.clone();
            let inner_clone = inner.clone();
            let idle_grace = self.idle_grace;

            tokio::spawn(async move {
                let res =
                    tail_task(inner_clone.clone(), tails.clone(), idle_grace, resume_at).await;
                if res.is_err() {
                    tracing::error!(path = ?inner_clone.path, error = ?res, "failed to open log file");
                    inner_clone.emit_control(LineKind::Error, "Failed to open log file".into());
                }
                tails.remove_if(&inner_clone.path, |_, v| Arc::ptr_eq(v, &inner_clone));
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

#[tracing::instrument(skip(inner, tails), fields(path = %inner.path.display()))]
async fn tail_task(
    inner: Arc<FileTail>,
    tails: Arc<TailMap>,
    idle_grace: Duration,
    resume_at: Option<u64>,
) -> Result<(), TailError> {
    let file = File::open(&inner.path).await?;
    let mut current_inode = file.metadata().await?.ino();
    let mut reader = BufReader::new(file);
    match resume_at {
        Some(offset) => reader.seek(std::io::SeekFrom::Start(offset)).await?,
        None => reader.seek(std::io::SeekFrom::End(0)).await?,
    };

    let mut pending: Vec<u8> = Vec::new();

    loop {
        if !inner.finished.load(Ordering::Acquire) && inner.subscribers.load(Ordering::Acquire) == 0
        {
            tokio::select! {
                () = tokio::time::sleep(idle_grace) => {
                    let removed = tails.remove_if(&inner.path, |_, v| {
                        Arc::ptr_eq(v, &inner) && v.subscribers.load(Ordering::Acquire) == 0
                    });
                    if removed.is_some() {
                        break;
                    }
                }
                () = inner.notify.notified() => {}
            }
        }

        let n = reader.read_until(b'\n', &mut pending).await?;
        if n == 0 {
            if inner.finished.load(Ordering::Acquire) {
                tails.remove_if(&inner.path, |_, v| Arc::ptr_eq(v, &inner));
                inner.emit_line(&mut pending);
                inner.emit_control(LineKind::Eof, String::new());
                break;
            }

            if let Ok(meta) = fs_err::tokio::metadata(&inner.path).await
                && let Ok(pos) = reader.stream_position().await
                && (meta.ino() != current_inode || meta.len() < pos)
            {
                let file = File::open(&inner.path).await?;
                current_inode = file.metadata().await?.ino();
                reader = BufReader::new(file);
                pending.clear();
            }
            tokio::time::sleep(POLL_INTERVAL).await;
        } else if pending.ends_with(b"\n") {
            inner.emit_line(&mut pending);
        }
    }

    Ok(())
}

#[tracing::instrument(skip_all)]
async fn read_last_lines(path: &Path, n: usize) -> Result<(Vec<String>, u64), TailError> {
    let mut file = match File::open(path).await {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok((vec![], 0)),
        Err(e) => return Err(TailError::Io(e)),
    };

    let meta = file.metadata().await?;
    let mut pos = meta.len();

    let mut chunks: Vec<Vec<u8>> = Vec::new();
    let mut newlines = 0usize;
    let mut scanned = 0u64;

    while pos > 0 && newlines <= n && scanned < MAX_BACKLOG_SCAN_BYTES {
        let step = usize::try_from(std::cmp::min(READ_CHUNK_SIZE, pos))?;
        pos -= step as u64;
        scanned += step as u64;

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

    let trailing = match bytes.iter().rposition(|&b| b == b'\n') {
        Some(i) => bytes.len() - 1 - i,
        None => 0,
    };
    let resume = meta.len() - trailing as u64;

    // Split into lines; handle \r\n by trimming trailing \r.
    let text = log_bytes_to_text(&bytes);
    let mut lines: Vec<String> = text
        .lines()
        .map(|l| l.trim_end_matches('\r').to_string())
        .collect();

    if trailing > 0 {
        lines.pop();
    }

    if lines.len() > n {
        lines.drain(0..lines.len() - n);
    }

    Ok((lines, resume))
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::pedantic)]

    use super::*;
    use tokio::io::AsyncWriteExt as _;

    async fn append(path: &Path, bytes: &[u8]) {
        let mut f = fs_err::tokio::OpenOptions::new()
            .append(true)
            .open(path)
            .await
            .unwrap();
        f.write_all(bytes).await.unwrap();
        f.flush().await.unwrap();
    }

    async fn next_msg(sub: &mut TailSubscription) -> LineMsg {
        tokio::time::timeout(Duration::from_secs(5), sub.rx.recv())
            .await
            .expect("timed out waiting for a tail message")
            .expect("broadcast channel closed")
    }

    #[tokio::test]
    async fn read_last_lines_empty_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("empty.log");
        fs_err::tokio::write(&path, b"").await.unwrap();
        let (lines, resume) = read_last_lines(&path, 10).await.unwrap();
        assert!(lines.is_empty());
        assert_eq!(resume, 0);
    }

    #[tokio::test]
    async fn read_last_lines_fewer_than_n() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("few.log");
        fs_err::tokio::write(&path, b"line1\nline2\n")
            .await
            .unwrap();
        let (lines, resume) = read_last_lines(&path, 10).await.unwrap();
        assert_eq!(lines, vec!["line1", "line2"]);
        assert_eq!(resume, 12);
    }

    #[tokio::test]
    async fn read_last_lines_leaves_trailing_partial_line_to_the_tail() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("partial.log");
        fs_err::tokio::write(&path, b"a\nb\nc").await.unwrap();
        let (lines, resume) = read_last_lines(&path, 10).await.unwrap();
        assert_eq!(lines, vec!["a", "b"]);
        assert_eq!(resume, 4);
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
        let (lines, _) = read_last_lines(&path, 3).await.unwrap();
        assert_eq!(lines.len(), 3);
        assert_eq!(lines, vec!["line97", "line98", "line99"]);
    }

    #[tokio::test]
    async fn read_last_lines_nonexistent_file_returns_empty() {
        let path = Path::new("/tmp/__nonexistent_hydra_test_file__.log");
        let (lines, resume) = read_last_lines(path, 10).await.unwrap();
        assert!(lines.is_empty());
        assert_eq!(resume, 0);
    }

    #[tokio::test]
    async fn read_last_lines_handles_carriage_return() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("crlf.log");
        fs_err::tokio::write(&path, b"line1\r\nline2\r\n")
            .await
            .unwrap();
        let (lines, resume) = read_last_lines(&path, 10).await.unwrap();
        assert_eq!(lines, vec!["line1", "line2"]);
        assert_eq!(resume, 14);
    }

    #[tokio::test]
    async fn read_last_lines_caps_scan_on_newline_free_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("noeol.log");

        let big = vec![b'x'; usize::try_from(MAX_BACKLOG_SCAN_BYTES).unwrap() + 64 * 1024];
        fs_err::tokio::write(&path, &big).await.unwrap();

        let (lines, resume) = read_last_lines(&path, 50).await.unwrap();
        assert_eq!(lines.len(), 1);
        assert!(lines[0].len() <= usize::try_from(MAX_BACKLOG_SCAN_BYTES).unwrap());
        assert_eq!(resume, big.len() as u64);
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
        for msg in &backlog {
            assert_eq!(msg.inner.kind, LineKind::Line);
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

        assert_eq!(sub1.backlog.len(), 1);
        assert_eq!(sub1.backlog[0].inner.line, "hello");
        assert_eq!(sub1.backlog[0].inner.line, sub2.backlog[0].inner.line);
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
        assert_eq!(sub1_inner.subscribers.load(Ordering::Acquire), 1);
    }

    #[tokio::test]
    async fn subscribe_to_new_file_populates_backlog_then_forwards_new_lines() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("live.log");
        fs_err::tokio::write(&path, b"line1\nline2\n")
            .await
            .unwrap();

        let manager = TailManager::new(Duration::from_secs(10));
        let sub = manager.subscribe(&path).await;

        assert_eq!(sub.backlog.len(), 2);
        assert_eq!(sub.backlog[0].inner.line, "line1");
        assert_eq!(sub.backlog[1].inner.line, "line2");
        assert!(sub.backlog[0].seq < sub.backlog[1].seq);
    }

    #[tokio::test]
    async fn subscribe_nonexistent_file_returns_subscription_with_empty_backlog_and_error_line() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nonexistent.log");

        let manager = TailManager::new(Duration::from_secs(1));
        let mut sub = manager.subscribe(&path).await;
        assert!(sub.backlog.is_empty());

        let msg = tokio::time::timeout(Duration::from_secs(2), sub.rx.recv()).await;
        match msg {
            Ok(Ok(m)) => {
                assert_eq!(m.inner.kind, LineKind::Error);
                assert!(m.inner.line.contains("Failed to open log file"));
            }
            Ok(Err(e)) => panic!("broadcast error: {e}"),
            Err(_) => panic!("timeout waiting for error line"),
        }
    }

    #[tokio::test]
    async fn tail_survives_invalid_utf8() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("binary.log");
        fs_err::tokio::write(&path, b"").await.unwrap();

        let manager = TailManager::new(Duration::from_secs(10));
        let mut sub = manager.subscribe(&path).await;

        append(&path, b"bad \xff\xfe bytes\n").await;
        let msg = next_msg(&mut sub).await;
        assert_eq!(msg.inner.kind, LineKind::Line);
        assert_eq!(msg.inner.line, "bad \u{fffd}\u{fffd} bytes");

        append(&path, b"still here\n").await;
        let msg = next_msg(&mut sub).await;
        assert_eq!(msg.inner.kind, LineKind::Line);
        assert_eq!(msg.inner.line, "still here");
    }

    #[tokio::test]
    async fn tail_joins_partial_writes_into_one_line() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("partial.log");
        fs_err::tokio::write(&path, b"").await.unwrap();

        let manager = TailManager::new(Duration::from_secs(10));
        let mut sub = manager.subscribe(&path).await;

        append(&path, b"first ha").await;
        tokio::time::sleep(POLL_INTERVAL * 3).await;
        append(&path, b"lf second half\nnext\n").await;

        let msg = next_msg(&mut sub).await;
        assert_eq!(msg.inner.line, "first half second half");
        let msg = next_msg(&mut sub).await;
        assert_eq!(msg.inner.line, "next");
    }

    #[tokio::test]
    async fn finish_tail_flushes_trailing_partial_line_then_eof() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("finish.log");
        fs_err::tokio::write(&path, b"").await.unwrap();

        let manager = TailManager::new(Duration::from_secs(60));
        let mut sub = manager.subscribe(&path).await;

        append(&path, b"complete\ntrailing without newline").await;

        let msg = next_msg(&mut sub).await;
        assert_eq!(msg.inner.line, "complete");

        tokio::time::sleep(POLL_INTERVAL * 3).await;
        manager.finish_tail(&path);

        let msg = next_msg(&mut sub).await;
        assert_eq!(msg.inner.kind, LineKind::Line);
        assert_eq!(msg.inner.line, "trailing without newline");

        let msg = next_msg(&mut sub).await;
        assert_eq!(msg.inner.kind, LineKind::Eof);

        assert!(!manager.tails.contains_key(path.as_path()));
    }

    #[tokio::test]
    async fn exited_tail_is_unregistered_and_resubscribe_is_live() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("idle.log");
        fs_err::tokio::write(&path, b"seed\n").await.unwrap();

        let manager = TailManager::new(Duration::from_millis(50));
        drop(manager.subscribe(&path).await);

        tokio::time::timeout(Duration::from_secs(5), async {
            while manager.tails.contains_key(path.as_path()) {
                tokio::time::sleep(Duration::from_millis(25)).await;
            }
        })
        .await
        .expect("tail was never unregistered after going idle");

        let mut sub = manager.subscribe(&path).await;
        append(&path, b"after restart\n").await;

        let msg = next_msg(&mut sub).await;
        assert_eq!(msg.inner.kind, LineKind::Line);
        assert_eq!(msg.inner.line, "after restart");
    }

    #[test]
    fn line_data_construction() {
        let data = LineData::new(LineKind::Line, "test".into(), None);
        assert_eq!(data.kind, LineKind::Line);
        assert_eq!(data.line, "test");
        assert!(data.timestamp.is_none());
    }

    #[test]
    fn line_msg_construction() {
        let data = LineData::new(LineKind::Error, "err".into(), None);
        let msg = LineMsg::new(42, data);
        assert_eq!(msg.seq, 42);
        assert_eq!(msg.inner.kind, LineKind::Error);
        assert_eq!(msg.inner.line, "err");
    }
}
