use binary_cache::S3BinaryCacheClient;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let _tracing_guard = hydra_tracing::init()?;
    let client = S3BinaryCacheClient::new(
        "s3://store?region=unknown&endpoint=http://localhost:9000&scheme=http&write-nar-listing=1&ls-compression=br&log-compression=br&profile=local_nix_store".parse()?,
    )
    .await?;
    tracing::info!("{:#?}", client.cfg);

    let has_info = client
        .has_narinfo(&nix_utils::StorePath::new(
            "lmn7lwydprqibdkghw7wgcn21yhllz13-glibc-2.40-66",
        ))
        .await?;
    tracing::info!("has narinfo? {has_info}");

    let narinfo = client
        .download_narinfo(&nix_utils::StorePath::new(
            "lmn7lwydprqibdkghw7wgcn21yhllz13-glibc-2.40-66",
        ))
        .await?;
    tracing::info!("narinfo:\n{narinfo:?}");

    let nardata = client.download_nar(&narinfo.unwrap().url).await?;
    tracing::info!("nardata len: {}", nardata.unwrap().len());

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
