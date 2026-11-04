mod config;
mod declarative;
mod evaluate;
mod evaluator;
mod fetcher;
mod ingest;
mod inputs;
mod nix_eval_jobs;
mod queries;
mod store_paths;

use clap::Parser;
use color_eyre::eyre::{self, WrapErr as _};

use config::HydraConfig;
use evaluator::Evaluator;

#[derive(clap::Parser, Debug)]
#[command(name = "hydra-evaluator", about = "Hydra jobset evaluation scheduler")]
struct Cli {
    /// Path to the evaluator's configuration file
    #[arg(
        short,
        long,
        env = "HYDRA_EVALUATOR_CONFIG",
        default_value = "evaluator.toml"
    )]
    config_path: String,

    /// Clear startTime on all jobsets and exit
    #[arg(long)]
    unlock: bool,

    /// Project name (requires jobset)
    project: Option<String>,

    /// Jobset name (requires project)
    jobset: Option<String>,
}

#[tokio::main]
async fn main() -> color_eyre::Result<()> {
    let _tracing_guard = hydra_tracing::init()?;
    let cli = Cli::parse();

    if cli.unlock {
        let db = db::Database::from_env(1)
            .await
            .wrap_err("failed to connect to database")?;
        queries::unlock_all_jobsets(&mut db.get().await?)
            .await
            .wrap_err("failed to unlock jobsets")?;
        tracing::info!("unlocked all jobsets");
        return Ok(());
    }

    let config = HydraConfig::load(&cli.config_path)?;

    // One connection per running evaluation, and two for the scheduler.
    let connections = u32::try_from(config.max_concurrent_evals() + 2).unwrap_or(u32::MAX);
    let db = db::Database::from_env(connections)
        .await
        .wrap_err("failed to connect to database")?;

    let eval_one = match (cli.project, cli.jobset) {
        (Some(p), Some(j)) => Some((p, j)),
        (None, None) => None,
        _ => eyre::bail!("Syntax: hydra-evaluator [<project> <jobset>]"),
    };

    // The store is needed both to describe inputs to the expression and to
    // find out whether a build an input names is actually here.
    let remote = daemon_client_utils::parse_nix_remote()
        .map_err(|e| eyre::eyre!("could not work out which store to use: {e}"))?;
    let available = store_paths::Availability::new(
        daemon_client_utils::DaemonStoreReader::new(daemon_client_utils::DaemonConnector::new(
            remote.socket.clone(),
            remote.store_dir.clone(),
        )),
        config.eval_substituter().map(str::to_owned),
    );
    let roots_dir = match config.roots_dir() {
        Some(dir) => dir.to_owned(),
        None => remote.default_roots_dir(&std::env::var("LOGNAME").wrap_err("LOGNAME is not set")?),
    };
    fs_err::create_dir_all(&roots_dir)?;

    let evaluator = Evaluator::new(
        db,
        std::sync::Arc::new(config),
        std::sync::Arc::new(available),
        roots_dir.into(),
        eval_one,
    );
    evaluator.run().await
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
