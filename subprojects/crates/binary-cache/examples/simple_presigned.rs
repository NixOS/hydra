use futures::stream::StreamExt as _;

use binary_cache::{PresignedUploadClient, S3BinaryCacheClient, path_to_narinfo};
use nix_utils::BaseStore as _;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let now = std::time::Instant::now();

    let _tracing_guard = hydra_tracing::init()?;
    let store = nix_utils::LocalStore::init();
    let client = S3BinaryCacheClient::new(
        format!(
            "s3://store2?region=unknown&endpoint=http://localhost:9000&scheme=http&write-nar-listing=1&write-debug-info=1&compression=zstd&ls-compression=br&log-compression=br&secret-key={}/../../example-secret-key&profile=local_nix_store",
            env!("CARGO_MANIFEST_DIR")
        ).parse()?,
    )
    .await?;
    tracing::info!("{:#?}", client.cfg);
    let upload_client = PresignedUploadClient::new();

    let paths_to_copy = store
        .query_requisites(
            &[&nix_utils::StorePath::new(
                "/nix/store/m1r53pnnm6hnjwyjmxska24y8amvlpjp-hello-2.12.1",
            )],
            true,
        )
        .await
        .unwrap_or_default();

    let mut stream = tokio_stream::iter(paths_to_copy)
        .map(|p| {
            let client = client.clone();
            let upload_client = upload_client.clone();
            let store = store.clone();
            async move {
                let narinfo = path_to_narinfo(&store, &p).await?;

                let presigned_request = client
                    .generate_nar_upload_presigned_url(
                        &narinfo.store_path,
                        &narinfo.nar_hash,
                        binary_cache::get_debug_info_build_ids(&store, &p).await?,
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
