#![forbid(unsafe_code)]
#![deny(
    clippy::all,
    future_incompatible,
    nonstandard_style,
    unused_qualifications
)]

//! Following Hydra build-step logs as the queue runner writes them:
//! where a step's log file is, how to tail it, and how to read the
//! notifications that announce steps. Shared by `hydra-ws` and
//! `hydra-ad-hoc`, so the two agree.

use std::path::{Path, PathBuf};

use harmonia_store_path::StorePath;

pub mod notify;
pub mod tailer;

/// The log file the queue runner writes for `drv`, under `log_prefix`
/// (normally `<hydraDataDir>/build-logs`).
pub fn log_path(log_prefix: &Path, drv: &StorePath) -> PathBuf {
    let base = drv.to_string();
    let (dir, file) = base.split_at(2);
    log_prefix.join(dir).join(file)
}
