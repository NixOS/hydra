//! Decides when jobsets are due, and queues a build to evaluate each.

mod config;
mod declarative;
mod eval_build;
mod fetcher;
mod inputs;
mod nix_eval_jobs;
mod programs;
mod queries;
mod scheduler;
mod store_paths;
mod submit;

use std::sync::Arc;

use clap::Parser;
use color_eyre::eyre::{self, WrapErr as _};

#[derive(clap::Parser, Debug)]
#[command(name = "hydra-submit-evaluation")]
struct Cli {
    /// Path to the configuration file
    #[arg(
        short,
        long,
        env = "HYDRA_EVALUATOR_CONFIG",
        default_value = "evaluator.toml"
    )]
    config_path: String,

    /// Submit one evaluation of this project's jobset and exit, rather than
    /// running as the daemon
    project: Option<String>,

    /// Jobset name (requires project)
    jobset: Option<String>,
}

#[tokio::main]
async fn main() -> color_eyre::Result<()> {
    let _tracing_guard = hydra_tracing::init()?;
    let cli = Cli::parse();

    let db = db::Database::from_env(4)
        .await
        .wrap_err("failed to connect to database")?;
    let config = config::HydraConfig::load(&cli.config_path)?;
    let programs = Arc::new(programs::Programs::locate()?);

    // The store directory is needed to describe inputs to the expression.
    let remote = daemon_client_utils::parse_nix_remote()
        .map_err(|e| eyre::eyre!("could not work out which store to use: {e}"))?;
    let available = store_paths::Availability::new(
        remote.store_dir.clone(),
        config.eval_substituter().map(str::to_owned),
        programs,
    );

    match (cli.project, cli.jobset) {
        (Some(project), Some(jobset)) => {
            let trace = format!("{}.once", scheduler::now());
            match submit::submit(&db, &config, &available, &project, &jobset, &trace).await {
                Ok(outcome) => {
                    tracing::info!("evaluation {outcome}");
                    if !outcome.succeeded() {
                        std::process::exit(1);
                    }
                }
                Err(e) => {
                    tracing::error!("{e:#}");
                    std::process::exit(1);
                }
            }
            Ok(())
        }
        (None, None) => scheduler::run(db, Arc::new(config), Arc::new(available)).await,
        _ => eyre::bail!("Syntax: hydra-submit-evaluation [<project> <jobset>]"),
    }
}

/// How long a helper process may run before we kill it. The Perl used the
/// same limit.
const HELPER_TIMEOUT: std::time::Duration = std::time::Duration::from_mins(10);

/// Run a helper to completion, killing it if it outlasts [`HELPER_TIMEOUT`].
async fn run_with_timeout(cmd: &mut tokio::process::Command) -> eyre::Result<std::process::Output> {
    tokio::time::timeout(HELPER_TIMEOUT, cmd.kill_on_drop(true).output())
        .await
        .map_err(|_| eyre::eyre!("timed out after {}s", HELPER_TIMEOUT.as_secs()))?
        .map_err(Into::into)
}

/// How many lines of a helper's stderr [`forward_stderr`] keeps.
const STDERR_TAIL_LINES: usize = 50;

/// Log the piped stderr of `child` at debug, in the current span, as it
/// arrives. The task yields the last [`STDERR_TAIL_LINES`] lines once stderr
/// closes.
fn forward_stderr(
    name: &'static str,
    child: &mut tokio::process::Child,
) -> eyre::Result<tokio::task::JoinHandle<String>> {
    use tokio::io::AsyncBufReadExt as _;
    use tracing::Instrument as _;

    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| eyre::eyre!("{name} has no stderr"))?;
    let task = async move {
        let mut reader = tokio::io::BufReader::new(stderr);
        let mut tail = std::collections::VecDeque::with_capacity(STDERR_TAIL_LINES);
        let mut buf = Vec::new();
        // Raw bytes rather than `lines()`: a non-UTF-8 line must not stop us
        // draining the pipe, or the helper blocks once it fills.
        while reader
            .read_until(b'\n', &mut buf)
            .await
            .is_ok_and(|n| n > 0)
        {
            let line = String::from_utf8(std::mem::take(&mut buf)).map_or_else(
                |_| "<non-UTF-8 line>".to_owned(),
                |l| l.trim_end().to_owned(),
            );
            tracing::debug!("{name}: {line}");
            if tail.len() == STDERR_TAIL_LINES {
                tail.pop_front();
            }
            tail.push_back(line);
        }
        Vec::from(tail).join("\n")
    };
    Ok(tokio::spawn(task.in_current_span()))
}

#[cfg(test)]
mod tests {
    #[tokio::test]
    async fn forward_stderr_keeps_the_tail() {
        let mut child = tokio::process::Command::new("sh")
            .args(["-c", "for i in $(seq 100); do echo $i >&2; done"])
            .stderr(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        let tail = super::forward_stderr("sh", &mut child).unwrap();
        child.wait().await.unwrap();
        let expected: Vec<String> = (51..=100).map(|i| i.to_string()).collect();
        assert_eq!(tail.await.unwrap(), expected.join("\n"));
    }
}
