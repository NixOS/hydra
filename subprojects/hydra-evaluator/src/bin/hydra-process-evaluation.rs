use clap::Parser;
use color_eyre::eyre::{self, WrapErr as _};
use futures::StreamExt as _;

use hydra_evaluator::config::HydraConfig;
use hydra_evaluator::{evaluate, queries};

#[derive(clap::Parser, Debug)]
#[command(
    name = "hydra-process-evaluation",
    about = "Turns finished evaluation builds into the builds they found"
)]
struct Cli {
    /// Path to the configuration file, shared with `hydra-submit-evaluation`
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
    let config = HydraConfig::load(&cli.config_path)?;

    // Subscribe before catching up, so a build that finishes in between is
    // not missed: it will be in the catch-up query or in the stream.
    let mut stream = if cli.once {
        None
    } else {
        Some(db.listener(vec!["build_finished"]).await?)
    };

    // Anything that finished while this was not running.
    catch_up(&db, &config).await?;

    let Some(stream) = stream.as_mut() else {
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

async fn catch_up(db: &db::Database, config: &HydraConfig) -> eyre::Result<()> {
    for eval_id in queries::get_evals_awaiting_completion(&mut db.get().await?).await? {
        process(db, config, eval_id).await;
    }
    Ok(())
}

/// Complete one evaluation, leaving it for the next catch-up if that fails:
/// the row is still uncompleted, which is the whole state this needs.
async fn process(db: &db::Database, config: &HydraConfig, eval_id: i32) {
    tracing::info!("processing evaluation {eval_id}");
    if let Err(e) = evaluate::complete(db, config, eval_id).await {
        tracing::error!("processing evaluation {eval_id} failed: {e:#}");
    }
}
