use binary_cache::S3BinaryCacheClient;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let _tracing_guard = hydra_tracing::init()?;
    let client = S3BinaryCacheClient::new(
        format!(
            "s3://store2?region=unknown&endpoint=http://localhost:9000&scheme=http&write-nar-listing=1&compression=zstd&ls-compression=br&log-compression=br&secret-key={}/../../example-secret-key&profile=local_nix_store",
            env!("CARGO_MANIFEST_DIR")
        ).parse()?,
    )
    .await?;
    tracing::info!("{:#?}", client.cfg);

    let id = harmonia_store_derivation::realisation::DrvOutput {
        drv_path: "g1w7hy3qg1w7hy3qg1w7hy3qg1w7hy3q-bash-5.2p37.drv"
            .parse()
            .unwrap(),
        output_name: "debug".parse().unwrap(),
    };
    tracing::info!(
        "has build trace before: {}",
        client.has_build_trace_entry(&id).await?
    );

    // A build trace entry is just the output path that a derivation's output
    // resolved to, so make one up rather than asking a store for it. The
    // client signs it on the way out.
    client
        .write_build_trace_entry(harmonia_store_derivation::realisation::Realisation {
            key: id.clone(),
            value: harmonia_store_derivation::realisation::UnkeyedRealisation {
                out_path: "g1w7hy3qg1w7hy3qg1w7hy3qg1w7hy3q-bash-5.2p37"
                    .parse()
                    .unwrap(),
                signatures: Default::default(),
            },
        })
        .await?;
    tracing::info!(
        "has build trace after: {}",
        client.has_build_trace_entry(&id).await?
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
