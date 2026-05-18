use std::sync::Arc;

use harmonia_store_derivation::derived_path::{DerivedPath, OutputSpec, SingleDerivedPath};
use harmonia_store_path::{StoreDir, StorePath};
use tokio::io::{AsyncBufReadExt as _, BufReader};
use tokio_stream::wrappers::LinesStream;

#[allow(clippy::type_complexity)]
#[tracing::instrument(skip(store_dir), fields(%drv), err)]
pub(crate) async fn realise_drv(
    store_dir: &StoreDir,
    drv: &StorePath,
    max_log_size: u64,
    max_silent_time: i32,
    build_timeout: i32,
) -> std::io::Result<(
    tokio::process::Child,
    LinesStream<BufReader<tokio::process::ChildStdout>>,
    LinesStream<BufReader<tokio::process::ChildStderr>>,
)> {
    let drv_installable = store_dir
        .display(&DerivedPath::Built {
            drv_path: Arc::new(SingleDerivedPath::Opaque(drv.clone())),
            outputs: OutputSpec::All,
        })
        .to_string();

    let mut child = tokio::process::Command::new("nix")
        .args([
            "--extra-experimental-features",
            "nix-command",
            "build",
            "--json",
            "--no-pretty",
            "--print-build-logs",
            "--log-format",
            "raw-with-logs",
            "--no-link",
            "--max-silent-time",
            &max_silent_time.to_string(),
            "--timeout",
            &build_timeout.to_string(),
            "--option",
            "max-build-log-size",
            &max_log_size.to_string(),
            "--option",
            "fallback",
            "true",
            "--option",
            "substitute",
            "false",
            "--option",
            "builders",
            "",
            &drv_installable,
        ])
        .kill_on_drop(true)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()?;

    let stdout = child.stdout.take().expect("stdout was piped");
    let stderr = child.stderr.take().expect("stderr was piped");

    let stdout = LinesStream::new(BufReader::new(stdout).lines());
    let stderr = LinesStream::new(BufReader::new(stderr).lines());

    Ok((child, stdout, stderr))
}
