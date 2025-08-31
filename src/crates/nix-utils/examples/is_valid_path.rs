use nix_utils::{self, BaseStore as _};

#[tokio::main]
async fn main() {
    let store = nix_utils::LocalStore::init();
    let nix_prefix = nix_utils::get_nix_prefix();
    println!(
        "storepath={nix_prefix} valid={}",
        store
            .is_valid_path(&nix_utils::StorePath::new(&nix_prefix))
            .await
    );
}
