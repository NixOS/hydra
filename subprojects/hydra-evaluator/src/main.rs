#![forbid(unsafe_code)]
#![deny(
    clippy::all,
    clippy::pedantic,
    clippy::expect_used,
    clippy::unwrap_used,
    future_incompatible,
    missing_debug_implementations,
    nonstandard_style,
    unreachable_pub,
    missing_copy_implementations,
    unused_qualifications
)]
#![allow(clippy::missing_errors_doc)]

mod config;
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
    #[arg(short, long, default_value = "evaluator.toml")]
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

    // The store is needed both to describe inputs to the expression -- which
    // used to be the Perl's business -- and to find out whether a build an
    // input names is actually here.
    let remote = daemon_client_utils::parse_nix_remote()
        .map_err(|e| eyre::eyre!("could not work out which store to use: {e}"))?;
    let available = store_paths::Availability::new(
        daemon_client_utils::DaemonStoreReader::new(daemon_client_utils::DaemonConnector::new(
            remote.socket.clone(),
            remote.store_dir.clone(),
        )),
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
