use clap::Parser;
use color_eyre::eyre::{self, WrapErr as _};

use hydra_evaluator::config::HydraConfig;
use hydra_evaluator::evaluator::Evaluator;
use hydra_evaluator::{evaluate, store_paths};

#[derive(clap::Parser, Debug)]
#[command(
    name = "hydra-submit-evaluation",
    about = "Decides when jobsets are due, and queues a build to evaluate each"
)]
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
    let config = HydraConfig::load(&cli.config_path)?;

    // The store is needed both to describe inputs to the expression and to
    // find out whether a build an input names is actually here.
    let remote = daemon_client_utils::parse_nix_remote()
        .map_err(|e| eyre::eyre!("could not work out which store to use: {e}"))?;
    let available = store_paths::Availability::new(
        remote.store_dir.clone(),
        config.eval_substituter().map(str::to_owned),
    );

    match (cli.project, cli.jobset) {
        // One jobset, now. Submitting is quick -- fetch the inputs, queue a
        // build -- so there is nothing to supervise: do it and report.
        (Some(project), Some(jobset)) => {
            let trace = format!("{}.once", now());
            match evaluate::evaluate(&db, &config, &available, &project, &jobset, &trace).await {
                Ok(evaluate::Outcome::Cached { previous }) => {
                    tracing::info!("cached, same as evaluation {previous}");
                }
                Ok(evaluate::Outcome::Scheduled { eval, build }) => {
                    tracing::info!("scheduled evaluation {eval} as build {build}");
                }
                Ok(evaluate::Outcome::Declared) => {
                    tracing::info!("jobsets created from the declarative specification");
                }
                Err(e) => {
                    tracing::error!("{e:#}");
                    std::process::exit(1);
                }
            }
            Ok(())
        }
        (None, None) => {
            Evaluator::new(
                db,
                std::sync::Arc::new(config),
                std::sync::Arc::new(available),
            )
            .run()
            .await
        }
        _ => eyre::bail!("Syntax: hydra-submit-evaluation [<project> <jobset>]"),
    }
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(0))
}
