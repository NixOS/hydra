use futures::stream::StreamExt as _;

use binary_cache::{PresignedUploadClient, S3BinaryCacheClient, path_to_narinfo};
use harmonia_store_path::StorePath;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let now = std::time::Instant::now();

    let _tracing_guard = hydra_tracing::init()?;
    let nix_config = daemon_client_utils::parse_nix_remote().unwrap();
    let store = harmonia_store_remote::ConnectionPool::new(
        &nix_config.socket,
        harmonia_store_remote::PoolConfig::default(),
    );
    let client = S3BinaryCacheClient::new(
        format!(
            "s3://store2?region=unknown&endpoint=http://localhost:9000&scheme=http&write-nar-listing=1&write-debug-info=1&compression=zstd&ls-compression=br&log-compression=br&secret-key={}/../../example-secret-key&profile=local_nix_store",
            env!("CARGO_MANIFEST_DIR")
        ).parse()?,
    )
    .await?;
    tracing::info!("{:#?}", client.cfg);
    let upload_client = PresignedUploadClient::new();

    let root: StorePath = "m1r53pnnm6hnjwyjmxska24y8amvlpjp-hello-2.12.1".parse()?;
    let paths_to_copy = binary_cache::query_closure(&store, &[root]).await?;

    let mut stream = tokio_stream::iter(paths_to_copy)
        .map(|vpi| {
            let client = client.clone();
            let upload_client = upload_client.clone();
            let store = store.clone();
            let p = vpi.path;
            async move {
                let narinfo = path_to_narinfo(&store, &p).await?;

                let presigned_request = client
                    .generate_nar_upload_presigned_url(
                        &narinfo.path,
                        &narinfo.info.info.nar_hash,
                        binary_cache::get_debug_info_build_ids(store.store_dir().as_ref(), &p)
                            .await?,
                    )
                    .await?;

                let narinfo = upload_client
                    .process_presigned_request(&store, narinfo, presigned_request)
                    .await?;

                client
                    .upload_narinfo_after_presigned_upload(&store, narinfo)
                    .await?;
                Ok::<(), Box<dyn std::error::Error>>(())
            }
        })
        .buffered(10);

    while let Some(v) = tokio_stream::StreamExt::next(&mut stream).await {
        v?;
    }

    tracing::info!("Client Metrics: {:#?}", upload_client.metrics());
    tracing::info!("Main Metrics: {:#?}", client.s3_stats());
    tracing::info!("Elapsed: {:#?}", now.elapsed());

    Ok(())
}
