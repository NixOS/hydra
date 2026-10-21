//! Turns finished evaluation builds into the builds they found.

mod complete;
mod config;
mod ingest;
mod jobs;
mod queries;

use clap::Parser;
use color_eyre::eyre::{self, WrapErr as _};
use futures::StreamExt as _;

use config::Config;

#[derive(clap::Parser, Debug)]
#[command(name = "hydra-process-evaluation")]
struct Cli {
    /// Path to `hydra-submit-evaluation`'s configuration file, which this
    /// reads only for where to root the evaluated derivations
    #[arg(
        short,
        long,
        env = "HYDRA_EVALUATOR_CONFIG",
        default_value = "evaluator.toml"
    )]
    config_path: String,

    /// Process whatever is waiting and exit, rather than running as the daemon
    #[arg(long)]
    once: bool,
}

#[tokio::main]
async fn main() -> color_eyre::Result<()> {
    let _tracing_guard = hydra_tracing::init()?;
    let cli = Cli::parse();

    let db = db::Database::from_env(4)
        .await
        .wrap_err("failed to connect to database")?;
    // Only for where to root the evaluated derivations.
    let config = Config::load(&cli.config_path)?;

    // Subscribe before catching up, so a build that finishes in between is
    // not missed: it will be in the catch-up query or in the stream.
    let mut stream = if cli.once {
        None
    } else {
        Some(db.listener(vec!["build_finished"]).await?)
    };

    // Anything that finished while this was not running.
    let mut all_ok = true;
    for eval_id in queries::get_evals_awaiting_completion(&mut db.get().await?).await? {
        all_ok &= process(&db, &config, eval_id).await;
    }

    let Some(stream) = stream.as_mut() else {
        // One shot: say whether every evaluation could be recorded.
        if !all_ok {
            std::process::exit(1);
        }
        return Ok(());
    };

    // `build_finished` carries the finished build first, then any builds it
    // finished along with it; only the first can be an evaluation build.
    while let Some(notification) = stream.next().await {
        let notification = notification.wrap_err("the notification stream failed")?;
        let Some(build_id) = notification
            .payload()
            .split('\t')
            .next()
            .and_then(|s| s.parse::<i32>().ok())
        else {
            continue;
        };

        for eval_id in queries::get_evals_for_build(&mut db.get().await?, build_id).await? {
            process(&db, &config, eval_id).await;
        }
    }

    eyre::bail!("the notification stream ended")
}

/// Complete one evaluation. A failure is logged and the daemon carries on:
/// either the evaluation was marked completed with its error, or it was not
/// and the next catch-up will try it again.
async fn process(db: &db::Database, config: &Config, eval_id: i32) -> bool {
    tracing::info!("processing evaluation {eval_id}");
    match complete::complete(db, config, eval_id).await {
        Ok(()) => true,
        Err(e) => {
            tracing::error!("processing evaluation {eval_id} failed: {e:#}");
            false
        }
    }
}
