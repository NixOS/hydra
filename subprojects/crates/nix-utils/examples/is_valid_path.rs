use nix_utils::{self, BaseStore as _};

#[tokio::main]
async fn main() {
    let store = nix_utils::LocalStore::init();
    let store_dir = nix_utils::get_store_dir();
    println!(
        "storepath={store_dir} valid={}",
        store
            .is_valid_path(&nix_utils::parse_store_path(store_dir.as_ref()))
            .await
    );
}
