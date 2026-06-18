use binary_cache::S3BinaryCacheClient;
use harmonia_store_path::StorePath;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let now = std::time::Instant::now();

    let _tracing_guard = hydra_tracing::init()?;
    let nix_config = daemon_client_utils::parse_nix_remote().unwrap();
    let local_db = local_nix_db::LocalNixDb::open(nix_config.store_dir.clone()).await?;
    let client = S3BinaryCacheClient::new(
        format!(
            "s3://store2?region=unknown&endpoint=http://localhost:9000&scheme=http&write-nar-listing=1&compression=zstd&ls-compression=br&log-compression=br&secret-key={}/../../example-secret-key&profile=local_nix_store",
            env!("CARGO_MANIFEST_DIR")
        ).parse()?,
    )
    .await?;
    tracing::info!("{:#?}", client.cfg);

    let root: StorePath = "m1r53pnnm6hnjwyjmxska24y8amvlpjp-hello-2.12.1".parse()?;
    let paths_to_copy = local_db.query_closure_infos(vec![root]).await?;

    client
        .copy_paths(local_db.store_dir(), paths_to_copy, true)
        .await?;

    tracing::info!("stats: {:#?}", client.s3_stats());
    tracing::info!("Elapsed: {:#?}", now.elapsed());

    Ok(())
}
