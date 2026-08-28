//! Extra output streams for a build.
//!
//! A build can be given named streams beyond its log. For each one, a FIFO is
//! created here and bound into the sandbox via `extra-sandbox-paths`; whatever
//! the build writes to it is relayed back to the queue runner verbatim.
//!
//! Nothing here interprets the bytes. The builder is transport: it does not
//! know, and must not learn, what any stream carries. That is why a FIFO works
//! -- Linux exempts FIFOs from the read-only-mount check in `may_open`, so a
//! build can open one for writing even though the mount is read-only.

use std::path::{Path, PathBuf};

use color_eyre::eyre::{self, WrapErr as _};
use hydra_proto::NamedStream;
use tokio::io::AsyncReadExt as _;

/// A FIFO bound into a build's sandbox, and the task relaying it.
#[derive(Debug)]
pub struct BoundStream {
    /// Name the chunks are tagged with.
    pub name: String,
    /// Where the build sees it.
    pub sandbox_path: String,
    /// Where it lives on this machine.
    host_path: PathBuf,
}

impl BoundStream {
    /// Create the FIFO. It is created rather than opened: opening the read end
    /// blocks until a writer appears, which for a build that never writes would
    /// be never.
    pub fn create(dir: &Path, stream: &NamedStream) -> eyre::Result<Self> {
        let host_path = dir.join(&stream.name);
        nix::unistd::mkfifo(&host_path, nix::sys::stat::Mode::from_bits_truncate(0o666))
            .wrap_err_with(|| format!("creating the fifo for stream {}", stream.name))?;
        Ok(Self {
            name: stream.name.clone(),
            sandbox_path: stream.sandbox_path.clone(),
            host_path,
        })
    }

    /// `dst=src` as `extra-sandbox-paths` wants it.
    #[must_use]
    pub fn sandbox_mapping(&self) -> String {
        format!("{}={}", self.sandbox_path, self.host_path.display())
    }

    /// Read the FIFO to end of file, handing each chunk to `sink`.
    ///
    /// Opening blocks until the build opens its end, so this is meant to be
    /// spawned alongside the build rather than awaited before it.
    pub async fn relay<F>(self, mut sink: F) -> eyre::Result<()>
    where
        F: FnMut(String, Vec<u8>),
    {
        let mut fifo = tokio::fs::File::open(&self.host_path)
            .await
            .wrap_err_with(|| format!("opening the fifo for stream {}", self.name))?;

        let mut buf = vec![0u8; 64 * 1024];
        loop {
            let n = fifo
                .read(&mut buf)
                .await
                .wrap_err_with(|| format!("reading stream {}", self.name))?;
            if n == 0 {
                // The build closed its end; for a FIFO that is the end of the
                // stream, not merely a pause.
                return Ok(());
            }
            sink(self.name.clone(), buf[..n].to_vec());
        }
    }
}

/// The `extra-sandbox-paths` value binding every stream into the sandbox.
#[must_use]
pub fn sandbox_paths_option(streams: &[BoundStream]) -> String {
    streams
        .iter()
        .map(BoundStream::sandbox_mapping)
        .collect::<Vec<_>>()
        .join(" ")
}
