#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let p = nix_utils::StorePath::new("dzgpbp0vp7lj7lgj26rjgmnjicq2wf4k-hello-2.12.2.drv");
    let (tx, mut rx) = tokio::sync::mpsc::channel::<()>(4);

    let store = nix_utils::LocalStore::init();
    let fod = std::sync::Arc::new(queue_runner::state::FodChecker::new(Some(tx)));
    fod.clone().start_traverse_loop(store);
    fod.to_traverse(&p);
    fod.trigger_traverse();
    let _ = rx.recv().await;
    fod.process(
        async move |path: nix_utils::StorePath, _: nix_utils::Derivation| {
            println!("{path}");
        },
    )
    .await;
    Ok(())
}
