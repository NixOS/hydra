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

    let db = db::Database::from_env(4)
        .await
        .wrap_err("failed to connect to database")?;

    if cli.unlock {
        queries::unlock_all_jobsets(&mut db.get().await?)
            .await
            .wrap_err("failed to unlock jobsets")?;
        tracing::info!("unlocked all jobsets");
        return Ok(());
    }

    let config = HydraConfig::load(&cli.config_path)?;

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
        remote.store_dir.clone(),
        config.eval_substituter().map(str::to_owned),
    );

    let evaluator = Evaluator::new(
        db,
        std::sync::Arc::new(config),
        std::sync::Arc::new(available),
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
