use nix_utils::BaseStore as _;

#[tokio::main]
async fn main() {
    let local = nix_utils::LocalStore::init();
    let hashes = local
        .static_output_hashes(&nix_utils::StorePath::new(
            "g6i53wpfisscqqj8d2hf3z83rzb9jklg-bash-5.2p37.drv",
        ))
        .await
        .unwrap();

    println!("hashes: {:?}", hashes);
}
