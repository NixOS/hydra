use harmonia_store_derivation::derivation::Derivation;
use harmonia_store_path::StorePath;

#[tokio::main]
async fn main() -> color_eyre::eyre::Result<()> {
    let p: StorePath = "dzgpbp0vp7lj7lgj26rjgmnjicq2wf4k-hello-2.12.2.drv".parse()?;
    let (tx, mut rx) = tokio::sync::mpsc::channel::<()>(4);

    let nix_config =
        daemon_client_utils::parse_nix_remote().map_err(|e| color_eyre::eyre::eyre!(e))?;
    let pool = harmonia_store_remote::ConnectionPool::new(
        &nix_config.socket,
        harmonia_store_remote::PoolConfig::default(),
    );
    let fod = std::sync::Arc::new(hydra_queue_runner::state::FodChecker::new(pool, Some(tx)));
    fod.clone().start_traverse_loop();
    fod.to_traverse(&p);
    fod.trigger_traverse();
    let _ = rx.recv().await;
    fod.process(async move |path: StorePath, _: Derivation| {
        println!("{path}");
    })
    .await;
    Ok(())
}
