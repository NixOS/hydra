use binary_cache::S3BinaryCacheClient;
use nix_utils::BaseStore as _;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let _tracing_guard = hydra_tracing::init()?;
    let store = nix_utils::LocalStore::init();

    let client = S3BinaryCacheClient::new(
        "s3://nix-cache-staging?ls-compression=br&log-compression=br".parse()?,
    )
    .await?;
    tracing::info!("{:#?}", client.cfg);

    let drv = nix_utils::StorePath::new("z3d15qi11dvljq5qz84kak3h0nb12wca-rsyslog-8.2510.0");
    let ps = store.query_requisites(&[&drv], false).await.unwrap();
    println!("ps before: {}", ps.len());

    let ps = client.query_missing_paths(ps.clone()).await;
    println!("ps after: {}", ps.len());

    let ps = store.query_requisites(&[&drv], true).await.unwrap();
    for p in ps {
        println!("{}", store.print_store_path(&p));
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
