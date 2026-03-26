use binary_cache::S3BinaryCacheClient;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let _tracing_guard = hydra_tracing::init()?;
    let local = nix_utils::LocalStore::init();
    let client = S3BinaryCacheClient::new(
        format!(
            "s3://store2?region=unknown&endpoint=http://localhost:9000&scheme=http&write-nar-listing=1&compression=zstd&ls-compression=br&log-compression=br&secret-key={}/../../example-secret-key&profile=local_nix_store",
            env!("CARGO_MANIFEST_DIR")
        ).parse()?,
    )
    .await?;
    tracing::info!("{:#?}", client.cfg);

    let id = nix_utils::DrvOutput {
        drv_path: "g1w7hy3qg1w7hy3qg1w7hy3qg1w7hy3q-bash-5.2p37.drv".parse().unwrap(),
        output_name: "debug".parse().unwrap(),
    };
    tracing::info!(
        "has realisation before: {}",
        client.has_realisation(&id).await?
    );
    client.copy_realisation(&local, &id, true).await?;
    tracing::info!(
        "has realisation after: {}",
        client.has_realisation(&id).await?
    );

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
