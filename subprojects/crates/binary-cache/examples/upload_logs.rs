use binary_cache::S3BinaryCacheClient;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let _tracing_guard = hydra_tracing::init()?;
    let client = S3BinaryCacheClient::new(
        "s3://store?region=unknown&endpoint=http://localhost:9000&scheme=http&write-nar-listing=1&ls-compression=br&log-compression=br&profile=local_nix_store".parse()?,
    )
    .await?;
    tracing::info!("{:#?}", client.cfg);

    let file = fs_err::tokio::File::open("/tmp/asdf").await.unwrap();
    let reader = Box::new(tokio::io::BufReader::new(file));
    client
        .upsert_file_stream("log/test2.drv", reader, "text/plain; charset=utf-8")
        .await?;

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
