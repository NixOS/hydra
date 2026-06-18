use binary_cache::S3BinaryCacheClient;
use harmonia_store_path::StorePath;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let _tracing_guard = hydra_tracing::init()?;
    let nix_config = daemon_client_utils::parse_nix_remote().unwrap();
    let local_db = local_nix_db::LocalNixDb::open(nix_config.store_dir.clone()).await?;

    let client = S3BinaryCacheClient::new(
        "s3://nix-cache-staging?ls-compression=br&log-compression=br".parse()?,
    )
    .await?;
    tracing::info!("{:#?}", client.cfg);

    let drv: StorePath = "z3d15qi11dvljq5qz84kak3h0nb12wca-rsyslog-8.2510.0".parse()?;

    let ps: Vec<StorePath> = local_db.query_closure(vec![drv.clone()]).await?;
    println!("closure size: {}", ps.len());

    let missing = client.query_missing_paths(ps).await;
    println!("missing: {}", missing.len());

    for p in &missing {
        println!("  {}", local_db.store_dir().display(p));
    }

    let stats = client.s3_stats();
    tracing::info!(
        "stats: put={}, put_bytes={}, put_time_ms={}, get={}, get_bytes={}, get_time_ms={}, head={}",
        stats.put,
        stats.put_bytes,
        stats.put_time_ms,
        stats.get,
        stats.get_bytes,
        stats.get_time_ms,
        stats.head
    );

    Ok(())
}
