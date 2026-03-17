#[tokio::main]
async fn main() {
    let store = nix_utils::LocalStore::init();
    let drv = nix_utils::query_drv(
        &store,
        &nix_utils::parse_store_path("5g60vyp4cbgwl12pav5apyi571smp62s-hello-2.12.2.drv"),
    )
    .await
    .unwrap();

    println!("{drv:?}");
}
