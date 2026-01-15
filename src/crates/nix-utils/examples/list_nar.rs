use nix_utils::BaseStore as _;

#[tokio::main]
async fn main() {
    let store = nix_utils::LocalStore::init();

    let ls = store
        .list_nar(
            &nix_utils::StorePath::new("sqw9kyl8zrfnkklb3vp6gji9jw9qfgb5-hello-2.12.2"),
            true,
        )
        .await
        .unwrap();
    println!("{ls:?}");
}
