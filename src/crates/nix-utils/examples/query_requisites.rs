use nix_utils::BaseStore as _;

#[tokio::main]
async fn main() {
    let store = nix_utils::LocalStore::init();

    let drv = nix_utils::StorePath::new("5g60vyp4cbgwl12pav5apyi571smp62s-hello-2.12.2.drv");
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
