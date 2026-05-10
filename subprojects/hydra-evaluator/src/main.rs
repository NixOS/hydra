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
mod evaluator;

use anyhow::Context as _;
use clap::Parser;

use config::{HydraConfig, parse_hydra_dbi};
use evaluator::Evaluator;

#[derive(clap::Parser, Debug)]
#[command(name = "hydra-evaluator", about = "Hydra jobset evaluation scheduler")]
struct Cli {
    /// Clear startTime on all jobsets and exit
    #[arg(long)]
    unlock: bool,

    /// Project name (requires jobset)
    project: Option<String>,

    /// Jobset name (requires project)
    jobset: Option<String>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let _tracing_guard = hydra_tracing::init()?;
    let cli = Cli::parse();

    let db_opts = parse_hydra_dbi()?;
    let db = db::Database::new_with_options(db_opts, 4)
        .await
        .context("failed to connect to database")?;

    if cli.unlock {
        sqlx::query("UPDATE Jobsets SET startTime = null")
            .execute(db.pool())
            .await
            .context("failed to unlock jobsets")?;
        tracing::info!("unlocked all jobsets");
        return Ok(());
    }

    let config = HydraConfig::load();

    let eval_one = match (cli.project, cli.jobset) {
        (Some(p), Some(j)) => Some((p, j)),
        (None, None) => None,
        _ => anyhow::bail!("Syntax: hydra-evaluator [<project> <jobset>]"),
    };

    let evaluator = Evaluator::new(db, &config, eval_one);
    evaluator.run().await
}
