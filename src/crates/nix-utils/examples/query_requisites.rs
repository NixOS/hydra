use nix_utils::BaseStore as _;

#[tokio::main]
async fn main() {
    let store = nix_utils::LocalStore::init();

    let drv = nix_utils::StorePath::new("z3d15qi11dvljq5qz84kak3h0nb12wca-rsyslog-8.2510.0");
    let ps = store.query_requisites(&[&drv], false).await.unwrap();
    for p in ps {
        println!("{}", store.print_store_path(&p));
    }

    println!();
    println!();

    let ps = store.query_requisites(&[&drv], true).await.unwrap();
    for p in ps {
        println!("{}", store.print_store_path(&p));
    }
}
