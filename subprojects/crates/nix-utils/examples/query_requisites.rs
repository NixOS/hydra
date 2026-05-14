use nix_utils::BaseStore as _;

#[tokio::main]
async fn main() {
    let store = nix_utils::LocalStore::init();

    let drv = "z3d15qi11dvljq5qz84kak3h0nb12wca-rsyslog-8.2510.0"
        .parse()
        .unwrap();
    let ps = store.query_requisites(&[&drv]).await.unwrap();
    for p in ps {
        println!("{}", store.print_store_path(&p));
    }
}
