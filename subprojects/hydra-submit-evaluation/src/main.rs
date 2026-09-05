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

//! Decides when jobsets are due, and queues a build to evaluate each.

mod config;
mod declarative;
mod eval_build;
mod fetcher;
mod inputs;
mod nix_eval_jobs;
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

    // The store directory is needed to describe inputs to the expression.
    let remote = daemon_client_utils::parse_nix_remote()
        .map_err(|e| eyre::eyre!("could not work out which store to use: {e}"))?;
    let available = store_paths::Availability::new(
        remote.store_dir.clone(),
        config.eval_substituter().map(str::to_owned),
    );

    match (cli.project, cli.jobset) {
        (Some(project), Some(jobset)) => {
            let trace = format!("{}.once", scheduler::now());
            match submit::submit(&db, &config, &available, &project, &jobset, &trace).await {
                Ok(submit::Outcome::Cached { previous }) => {
                    tracing::info!("cached, same as evaluation {previous}");
                }
                Ok(submit::Outcome::Scheduled { eval, build }) => {
                    tracing::info!("scheduled evaluation {eval} as build {build}");
                }
                Ok(submit::Outcome::Declared) => {
                    tracing::info!(
                        "the declarative specification named the jobsets; nothing to evaluate"
                    );
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
