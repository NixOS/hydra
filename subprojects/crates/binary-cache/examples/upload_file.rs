use binary_cache::S3BinaryCacheClient;
use harmonia_store_path::StorePath;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let now = std::time::Instant::now();

    let _tracing_guard = hydra_tracing::init()?;
    let nix_config = daemon_client_utils::parse_nix_remote().unwrap();
    let local = harmonia_store_remote::ConnectionPool::new(
        &nix_config.socket,
        harmonia_store_remote::PoolConfig::default(),
    );
    let client = S3BinaryCacheClient::new(
        format!(
            "s3://store2?region=unknown&endpoint=http://localhost:9000&scheme=http&write-nar-listing=1&compression=zstd&ls-compression=br&log-compression=br&secret-key={}/../../example-secret-key&profile=local_nix_store",
            env!("CARGO_MANIFEST_DIR")
        ).parse()?,
    )
    .await?;
    tracing::info!("{:#?}", client.cfg);

    let root: StorePath = "m1r53pnnm6hnjwyjmxska24y8amvlpjp-hello-2.12.1".parse()?;
    let paths_to_copy = daemon_client_utils::query_closure(&local, &[root]).await?;

    client.copy_paths(&local, paths_to_copy, true).await?;

    tracing::info!("stats: {:#?}", client.s3_stats());
    tracing::info!("Elapsed: {:#?}", now.elapsed());

    Ok(())
}
